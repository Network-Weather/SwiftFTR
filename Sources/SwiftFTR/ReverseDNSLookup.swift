import Foundation
import dnssd

#if canImport(Darwin)
  import Darwin
#endif

/// The PTR question for one address: the name to query and the interface to query it on.
struct ReverseDNSQuestion: Sendable, Equatable {
  /// The reverse name, without a trailing dot: `4.3.2.1.in-addr.arpa` or 32 nibbles and
  /// `ip6.arpa`.
  let name: String
  /// The zone of a link-local IPv6 address, as an interface index; 0 (every interface) otherwise.
  let interfaceIndex: UInt32
  /// Whether the daemon answers this question by multicast DNS on the local link (169.254.0.0/16
  /// and fe80::/10). Multicast never answers "no such name", so an unanswered question of this
  /// kind runs until its caller's deadline: it is evidence of no responder, not of a stall.
  let isMulticast: Bool

  /// The question for `address`, or `nil` when it is not an IPv4 or IPv6 literal.
  ///
  /// An IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) asks the IPv4 question for `a.b.c.d`, because
  /// that is the question `getnameinfo` answers for it: on macOS it returns the IPv4 address's
  /// name for the mapped form. A zone is honoured only on a link-local address, where it says
  /// which link to ask; on any other address it would scope a unicast question to an interface
  /// that may have no resolver, which the daemon answers with "no such record" at once.
  ///
  /// A zone on a link-local address must name an interface that exists, by name (`%en0`) or by
  /// index (`%4`); otherwise there is no question, because falling back to every link would let
  /// a responder on another link name an address the caller scoped elsewhere. A link-local
  /// address with no zone asks on every link, as `getnameinfo` does for it (measured: unscoped
  /// `fe80::1` is answered with the name a lookup scoped to `lo0` received), so its answer may
  /// come from any link.
  ///
  /// A string with an embedded NUL is no literal: `inet_pton` would see only the part before it.
  init?(address: String) {
    guard !address.utf8.contains(0) else { return nil }
    var v4 = in_addr()
    if address.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
      self.init(ipv4: withUnsafeBytes(of: &v4) { Array($0) })
      return
    }
    let parts = address.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
    guard let bare = parts.first, !bare.isEmpty else { return nil }
    if parts.count == 2 && parts[1].isEmpty { return nil }
    var v6 = in6_addr()
    guard String(bare).withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 else { return nil }
    let bytes = withUnsafeBytes(of: &v6) { Array($0) }

    if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xFF && bytes[11] == 0xFF {
      self.init(ipv4: Array(bytes[12..<16]))
      return
    }

    let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
    var interfaceIndex: UInt32 = 0
    if isLinkLocal && parts.count == 2 {
      guard let index = Self.interfaceIndex(zone: String(parts[1])) else { return nil }
      interfaceIndex = index
    }
    var nibbles: [String] = []
    nibbles.reserveCapacity(32)
    for byte in bytes.reversed() {
      nibbles.append(String(byte & 0x0F, radix: 16))
      nibbles.append(String(byte >> 4, radix: 16))
    }
    self.init(
      name: nibbles.joined(separator: ".") + ".ip6.arpa",
      interfaceIndex: interfaceIndex,
      isMulticast: isLinkLocal)
  }

  /// The index of the interface `zone` names, by name or as a decimal index, or `nil` when no
  /// interface has that name or index.
  private static func interfaceIndex(zone: String) -> UInt32? {
    let byName = if_nametoindex(zone)
    if byName != 0 { return byName }
    guard let index = UInt32(zone), index != 0 else { return nil }
    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
    return if_indextoname(index, &name) != nil ? index : nil
  }

  private init(ipv4 octets: [UInt8]) {
    self.init(
      name: octets.reversed().map(String.init).joined(separator: ".") + ".in-addr.arpa",
      interfaceIndex: 0,
      isMulticast: octets[0] == 169 && octets[1] == 254)
  }

  private init(name: String, interfaceIndex: UInt32, isMulticast: Bool) {
    self.name = name
    self.interfaceIndex = interfaceIndex
    self.isMulticast = isMulticast
  }
}

/// How one reverse-DNS lookup ended.
enum ReverseDNSLookupOutcome: Sendable, Equatable {
  /// The first PTR record the daemon added, as a hostname without the trailing dot, in DNS
  /// presentation form: printable ASCII only, with `.` and `\` inside a label and every other
  /// byte outside `!` to `~` escaped (see ``ReverseDNSLookup/hostname(fromPTR:)``). An ordinary
  /// hostname is the string `getnameinfo` returns.
  case answer(String)
  /// The daemon reported that no PTR record exists (`kDNSServiceErr_NoSuchRecord`, or
  /// `kDNSServiceErr_NoSuchName`).
  ///
  /// This does not prove the address has no name. The daemon reports it, with the same flags,
  /// for an authoritative negative answer and for a question it suppressed without asking anyone
  /// (measured: a question scoped to an interface with no resolver gets it at once, for an
  /// address that has a PTR record). See ``isCacheable``.
  case noSuchRecord
  /// The lookup could not be made, or the daemon ended it with an error.
  case error(ReverseDNSLookupError)
  /// The caller's deadline passed with no outcome, or the daemon gave up
  /// (`kDNSServiceErr_Timeout`).
  case timedOut
  /// The calling task was cancelled, or ``ReverseDNSLookup/cancel()`` was called, first.
  case cancelled

  /// Whether a cache may keep this outcome as what the address's name is. Only an answer: "no
  /// such record" cannot be told apart from a suppressed question, and every other outcome says
  /// nothing about the name.
  var isCacheable: Bool {
    if case .answer = self { return true }
    return false
  }
}

/// The `dns_sd` error codes this file reads, as the type the API returns them in.
enum DNSServiceStatus {
  static let noError = DNSServiceErrorType(kDNSServiceErr_NoError)
  static let unknown = DNSServiceErrorType(kDNSServiceErr_Unknown)
  static let noSuchName = DNSServiceErrorType(kDNSServiceErr_NoSuchName)
  static let noSuchRecord = DNSServiceErrorType(kDNSServiceErr_NoSuchRecord)
  static let timeout = DNSServiceErrorType(kDNSServiceErr_Timeout)
  static let serviceNotRunning = DNSServiceErrorType(kDNSServiceErr_ServiceNotRunning)
  static let defunctConnection = DNSServiceErrorType(kDNSServiceErr_DefunctConnection)
}

/// Why a reverse-DNS lookup ended with ``ReverseDNSLookupOutcome/error(_:)``.
enum ReverseDNSLookupError: Sendable, Equatable {
  /// The address is not an IPv4 or IPv6 literal. No query was made.
  case invalidAddress
  /// `DNSServiceQueryRecord` returned this error; no query exists.
  case startFailed(DNSServiceErrorType)
  /// `DNSServiceSetDispatchQueue` returned this error; the query was deallocated.
  case dispatchQueueFailed(DNSServiceErrorType)
  /// The daemon delivered this error to the callback, for example
  /// `kDNSServiceErr_ServiceNotRunning` or `kDNSServiceErr_DefunctConnection`.
  case daemon(DNSServiceErrorType)
  /// The daemon added a PTR record whose data is not one well-formed, uncompressed domain name.
  /// Says nothing about the address's name, so it is not cached.
  case malformedRecord
}

/// The three `dns_sd` calls a lookup makes, so tests can substitute the daemon
/// (``TestSeams/dnsService``).
///
/// `queryRecord` runs on the lookup's queue and must call back, if ever, through
/// ``ReverseDNSLookup/reply`` with the context it was given, on the queue `setDispatchQueue`
/// received. `deallocate` is called exactly once for a reference `queryRecord` returned, on that
/// same queue, and no callback may follow it.
struct DNSServiceCalls: Sendable {
  var queryRecord:
    @Sendable (
      _ flags: DNSServiceFlags, _ interfaceIndex: UInt32, _ name: String,
      _ context: UnsafeMutableRawPointer
    ) -> (DNSServiceErrorType, DNSServiceRef?)
  var setDispatchQueue:
    @Sendable (_ ref: DNSServiceRef, _ queue: DispatchQueue) -> DNSServiceErrorType
  var deallocate: @Sendable (_ ref: DNSServiceRef) -> Void

  /// The system daemon.
  static let system = DNSServiceCalls(
    queryRecord: { flags, interfaceIndex, name, context in
      var ref: DNSServiceRef?
      let status = DNSServiceQueryRecord(
        &ref, flags, interfaceIndex, name, UInt16(kDNSServiceType_PTR),
        UInt16(kDNSServiceClass_IN), ReverseDNSLookup.reply, context)
      return (status, status == DNSServiceStatus.noError ? ref : nil)
    },
    setDispatchQueue: { ref, queue in DNSServiceSetDispatchQueue(ref, queue) },
    deallocate: { ref in DNSServiceRefDeallocate(ref) }
  )
}

/// One PTR lookup through the system's DNS daemon (`DNSServiceQueryRecord`), which holds no
/// thread while it waits and is stopped, not abandoned, when the caller stops waiting.
///
/// The `DNSServiceRef` rules, which is where this API crashes if misused:
///
/// - The lookup owns a serial queue. `DNSServiceQueryRecord` runs on it, because it makes a
///   synchronous round trip to the daemon; the reference is scheduled on it with
///   `DNSServiceSetDispatchQueue`, so every callback runs on it; and `DNSServiceRefDeallocate`
///   runs only on it. The results of both calls are checked.
/// - The deadline timer runs on a different queue, so a start call stalled in the daemon cannot
///   delay it. The caller is released at the deadline; when the start call finally returns, the
///   reference it made is deallocated at once.
/// - Cancellation from any thread resolves the caller where it is and hops to the queue to
///   deallocate.
/// - The callback context is a ``CallbackContext`` that only the daemon's reference holds,
///   retained when the query starts and released only after the deallocate, so no callback can
///   reach a freed context. It refers to this object, which it keeps alive for as long as it
///   lives.
///   deallocate, so no callback can reach a freed object.
/// - `kDNSServiceFlagsReturnIntermediates` is set, because without it an address with no name
///   never calls back. Intermediate records of another type (a CNAME) and remove events (no
///   `kDNSServiceFlagsAdd`) are ignored; only an added PTR record or an error is an outcome. The
///   query would stay active until deallocated, so the first outcome deallocates it.
/// - The caller is resumed exactly once, with the first of: an outcome from the daemon, the
///   deadline, or cancellation.
///
/// States, and what each event does. "Resolved" means the caller has its outcome; "torn down"
/// means the reference has been deallocated or will never exist.
///
///     State                  Event                       Rule
///     created                cancel or deadline          resolve; the start finds it resolved,
///                                                        makes no query, and tears down
///     starting (on queue)    cancel or deadline          resolve now (the caller is released
///                                                        while the start call runs); the start
///                                                        returns and deallocates at once
///     starting               start call fails            resolve with startFailed; no reference
///     starting               queue call fails            resolve with dispatchQueueFailed;
///                                                        deallocate
///     running                added PTR, error            resolve with the outcome; deallocate
///                                                        in the callback
///     running                CNAME, remove event         ignored
///     running                cancel or deadline          resolve; hop to the queue; deallocate
///     resolved, torn down    any event                   ignored
final class ReverseDNSLookup: @unchecked Sendable {
  /// Lookups in flight at once by default. Each holds one descriptor (its connection to the
  /// daemon), so this keeps reverse DNS far from the default limit of 256 descriptors however
  /// many traces run at once; 32 also covers every hop of one trace in a single wave. A
  /// proposed value, not a measurement.
  static let defaultMaxConcurrentLookups = 32

  /// Bounds the lookups in flight in this process, for callers that pass no limiter of their own.
  static let sharedLimiter = _ConcurrencySemaphore(maxConcurrent: defaultMaxConcurrentLookups)

  static let flags = DNSServiceFlags(kDNSServiceFlagsReturnIntermediates)

  /// Marks a lookup's own queue, so a test substitute can check which queue it was called on.
  static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

  /// Runs every lookup's deadline timer. Never the lookup's own queue, where a stalled start
  /// call would hold the timer back.
  private static let timerQueue = DispatchQueue(label: "com.swiftftr.rdns.deadline")

  /// Looks up the PTR name of `address` through the system daemon.
  ///
  /// Waits for a permit from `limiter` first, without holding a thread; the deadline starts once
  /// the permit is held, and the permit is returned only when the lookup's reference has been
  /// deallocated, so `limiter` bounds the descriptors actually open. Cancelling the calling task
  /// while it waits returns ``ReverseDNSLookupOutcome/cancelled``.
  ///
  /// - Parameters:
  ///   - address: An IPv4 or IPv6 literal, with an optional zone.
  ///   - timeout: Seconds from the start of the query until the caller is released with
  ///     ``ReverseDNSLookupOutcome/timedOut``. Zero, negative and NaN make no query.
  ///   - limiter: Bounds the lookups in flight. Defaults to one shared by the process.
  static func lookup(
    _ address: String,
    timeout: TimeInterval,
    limiter: _ConcurrencySemaphore = ReverseDNSLookup.sharedLimiter
  ) async -> ReverseDNSLookupOutcome {
    guard let question = ReverseDNSQuestion(address: address) else {
      return .error(.invalidAddress)
    }
    guard timeout > 0 else { return .timedOut }
    // Read on the async side: the lookup's queue cannot see task-locals.
    let calls = TestSeams.dnsService ?? .system
    do {
      try await limiter.wait()
    } catch {
      return .cancelled
    }
    let lookup = ReverseDNSLookup(question: question, calls: calls) {
      Task { await limiter.signal() }
    }
    return await withTaskCancellationHandler {
      await lookup.run(timeout: timeout)
    } onCancel: {
      lookup.cancel()
    }
  }

  let question: ReverseDNSQuestion
  private let calls: DNSServiceCalls
  private let queue: DispatchQueue
  /// Called once, on `queue`, when the reference has been deallocated or will never exist.
  private let onTornDown: @Sendable () -> Void

  // Guarded by `lock`; read and written from any thread.
  private let lock = NSLock()
  private var outcome: ReverseDNSLookupOutcome?
  private var continuation: CheckedContinuation<ReverseDNSLookupOutcome, Never>?
  private var timer: DispatchSourceTimer?

  // Confined to `queue`.
  private var ref: DNSServiceRef?
  private var context: Unmanaged<CallbackContext>?
  private var tornDown = false

  init(
    question: ReverseDNSQuestion, calls: DNSServiceCalls,
    onTornDown: @escaping @Sendable () -> Void = {}
  ) {
    self.question = question
    self.calls = calls
    self.onTornDown = onTornDown
    self.queue = DispatchQueue(label: "com.swiftftr.rdns.lookup")
    queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
  }

  /// Starts the query and returns its outcome. Call once.
  func run(timeout: TimeInterval) async -> ReverseDNSLookupOutcome {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let outcome {
        // Cancelled before the wait began.
        lock.unlock()
        continuation.resume(returning: outcome)
      } else {
        self.continuation = continuation
        lock.unlock()
        armDeadline(timeout)
      }
      // Always hop to the queue: the start makes the query, or finds the lookup resolved and
      // tears it down without one.
      queue.async { self.start() }
    }
  }

  /// Ends the lookup with ``ReverseDNSLookupOutcome/cancelled`` unless it already has an outcome.
  /// Safe from any thread.
  func cancel() {
    resolve(.cancelled)
  }

  // MARK: - Any thread

  private var isResolved: Bool {
    lock.lock()
    defer { lock.unlock() }
    return outcome != nil
  }

  private func armDeadline(_ timeout: TimeInterval) {
    let timer = DispatchSource.makeTimerSource(queue: Self.timerQueue)
    // Capped so the conversion to nanoseconds cannot overflow.
    timer.schedule(deadline: .now() + min(timeout, 365 * 86400))
    timer.setEventHandler { [weak self] in self?.resolve(.timedOut) }
    // Activated before it can be cancelled: libdispatch traps on releasing a source that was
    // never activated.
    timer.activate()
    lock.lock()
    if outcome == nil {
      self.timer = timer
      lock.unlock()
    } else {
      lock.unlock()
      timer.cancel()
    }
  }

  /// Records the first outcome and resumes the caller with it; later calls do nothing. Off the
  /// queue, hops to it to deallocate.
  private func resolve(_ result: ReverseDNSLookupOutcome, onQueue: Bool = false) {
    lock.lock()
    guard outcome == nil else {
      lock.unlock()
      return
    }
    outcome = result
    let waiter = continuation
    continuation = nil
    let deadline = timer
    timer = nil
    lock.unlock()

    deadline?.cancel()
    waiter?.resume(returning: result)
    if onQueue {
      tearDown()
    } else {
      queue.async { self.tearDown() }
    }
  }

  // MARK: - On `queue`

  private func start() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !isResolved else {
      tearDown()
      return
    }
    let retained = Unmanaged.passRetained(CallbackContext(lookup: self))
    let (status, newRef) = calls.queryRecord(
      Self.flags, question.interfaceIndex, question.name, retained.toOpaque())
    guard status == DNSServiceStatus.noError, let newRef else {
      // No reference, so the daemon will never call back with this context.
      retained.release()
      resolve(
        .error(
          .startFailed(status == DNSServiceStatus.noError ? DNSServiceStatus.unknown : status)),
        onQueue: true)
      tearDown()
      return
    }
    ref = newRef
    context = retained

    let queued = calls.setDispatchQueue(newRef, queue)
    guard queued == DNSServiceStatus.noError else {
      resolve(.error(.dispatchQueueFailed(queued)), onQueue: true)
      tearDown()
      return
    }
    // A deadline or cancellation that arrived during the start call has already released the
    // caller, and the teardown it queued runs after this block, so it deallocates the reference
    // just made.
  }

  /// Deallocates the reference, then releases the callback context. Runs once.
  private func tearDown() {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !tornDown else { return }
    tornDown = true
    if let ref {
      calls.deallocate(ref)
      self.ref = nil
    }
    context?.release()
    context = nil
    onTornDown()
  }

  fileprivate func handleReply(
    flags: DNSServiceFlags, errorCode: DNSServiceErrorType, rrtype: UInt16,
    rdata: UnsafeRawBufferPointer
  ) {
    dispatchPrecondition(condition: .onQueue(queue))
    guard !tornDown, !isResolved else { return }
    let result: ReverseDNSLookupOutcome
    switch errorCode {
    case DNSServiceStatus.noError:
      // Remove events and intermediate records of another type say nothing about the name.
      guard flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
        rrtype == UInt16(kDNSServiceType_PTR)
      else { return }
      if let hostname = Self.hostname(fromPTR: rdata) {
        result = .answer(hostname)
      } else {
        result = .error(.malformedRecord)
      }
    case DNSServiceStatus.noSuchRecord, DNSServiceStatus.noSuchName:
      result = .noSuchRecord
    case DNSServiceStatus.timeout:
      result = .timedOut
    default:
      result = .error(.daemon(errorCode))
    }
    resolve(result, onQueue: true)
  }

  /// The hostname a PTR record's data names, in DNS presentation form without the trailing dot,
  /// or `nil` when the data is not exactly one well-formed, uncompressed domain name.
  ///
  /// The daemon delivers the name in wire form, uncompressed (measured: `one.one.one.one` arrives
  /// as `03 6f6e65 03 6f6e65 03 6f6e65 03 6f6e65 00`), so a compression pointer is malformed
  /// here, as are reserved label types, a label running past the data, data after the root label,
  /// a wire length over 255 bytes, and the root name alone.
  ///
  /// Labels are chosen by whoever runs the address's reverse zone, and may hold any byte. The
  /// result is printable ASCII only, and one label always reads as one label: `.` and `\` in a
  /// label are written `\.` and `\\`, and every byte outside `!` to `~` (space, control bytes,
  /// NUL, and each byte of non-ASCII UTF-8) is written `\DDD` in decimal. These are the escaping
  /// rules of `dns_sd.h` ("Notes on DNS Name Escaping"). An ordinary hostname (letters, digits,
  /// hyphens, underscores) is unchanged, and so equals what `getnameinfo` returns; `getnameinfo`
  /// itself escapes only `.`, and returns the other bytes raw and stops at a NUL (measured).
  static func hostname(fromPTR rdata: UnsafeRawBufferPointer) -> String? {
    let bytes = Array(rdata)
    guard bytes.count <= 255 else { return nil }
    var labels: [String] = []
    var offset = 0
    while true {
      guard offset < bytes.count else { return nil }
      let length = Int(bytes[offset])
      offset += 1
      if length == 0 { break }
      // 0xC0 is a compression pointer; 0x40 and 0x80 are reserved label types.
      guard length & 0xC0 == 0, offset + length <= bytes.count else { return nil }
      var label = ""
      for byte in bytes[offset..<(offset + length)] {
        switch byte {
        case UInt8(ascii: "."), UInt8(ascii: "\\"):
          label.append("\\")
          label.append(Character(Unicode.Scalar(byte)))
        case 0x21...0x7E:
          label.append(Character(Unicode.Scalar(byte)))
        default:
          let decimal = String(byte)
          label.append("\\" + String(repeating: "0", count: 3 - decimal.count) + decimal)
        }
      }
      labels.append(label)
      offset += length
    }
    guard offset == bytes.count, !labels.isEmpty else { return nil }
    return labels.joined(separator: ".")
  }

  /// What the daemon's callback is given: the lookup, held only through the query's reference.
  ///
  /// A separate object rather than the lookup itself, so its lifetime is exactly the context's:
  /// the retain made when the query starts is its only owner.
  final class CallbackContext {
    let lookup: ReverseDNSLookup
    init(lookup: ReverseDNSLookup) { self.lookup = lookup }
  }

  /// The callback `DNSServiceQueryRecord` is given. Its context is a retained ``CallbackContext``.
  static let reply: DNSServiceQueryRecordReply = {
    _, flags, _, errorCode, _, rrtype, _, rdlen, rdata, _, context in
    guard let context else { return }
    // Borrowed, not retained, so the callback adds no owner of its own.
    let lookup = Unmanaged<CallbackContext>.fromOpaque(context)._withUnsafeGuaranteedRef {
      $0.lookup
    }
    let bytes = UnsafeRawBufferPointer(start: rdata, count: rdata == nil ? 0 : Int(rdlen))
    lookup.handleReply(flags: flags, errorCode: errorCode, rrtype: rrtype, rdata: bytes)
  }
}
