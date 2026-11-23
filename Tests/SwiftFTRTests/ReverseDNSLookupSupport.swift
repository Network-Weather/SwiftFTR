import Foundation
import Testing
import dnssd

@testable import SwiftFTR

/// A substitute for the DNS daemon behind ``ReverseDNSLookup``, through `TestSeams.dnsService`.
///
/// It hands out fake references, records every call with the queue it ran on, and delivers
/// replies through the lookup's real callback, on the queue the reference was scheduled on, as
/// the daemon does. Like the daemon, it delivers nothing to a reference once it is deallocated.
final class FakeDNSService: @unchecked Sendable {
  enum Start {
    /// Return success and a reference.
    case succeed
    /// Return this error and no reference.
    case fail(DNSServiceErrorType)
    /// Block the calling thread (the lookup's queue) until the gate opens, then succeed.
    case gated(StallGate)
  }

  struct Call {
    /// Whether the call ran on a lookup's own queue.
    let onLookupQueue: Bool
    /// The lookup queue's identity, when it ran on one.
    let queueID: ObjectIdentifier?
  }

  private final class Query: @unchecked Sendable {
    let name: String
    let interfaceIndex: UInt32
    let flags: DNSServiceFlags
    let context: UnsafeMutableRawPointer
    let startQueue: ObjectIdentifier?
    var queue: DispatchQueue?
    var deallocated = false
    /// The context object, held weakly, so a deallocate can see whether it is still alive.
    weak var contextObject: ReverseDNSLookup.CallbackContext?

    init(
      name: String, interfaceIndex: UInt32, flags: DNSServiceFlags,
      context: UnsafeMutableRawPointer, startQueue: ObjectIdentifier?
    ) {
      self.name = name
      self.interfaceIndex = interfaceIndex
      self.flags = flags
      self.context = context
      self.startQueue = startQueue
      self.contextObject = Unmanaged<ReverseDNSLookup.CallbackContext>.fromOpaque(context)
        .takeUnretainedValue()
    }
  }

  private let lock = NSLock()
  private let start: Start
  private let queueResult: DNSServiceErrorType
  private var queries: [OpaquePointer: Query] = [:]
  private var order: [OpaquePointer] = []
  private var startCalls: [Call] = []
  private var deallocations: [Call] = []
  private var deallocatedOnStartQueue: [Bool] = []
  private var contextAliveAtDeallocate: [Bool] = []
  private var callbacks = 0
  private var live = 0
  private var maxLive = 0
  private var unknownDeallocations = 0
  private var doubleDeallocations = 0

  /// How a lookup's deadline passes.
  enum Deadline {
    /// Only when the test calls ``expireDeadlines()`` or ``expireDeadline(number:)``, never by
    /// the clock, so a test can order it against every other event.
    case controlled
    /// At once, inside the call that arms it: before the lookup has asked for a permit or
    /// queued its start.
    case expiresWhenArmed
    /// By the lookup's real timer.
    case timer
  }

  init(
    start: Start = .succeed, queueResult: DNSServiceErrorType = DNSServiceStatus.noError,
    deadline: Deadline = .controlled
  ) {
    self.start = start
    self.queueResult = queueResult
    self.deadline = deadline
  }

  deinit {
    for ref in order { UnsafeMutableRawPointer(ref).deallocate() }
  }

  private let deadline: Deadline
  /// Every deadline armed, in the order lookups armed them; `nil` once it has been made to pass.
  private var armed: [(@Sendable () -> Void)?] = []

  /// Deadlines lookups have armed through this fake, passed or not.
  var deadlinesArmed: Int { locked { armed.count } }

  /// Makes every armed deadline that has not yet passed pass now, on this thread. Returns how
  /// many there were.
  @discardableResult
  func expireDeadlines() -> Int {
    let due = locked {
      let due = armed.compactMap { $0 }
      armed = armed.map { _ in nil }
      return due
    }
    for expire in due { expire() }
    return due.count
  }

  /// Makes the `number`th deadline armed (from 0) pass now, unless it already has. Returns
  /// whether it was still pending.
  @discardableResult
  func expireDeadline(number: Int) -> Bool {
    let due: (@Sendable () -> Void)? = locked {
      guard number < armed.count else { return nil }
      let due = armed[number]
      armed[number] = nil
      return due
    }
    due?()
    return due != nil
  }

  var calls: DNSServiceCalls {
    return DNSServiceCalls(
      queryRecord: { [self] flags, interfaceIndex, name, context in
        let call = Self.currentCall()
        lock.lock()
        startCalls.append(call)
        lock.unlock()
        switch start {
        case .fail(let status):
          return (status, nil)
        case .gated(let gate):
          gate.wait(limit: 60)
        case .succeed:
          break
        }
        let ref = OpaquePointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
        lock.lock()
        queries[ref] = Query(
          name: name, interfaceIndex: interfaceIndex, flags: flags, context: context,
          startQueue: call.queueID)
        order.append(ref)
        live += 1
        maxLive = max(maxLive, live)
        lock.unlock()
        return (DNSServiceStatus.noError, ref)
      },
      setDispatchQueue: { [self] ref, queue in
        lock.lock()
        defer { lock.unlock() }
        guard queueResult == DNSServiceStatus.noError else { return queueResult }
        queries[ref]?.queue = queue
        return queueResult
      },
      deallocate: { [self] ref in
        let call = Self.currentCall()
        lock.lock()
        defer { lock.unlock() }
        deallocations.append(call)
        guard let query = queries[ref] else {
          unknownDeallocations += 1
          return
        }
        if query.deallocated {
          doubleDeallocations += 1
          return
        }
        query.deallocated = true
        contextAliveAtDeallocate.append(query.contextObject != nil)
        deallocatedOnStartQueue.append(call.queueID != nil && call.queueID == query.startQueue)
        live -= 1
      },
      armDeadline: deadline == .timer ? nil : armDeadline
    )
  }

  /// Records a lookup's deadline, to pass only when ``expireDeadlines()`` is called.
  /// Records a lookup's deadline, to pass when the test says so, or at once.
  private var armDeadline:
    @Sendable (_ timeout: TimeInterval, _ expire: @escaping @Sendable () -> Void) -> Void
  {
    { [self] _, expire in
      if deadline == .expiresWhenArmed {
        lock.lock()
        armed.append(nil)
        lock.unlock()
        expire()
        return
      }
      lock.lock()
      armed.append(expire)
      lock.unlock()
    }
  }

  /// Runs `body` with this fake in place of the daemon.
  func install<T>(_ body: () async throws -> T) async rethrows -> T {
    try await TestSeams.$dnsService.withValue(calls) { try await body() }
  }

  /// Delivers one reply to the `index`th query started, on its queue, unless it has been
  /// deallocated by the time the queue runs it. Returns `false` when there is no such scheduled
  /// query.
  @discardableResult
  func deliver(
    to index: Int = 0,
    flags: DNSServiceFlags = DNSServiceFlags(kDNSServiceFlagsAdd),
    error: DNSServiceErrorType = DNSServiceStatus.noError,
    rrtype: UInt16 = UInt16(kDNSServiceType_PTR),
    rdata: [UInt8] = []
  ) -> Bool {
    lock.lock()
    guard index < order.count, let query = queries[order[index]], let queue = query.queue else {
      lock.unlock()
      return false
    }
    let refAddress = UnsafeMutableRawPointer(order[index])
    lock.unlock()
    queue.async { [self] in
      let ref = OpaquePointer(refAddress)
      lock.lock()
      let gone = query.deallocated
      if !gone { callbacks += 1 }
      lock.unlock()
      guard !gone else { return }
      rdata.withUnsafeBytes { bytes in
        ReverseDNSLookup.reply(
          ref, flags, 0, error, query.name, rrtype, UInt16(kDNSServiceClass_IN),
          UInt16(bytes.count), bytes.baseAddress, 60, query.context)
      }
    }
    return true
  }

  /// Queues a block on the `index`th query's queue that waits for `gate`, so whatever is queued
  /// after it runs only once the gate opens, in the order it was queued. Returns `false` when
  /// there is no such scheduled query.
  @discardableResult
  func blockQueue(of index: Int = 0, until gate: StallGate) -> Bool {
    lock.lock()
    guard index < order.count, let queue = queries[order[index]]?.queue else {
      lock.unlock()
      return false
    }
    lock.unlock()
    queue.async { gate.wait(limit: 60) }
    return true
  }

  /// Returns once everything queued so far on the `index`th query's queue has run.
  func drainQueue(of index: Int = 0) async {
    let queue = locked { index < order.count ? queries[order[index]]?.queue : nil }
    guard let queue else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      queue.async { continuation.resume() }
    }
  }

  var starts: [Call] { locked { startCalls } }
  var deallocs: [Call] { locked { deallocations } }
  /// For each deallocated reference, whether it was deallocated on the queue its start ran on.
  var deallocatedOnOwnQueue: [Bool] { locked { deallocatedOnStartQueue } }
  /// For each deallocated reference, whether its callback context was still alive at the call.
  var contextAliveAtEachDeallocate: [Bool] { locked { contextAliveAtDeallocate } }
  var maxConcurrent: Int { locked { maxLive } }
  /// Replies handed to the lookup's callback (a reply queued after the deallocate is dropped, as
  /// the daemon drops it).
  var callbacksDelivered: Int { locked { callbacks } }
  var liveCount: Int { locked { live } }
  var misuse: (unknown: Int, double: Int) { locked { (unknownDeallocations, doubleDeallocations) } }
  var startedCount: Int { locked { order.count } }
  var scheduledCount: Int { locked { order.filter { queries[$0]?.queue != nil }.count } }

  func question(_ index: Int = 0) -> (name: String, interfaceIndex: UInt32, flags: DNSServiceFlags)?
  {
    locked {
      guard index < order.count, let query = queries[order[index]] else { return nil }
      return (query.name, query.interfaceIndex, query.flags)
    }
  }

  private func locked<T>(_ body: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    return body()
  }

  private static func currentCall() -> Call {
    let id = DispatchQueue.getSpecific(key: ReverseDNSLookup.queueKey)
    return Call(onLookupQueue: id != nil, queueID: id)
  }
}

/// Wraps the real daemon calls, recording what ``FakeDNSService`` records about queues and
/// counting live references, so a test against the real daemon can check the same rules.
final class CountingDNSService: @unchecked Sendable {
  private let lock = NSCondition()
  /// Each successful start waits, on its lookup's queue, until this many references are open at
  /// once (or 30 seconds pass), so a test can make overlap certain. Zero waits for nothing.
  private let holdUntilLive: Int
  private var reachedHold = false

  init(holdUntilLive: Int = 0) {
    self.holdUntilLive = holdUntilLive
  }

  private var live = 0
  private var maxLive = 0
  private var started = 0
  private var deallocated = 0
  private var offQueue = 0
  private var descriptorsSeen = 0

  var calls: DNSServiceCalls {
    let system = DNSServiceCalls.system
    return DNSServiceCalls(
      queryRecord: { [self] flags, interfaceIndex, name, context in
        let onQueue = DispatchQueue.getSpecific(key: ReverseDNSLookup.queueKey) != nil
        let (status, ref) = system.queryRecord(flags, interfaceIndex, name, context)
        lock.lock()
        if !onQueue { offQueue += 1 }
        if let ref {
          started += 1
          live += 1
          maxLive = max(maxLive, live)
          if DNSServiceRefSockFD(ref) >= 0 { descriptorsSeen += 1 }
          if live >= holdUntilLive { reachedHold = true }
          lock.broadcast()
          let giveUp = Date().addingTimeInterval(30)
          while !reachedHold && lock.wait(until: giveUp) {}
        }
        lock.unlock()
        return (status, ref)
      },
      setDispatchQueue: system.setDispatchQueue,
      deallocate: { [self] ref in
        let onQueue = DispatchQueue.getSpecific(key: ReverseDNSLookup.queueKey) != nil
        system.deallocate(ref)
        lock.lock()
        if !onQueue { offQueue += 1 }
        deallocated += 1
        live -= 1
        lock.unlock()
      }
    )
  }

  func install<T>(_ body: () async throws -> T) async rethrows -> T {
    try await TestSeams.$dnsService.withValue(calls) { try await body() }
  }

  var snapshot: (started: Int, deallocated: Int, live: Int, maxLive: Int, offQueue: Int, fds: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (started, deallocated, live, maxLive, offQueue, descriptorsSeen)
  }
}

/// Wire-form domain names for PTR data.
enum PTRData {
  static func name(_ dotted: String) -> [UInt8] {
    var bytes: [UInt8] = []
    for label in dotted.split(separator: ".") {
      bytes.append(UInt8(label.utf8.count))
      bytes.append(contentsOf: label.utf8)
    }
    bytes.append(0)
    return bytes
  }
}
