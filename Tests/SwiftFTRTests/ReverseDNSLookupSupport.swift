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

    init(
      name: String, interfaceIndex: UInt32, flags: DNSServiceFlags,
      context: UnsafeMutableRawPointer, startQueue: ObjectIdentifier?
    ) {
      self.name = name
      self.interfaceIndex = interfaceIndex
      self.flags = flags
      self.context = context
      self.startQueue = startQueue
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
  private var live = 0
  private var maxLive = 0
  private var unknownDeallocations = 0
  private var doubleDeallocations = 0

  init(start: Start = .succeed, queueResult: DNSServiceErrorType = DNSServiceStatus.noError) {
    self.start = start
    self.queueResult = queueResult
  }

  var calls: DNSServiceCalls {
    DNSServiceCalls(
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
        deallocatedOnStartQueue.append(call.queueID != nil && call.queueID == query.startQueue)
        live -= 1
      }
    )
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

  var starts: [Call] { locked { startCalls } }
  var deallocs: [Call] { locked { deallocations } }
  /// For each deallocated reference, whether it was deallocated on the queue its start ran on.
  var deallocatedOnOwnQueue: [Bool] { locked { deallocatedOnStartQueue } }
  var maxConcurrent: Int { locked { maxLive } }
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
  private let lock = NSLock()
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
