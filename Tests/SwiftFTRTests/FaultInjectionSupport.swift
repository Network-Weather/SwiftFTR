import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

// Fixtures shared by the fault-injection battery (docs/ROBUSTNESS-TESTING.md). Everything here
// binds a loopback address on an ephemeral port; nothing sends a packet off the host.

// MARK: - Small synchronization helpers

/// Thread-safe counter readable from any context.
final class FaultCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  func increment() {
    lock.lock()
    count += 1
    lock.unlock()
  }
}

/// A gate that blocking substitutes wait on, so a stall ends when the test is done with it rather
/// than outliving the test on an executor thread.
final class StallGate: @unchecked Sendable {
  private let semaphore = DispatchSemaphore(value: 0)
  private let lock = NSLock()
  private var opened = false

  /// Blocks the calling thread until `open()` or `limit` seconds pass.
  func wait(limit: TimeInterval) {
    lock.lock()
    if opened {
      lock.unlock()
      return
    }
    lock.unlock()
    // Pass a wake-up from `open()` on, so every waiter is released by one call. A wait that
    // merely timed out must not, or it would release waiters the gate should still be holding.
    if semaphore.wait(timeout: .now() + limit) == .success { semaphore.signal() }
  }

  /// Suspends the calling task, without holding a cooperative thread, as ``wait(limit:)`` does.
  func waitAsync(limit: TimeInterval) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        self.wait(limit: limit)
        continuation.resume()
      }
    }
  }

  func open() {
    lock.lock()
    let wasOpen = opened
    opened = true
    lock.unlock()
    if !wasOpen { semaphore.signal() }
  }
}

/// Seconds elapsed while running `body`.
func measure<T>(_ body: () async throws -> T) async rethrows -> (T, TimeInterval) {
  let start = monotonicNow()
  let value = try await body()
  return (value, monotonicNow() - start)
}

/// Thrown by ``measure(within:_:)`` when the operation outlives its watchdog.
struct WatchdogExpired: Error, CustomStringConvertible {
  let limit: TimeInterval
  var description: String { "operation still running after the \(limit)s watchdog" }
}

/// Seconds elapsed while running `body`, or ``WatchdogExpired`` once `limit` seconds pass.
///
/// The operation runs in its own task and the watchdog does not wait for it to finish, so an
/// operation that never returns fails the test instead of hanging the run. The abandoned task is
/// cancelled.
func measure<T: Sendable>(
  within limit: TimeInterval, _ body: @escaping @Sendable () async throws -> T
) async throws -> (T, TimeInterval) {
  let start = monotonicNow()
  let outcome = WatchdogRace<T>()
  let work = Task {
    do {
      outcome.finish(.success(try await body()))
    } catch {
      outcome.finish(.failure(error))
    }
  }
  let watchdog = Task {
    try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
    outcome.finish(.failure(WatchdogExpired(limit: limit)))
  }
  let result = await outcome.value
  watchdog.cancel()
  if case .failure(let error) = result, error is WatchdogExpired { work.cancel() }
  return (try result.get(), monotonicNow() - start)
}

/// The first of an operation and its watchdog to finish.
private final class WatchdogRace<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var result: Result<T, Error>?
  private var waiter: CheckedContinuation<Result<T, Error>, Never>?

  var value: Result<T, Error> {
    get async {
      await withCheckedContinuation { continuation in
        lock.lock()
        if let result {
          lock.unlock()
          continuation.resume(returning: result)
        } else {
          waiter = continuation
          lock.unlock()
        }
      }
    }
  }

  func finish(_ outcome: Result<T, Error>) {
    lock.lock()
    guard result == nil else {
      lock.unlock()
      return
    }
    result = outcome
    let pending = waiter
    waiter = nil
    lock.unlock()
    pending?.resume(returning: outcome)
  }
}

/// Waits for `event`, or records a failure and throws once `limit` seconds pass, so an event that
/// never happens fails the test instead of hanging the run. The abandoned wait is left suspended.
func waitBounded(
  _ what: String, within limit: TimeInterval = 10,
  _ event: @escaping @Sendable () async -> Void
) async throws {
  do {
    _ = try await measure(within: limit) { await event() }
  } catch let expired as WatchdogExpired {
    Issue.record("\(what) never happened: \(expired)")
    throw expired
  }
}

/// Polls `condition` until it holds or `limit` seconds pass. Returns whether it held.
func eventually(
  within limit: TimeInterval, _ condition: @Sendable () async -> Bool
) async -> Bool {
  let giveUp = monotonicNow() + limit
  while monotonicNow() < giveUp {
    if await condition() { return true }
    try? await Task.sleep(nanoseconds: 5_000_000)
  }
  return await condition()
}

/// Runs `body` on a thread outside Swift's cooperative pool and reports whether it returned
/// within `limit` seconds. A call that never returns leaks its thread but cannot hang the suite.
func returnsWithin(_ limit: TimeInterval, _ body: @escaping @Sendable () -> Void) async -> Bool {
  let done = DispatchSemaphore(value: 0)
  Thread.detachNewThread {
    body()
    done.signal()
  }
  return await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      continuation.resume(returning: done.wait(timeout: .now() + limit) == .success)
    }
  }
}

enum FixtureError: Error {
  case socket(String, Int32)
}

// MARK: - Loopback addresses

func loopbackAddress(family: Int32, port: UInt16) -> (sockaddr_storage, socklen_t) {
  var storage = sockaddr_storage()
  if family == AF_INET6 {
    var sin6 = sockaddr_in6()
    sin6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    sin6.sin6_family = sa_family_t(AF_INET6)
    sin6.sin6_port = port.bigEndian
    sin6.sin6_addr = in6addr_loopback
    withUnsafeMutableBytes(of: &storage) { dst in
      withUnsafeBytes(of: sin6) { dst.copyMemory(from: $0) }
    }
    return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
  }
  var sin = sockaddr_in()
  sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  sin.sin_family = sa_family_t(AF_INET)
  sin.sin_port = port.bigEndian
  sin.sin_addr.s_addr = inet_addr("127.0.0.1")
  withUnsafeMutableBytes(of: &storage) { dst in
    withUnsafeBytes(of: sin) { dst.copyMemory(from: $0) }
  }
  return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
}

/// Opens a socket bound to loopback on an ephemeral port and returns it with the port.
func bindLoopback(family: Int32, type: Int32) throws -> (fd: Int32, port: UInt16) {
  let fd = socket(family, type, 0)
  guard fd >= 0 else { throw FixtureError.socket("socket", errno) }
  var on: Int32 = 1
  _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
  var (address, length) = loopbackAddress(family: family, port: 0)
  let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
  }
  guard bound == 0 else {
    let code = errno
    close(fd)
    throw FixtureError.socket("bind", code)
  }
  var actual = sockaddr_storage()
  var actualLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
  _ = withUnsafeMutablePointer(to: &actual) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &actualLength) }
  }
  let port: UInt16 = withUnsafeBytes(of: actual) { raw in
    // sin_port and sin6_port share an offset.
    UInt16(bigEndian: raw.load(fromByteOffset: 2, as: UInt16.self))
  }
  return (fd, port)
}

func setReceiveTimeout(_ fd: Int32, seconds: TimeInterval) {
  var tv = timeval(
    tv_sec: Int(seconds), tv_usec: __darwin_suseconds_t((seconds - floor(seconds)) * 1_000_000))
  _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
}

// MARK: - Fake ICMP network

// Darwin's IPv6 socket options that the Swift overlay does not export.
private let ipv6RecvHopLimit: Int32 = 37  // IPV6_RECVHOPLIMIT
private let ipv6HopLimit: Int32 = 47  // IPV6_HOPLIMIT

/// A loopback stand-in for the network a trace or ping probes.
///
/// Bound through ``TestSeams``, a trace resolves its destination to this peer and sends its real
/// echo requests over a loopback UDP socket instead of an ICMP one. The peer hands each request to
/// a script, which returns the datagrams to send back and when. Replies arrive at the trace's own
/// receive loop and parser exactly as kernel-delivered ICMP would, so silence, late replies,
/// truncation, garbage and foreign identifiers can all be staged without privileges.
///
/// Replies always come from the loopback address, so every hop of a staged path has that address.
final class FakeICMPNetwork: @unchecked Sendable {
  struct Probe: Sendable {
    let identifier: UInt16
    let sequence: UInt16
    /// The hop limit the probe was sent with (its TTL), read from ancillary data.
    let hopLimit: Int?
  }

  struct Reply: Sendable {
    let bytes: [UInt8]
    let delay: TimeInterval
    /// The IPv6 hop limit to send this reply with, which the receiver reads from ancillary data.
    /// `nil` sends with the system default. Ignored on IPv4, whose receive loop reads the TTL
    /// from an IP header carried in `bytes` instead.
    let hopLimit: Int32?

    init(_ bytes: [UInt8], after delay: TimeInterval = 0, hopLimit: Int32? = nil) {
      self.bytes = bytes
      self.delay = delay
      self.hopLimit = hopLimit
    }
  }

  typealias Script = @Sendable (Probe) -> [Reply]

  let family: Int32
  let port: UInt16
  let probes = FaultCounter()

  /// Owned by the serve thread, which closes it as it exits.
  private let fd: Int32
  private let script: Script
  private let lock = NSLock()
  private var stopped = false
  private let socketsLock = NSLock()
  private var openedSockets: [Int32] = []

  init(family: Int32 = AF_INET, script: @escaping Script) throws {
    self.family = family
    self.script = script
    (fd, port) = try bindLoopback(family: family, type: SOCK_DGRAM)
    setReceiveTimeout(fd, seconds: 0.02)
    var on: Int32 = 1
    if family == AF_INET6 {
      _ = setsockopt(
        fd, IPPROTO_IPV6, ipv6RecvHopLimit, &on, socklen_t(MemoryLayout<Int32>.size))
    } else {
      _ = setsockopt(fd, IPPROTO_IP, IP_RECVTTL, &on, socklen_t(MemoryLayout<Int32>.size))
    }
    let thread = Thread { [self] in self.serve() }
    thread.start()
  }

  deinit { stop() }

  /// The destination a trace should resolve to: this peer.
  var resolved: ResolvedHost {
    let (address, length) = loopbackAddress(family: family, port: port)
    return ResolvedHost(
      family: family, address: address, addressLen: length,
      canonical: family == AF_INET6 ? "::1" : "127.0.0.1")
  }

  /// Opens the socket a trace sends on: a UDP socket of the requested family.
  func makeSocket(_ requestedFamily: Int32) throws -> Int32 {
    let s = socket(requestedFamily, SOCK_DGRAM, IPPROTO_UDP)
    guard s >= 0 else {
      throw TracerouteError.socketCreateFailed(errno: errno, details: "fake network socket")
    }
    socketsLock.lock()
    openedSockets.append(s)
    socketsLock.unlock()
    return s
  }

  /// Number of sockets the library opened through this network.
  var socketsOpened: Int {
    socketsLock.lock()
    defer { socketsLock.unlock() }
    return openedSockets.count
  }

  /// Runs `body` with forward resolution and the ICMP socket factory pointed at this network, or
  /// at `socketFactory` when one is given.
  ///
  /// Public-IP discovery is substituted too: by the test's own substitute when one is bound, and
  /// otherwise by one that fails at once, so a classified trace inside `body` can never fall
  /// through to real STUN traffic.
  func install<T>(
    socketFactory: TestSeams.MakeICMPSocket? = nil, _ body: () async throws -> T
  ) async rethrows -> T {
    let resolved = self.resolved
    let resolve: TestSeams.ResolveHost = { _, _ in resolved }
    let makeSocket: TestSeams.MakeICMPSocket = socketFactory ?? { try self.makeSocket($0) }
    let discover: TestSeams.DiscoverPublicIPv4 =
      TestSeams.discoverPublicIPv4 ?? {
        throw PublicIPError.allMethodsFailed(stunError: "offline test", dnsError: "offline test")
      }
    return try await TestSeams.$resolveHost.withValue(resolve) {
      try await TestSeams.$makeICMPSocket.withValue(makeSocket) {
        try await TestSeams.$discoverPublicIPv4.withValue(discover) {
          try await body()
        }
      }
    }
  }

  /// Stops answering, without waiting: no reply is sent once this returns, and the serve thread
  /// closes the peer's socket when it next wakes, within its 20 ms receive timeout. Safe to call
  /// from `defer` in an async test, since it parks no thread.
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  private func serve() {
    // The serve thread owns `fd`. It closes it under the lock that `send` checks `stopped` under,
    // and only once `stopped` is set, so nothing sends on the number after it is closed and
    // perhaps handed to another test's socket.
    defer {
      lock.lock()
      close(fd)
      lock.unlock()
    }
    var buffer = [UInt8](repeating: 0, count: 4096)
    var control = [UInt8](repeating: 0, count: 128)
    while true {
      lock.lock()
      let done = stopped
      lock.unlock()
      if done { return }

      var source = sockaddr_storage()
      var hopLimit: Int?
      let received = buffer.withUnsafeMutableBytes { raw -> Int in
        control.withUnsafeMutableBytes { ctl -> Int in
          withUnsafeMutablePointer(to: &source) { sp -> Int in
            var iov = iovec(iov_base: raw.baseAddress, iov_len: raw.count)
            return withUnsafeMutablePointer(to: &iov) { iovp -> Int in
              var msg = msghdr()
              msg.msg_name = UnsafeMutableRawPointer(sp)
              msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
              msg.msg_iov = iovp
              msg.msg_iovlen = 1
              msg.msg_control = ctl.baseAddress
              msg.msg_controllen = socklen_t(ctl.count)
              let n = recvmsg(fd, &msg, 0)
              if n >= 0 { hopLimit = Self.hopLimit(from: msg) }
              return n
            }
          }
        }
      }
      // A probe that arrives after `stop()` is neither counted nor scripted.
      if isStopped { return }
      guard received >= 8 else { continue }
      let bytes = Array(buffer.prefix(received))
      let requestType: UInt8 = family == AF_INET6 ? 128 : 8
      guard bytes[0] == requestType else { continue }
      let probe = Probe(
        identifier: UInt16(bytes[4]) << 8 | UInt16(bytes[5]),
        sequence: UInt16(bytes[6]) << 8 | UInt16(bytes[7]),
        hopLimit: hopLimit)
      probes.increment()
      for reply in script(probe) {
        if reply.delay <= 0 {
          send(reply.bytes, to: source, hopLimit: reply.hopLimit)
        } else {
          // Captured by value: `source` is a `var` (the receive writes into it), though nothing
          // writes it once this datagram has been read.
          DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { [source] in
            self.send(reply.bytes, to: source, hopLimit: reply.hopLimit)
          }
        }
      }
    }
  }

  /// Sends `reply` now, from this network's address, to the socket `fd` is bound to, as if it
  /// answered a probe from `fd`. Returns false if `fd` has no local address yet (it binds on its
  /// first send).
  @discardableResult
  func inject(_ reply: Reply, to fd: Int32) -> Bool {
    var address = sockaddr_storage()
    var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let named = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    let port = withUnsafeBytes(of: address) {
      UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self))
    }
    guard named == 0, port != 0 else { return false }
    // A socket bound to the wildcard address is reached on loopback.
    let (destination, _) = loopbackAddress(family: family, port: port)
    send(reply.bytes, to: destination, hopLimit: reply.hopLimit)
    return true
  }

  private func send(_ bytes: [UInt8], to destination: sockaddr_storage, hopLimit: Int32?) {
    lock.lock()
    defer { lock.unlock() }
    // Closed under the same lock, so a late reply never reaches a recycled descriptor.
    guard !stopped else { return }
    if family == AF_INET6 {
      // Set on every send, under the lock, so one reply's hop limit never leaks into the next.
      // -1 restores the system default.
      var hops: Int32 = hopLimit ?? -1
      _ = setsockopt(
        fd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &hops, socklen_t(MemoryLayout<Int32>.size))
    }
    var destination = destination
    let length = socklen_t(destination.ss_len)
    _ = bytes.withUnsafeBytes { raw in
      withUnsafePointer(to: &destination) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          sendto(fd, raw.baseAddress, raw.count, 0, $0, length)
        }
      }
    }
  }

  private static func hopLimit(from msg: msghdr) -> Int? {
    guard msg.msg_controllen > 0, let base = msg.msg_control else { return nil }
    let header = base.assumingMemoryBound(to: cmsghdr.self).pointee
    guard header.cmsg_len >= socklen_t(MemoryLayout<cmsghdr>.size) else { return nil }
    let data = base.advanced(by: MemoryLayout<cmsghdr>.size)
    if header.cmsg_level == IPPROTO_IP, header.cmsg_type == IP_RECVTTL {
      return Int(data.load(as: UInt8.self))
    }
    if header.cmsg_level == IPPROTO_IPV6, header.cmsg_type == ipv6HopLimit {
      return Int(data.loadUnaligned(as: Int32.self))
    }
    return nil
  }
}

// MARK: - ICMP datagram builders

/// ICMP datagrams as the library's receive loop sees them on a datagram socket.
enum ICMPWire {
  static func echoReply(family: Int32, id: UInt16, seq: UInt16) -> [UInt8] {
    [family == AF_INET6 ? 129 : 0, 0, 0, 0, hi(id), lo(id), hi(seq), lo(seq)]
      + [UInt8](repeating: 0x61, count: 8)
  }

  static func timeExceeded(family: Int32, id: UInt16, seq: UInt16) -> [UInt8] {
    error(family: family, type: family == AF_INET6 ? 3 : 11, code: 0, id: id, seq: seq)
  }

  static func unreachable(family: Int32, code: UInt8, id: UInt16, seq: UInt16) -> [UInt8] {
    error(family: family, type: family == AF_INET6 ? 1 : 3, code: code, id: id, seq: seq)
  }

  /// An ICMP error quoting the original IP header and the echo request that triggered it.
  static func error(family: Int32, type: UInt8, code: UInt8, id: UInt16, seq: UInt16) -> [UInt8] {
    let header: [UInt8] = [type, code, 0, 0, 0, 0, 0, 0]
    let inner: [UInt8] = [family == AF_INET6 ? 128 : 8, 0, 0, 0, hi(id), lo(id), hi(seq), lo(seq)]
    if family == AF_INET6 {
      var ip = [UInt8](repeating: 0, count: 40)
      ip[0] = 0x60
      ip[5] = 8
      ip[6] = UInt8(IPPROTO_ICMPV6)
      ip[7] = 1
      return header + ip + inner
    }
    var ip = [UInt8](repeating: 0, count: 20)
    ip[0] = 0x45
    ip[3] = 28
    ip[8] = 1
    ip[9] = UInt8(IPPROTO_ICMP)
    return header + ip + inner
  }

  private static func hi(_ v: UInt16) -> UInt8 { UInt8(v >> 8) }
  private static func lo(_ v: UInt16) -> UInt8 { UInt8(v & 0xFF) }
}

/// A path of `destinationTTL` hops: every probe below it is answered with time-exceeded and every
/// probe at or above it with an echo reply.
func pathScript(family: Int32 = AF_INET, destinationTTL: Int, after delay: TimeInterval = 0)
  -> FakeICMPNetwork.Script
{
  { probe in
    let ttl = probe.hopLimit ?? Int(probe.sequence)
    let bytes =
      ttl < destinationTTL
      ? ICMPWire.timeExceeded(family: family, id: probe.identifier, seq: probe.sequence)
      : ICMPWire.echoReply(family: family, id: probe.identifier, seq: probe.sequence)
    return [FakeICMPNetwork.Reply(bytes, after: delay)]
  }
}

// MARK: - Loopback TCP server

/// A loopback TCP listener whose behaviour after accepting is scripted per test.
///
/// Each accepted connection belongs to the thread that handles it, which is the only code that
/// reads, writes or closes it, and the listening socket belongs to the accept loop's thread. `stop()`
/// only shuts connections down, under the lock a handler holds to withdraw its connection before
/// closing it, which wakes any pending I/O. So a descriptor number is never touched after it is
/// closed, and a parallel test that is handed the same number is never disturbed. `stop()` does not
/// wait for the threads to finish; ``stopAndWait()`` does.
final class LoopbackTCPServer: @unchecked Sendable {
  enum Behavior: Sendable {
    /// Accept, then never read or write.
    case silent
    /// Accept, read the request, write `prefix`, then reset the connection.
    case resetAfter(prefix: [UInt8])
    /// Accept, read the request, wait `delay`, then write `response` and close.
    case respond(response: [UInt8], after: TimeInterval)
    /// Accept and close at once, without writing.
    case closeImmediately
    /// Accept, read the request, write `response`, then hold the connection open, sending
    /// nothing more, until `stop()`.
    case respondThenHold(response: [UInt8])
  }

  let port: UInt16
  let accepted = FaultCounter()

  private let fd: Int32
  private let behavior: Behavior
  private let exitGate: StallGate?
  private let lock = NSLock()
  private var stopped = false
  /// Connections whose handler has not closed them yet.
  private var live: Set<Int32> = []
  /// The accept loop and every handler, until each has closed its descriptor.
  private let threads = DispatchGroup()
  /// Signalled once by `stop()`; handlers that wait use it instead of sleeping.
  private let stopping = DispatchSemaphore(value: 0)

  /// - Parameter exitGate: When given, every handler waits on it just before closing its
  ///   connection, so a test can observe which teardown waits for handlers.
  init(family: Int32 = AF_INET, behavior: Behavior, exitGate: StallGate? = nil) throws {
    self.exitGate = exitGate
    self.behavior = behavior
    // Held in locals until `listen` succeeds. Once every stored property is set, a throwing
    // initializer runs `deinit`, and `stop()` would wait for an accept loop that never started.
    let (bound, boundPort) = try bindLoopback(family: family, type: SOCK_STREAM)
    guard listen(bound, 64) == 0 else {
      let code = errno
      close(bound)
      throw FixtureError.socket("listen", code)
    }
    fd = bound
    port = boundPort
    threads.enter()
    let thread = Thread { [self] in self.acceptLoop() }
    thread.start()
  }

  deinit { stop() }

  /// Stops accepting and shuts every connection down, without waiting: handlers end on their own
  /// threads, and the accept loop closes the listener within its 20 ms poll. Safe to call from
  /// `defer` in an async test, since it parks no thread.
  func stop() {
    lock.lock()
    let wasStopped = stopped
    stopped = true
    // Wake every handler: pending reads return, and waits on `stopping` end. A connection still
    // in `live` has not been closed by its handler, which withdraws it under this lock first.
    if !wasStopped {
      for connection in live { _ = shutdown(connection, SHUT_RDWR) }
    }
    lock.unlock()
    if !wasStopped { stopping.signal() }
  }

  /// Stops the server as ``stop()`` does, then suspends, without holding a thread, until the
  /// accept loop and every handler have closed their descriptors.
  func stopAndWait() async {
    stop()
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      threads.notify(queue: .global()) { continuation.resume() }
    }
  }

  private func acceptLoop() {
    defer {
      close(fd)
      threads.leave()
    }
    while true {
      lock.lock()
      let done = stopped
      lock.unlock()
      if done { return }
      var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
      guard poll(&pfd, 1, 20) > 0 else { continue }
      let client = accept(fd, nil, nil)
      guard client >= 0 else { continue }
      lock.lock()
      // Accepted after `stop()` shut the others down: nothing would wake its handler.
      guard !stopped else {
        lock.unlock()
        close(client)
        return
      }
      live.insert(client)
      // Entered before the accept loop leaves, so the group cannot drain while a handler runs.
      threads.enter()
      // Counted only once the handler is certain to run, and under the lock `stop()` takes, so a
      // test that has seen the count knows a handler is live for this connection.
      accepted.increment()
      lock.unlock()
      let behavior = self.behavior
      Thread.detachNewThread { [self] in
        defer { threads.leave() }
        self.handle(client, behavior)
      }
    }
  }

  /// Runs on the connection's own thread, which owns `client` until it closes it here.
  private func handle(_ client: Int32, _ behavior: Behavior) {
    var reset = false
    switch behavior {
    case .silent:
      waitForStop(limit: .infinity)
    case .closeImmediately:
      break
    case .resetAfter(let prefix):
      readRequest(client)
      write(prefix, to: client)
      reset = true
    case .respond(let response, let delay):
      readRequest(client)
      waitForStop(limit: delay)
      write(response, to: client)
    case .respondThenHold(let response):
      readRequest(client)
      write(response, to: client)
      waitForStop(limit: .infinity)
    }
    // A test can hold the handler here to prove stop() does not wait for it, and stopAndWait()
    // does.
    exitGate?.wait(limit: 30)
    lock.lock()
    live.remove(client)
    lock.unlock()
    if reset {
      var option = Darwin.linger(l_onoff: 1, l_linger: 0)
      _ = setsockopt(
        client, SOL_SOCKET, SO_LINGER, &option, socklen_t(MemoryLayout<Darwin.linger>.size))
    }
    close(client)
  }

  /// Waits until `stop()` or `limit` seconds, passing a stop on to the next waiting handler.
  private func waitForStop(limit: TimeInterval) {
    let deadline: DispatchTime = limit.isFinite ? .now() + limit : .distantFuture
    if stopping.wait(timeout: deadline) == .success { stopping.signal() }
  }

  private func readRequest(_ client: Int32) {
    setReceiveTimeout(client, seconds: 1)
    var buffer = [UInt8](repeating: 0, count: 4096)
    _ = recv(client, &buffer, buffer.count, 0)
  }

  private func write(_ bytes: [UInt8], to client: Int32) {
    _ = bytes.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, Int32(MSG_NOSIGNAL)) }
  }
}

/// A loopback TCP port that refuses connections, reserved for the fixture's lifetime.
///
/// The port belongs to a socket that is connected to a private listener, so it stays allocated
/// (no other socket is handed it) while no listener is bound to it, and a SYN to it is answered
/// with a reset. A socket that is merely bound to the port without listening does not work:
/// Darwin drops the SYN, which looks like a filtered port.
final class RefusingTCPPort: @unchecked Sendable {
  let port: UInt16
  private let descriptors: [Int32]

  init(family: Int32 = AF_INET) throws {
    let (listener, listenerPort) = try bindLoopback(family: family, type: SOCK_STREAM)
    guard listen(listener, 1) == 0 else {
      let code = errno
      close(listener)
      throw FixtureError.socket("listen", code)
    }
    let holder = socket(family, SOCK_STREAM, 0)
    guard holder >= 0 else {
      close(listener)
      throw FixtureError.socket("socket", errno)
    }
    var (address, length) = loopbackAddress(family: family, port: listenerPort)
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(holder, $0, length) }
    }
    let accepted = connected == 0 ? accept(listener, nil, nil) : -1
    guard accepted >= 0 else {
      let code = errno
      close(holder)
      close(listener)
      throw FixtureError.socket("connect", code)
    }
    var local = sockaddr_storage()
    var localLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
    _ = withUnsafeMutablePointer(to: &local) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(holder, $0, &localLength) }
    }
    port = withUnsafeBytes(of: local) {
      UInt16(bigEndian: $0.load(fromByteOffset: 2, as: UInt16.self))
    }
    descriptors = [holder, accepted, listener]
  }

  deinit { for descriptor in descriptors { close(descriptor) } }
}

/// A loopback UDP port that answers every datagram with ICMP port-unreachable, reserved for the
/// fixture's lifetime.
///
/// The port belongs to a socket connected to another loopback address, so the kernel delivers it
/// only datagrams from that peer and answers everyone else as it would for an unbound port, while
/// no other socket can be handed the number.
final class RefusingUDPPort: @unchecked Sendable {
  let port: UInt16
  private let fd: Int32

  init(family: Int32 = AF_INET) throws {
    let (bound, boundPort) = try bindLoopback(family: family, type: SOCK_DGRAM)
    // Port 9 (discard): connecting a datagram socket sends nothing; it only fixes the peer.
    var (peer, length) = loopbackAddress(family: family, port: 9)
    let connected = withUnsafePointer(to: &peer) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(bound, $0, length) }
    }
    guard connected == 0 else {
      let code = errno
      close(bound)
      throw FixtureError.socket("connect", code)
    }
    fd = bound
    port = boundPort
  }

  deinit { close(fd) }
}

// MARK: - Loopback UDP responder

/// A loopback UDP server that answers each datagram as a test scripts: not at all, late, or with
/// arbitrary bytes.
final class LoopbackUDPResponder: @unchecked Sendable {
  typealias Script = @Sendable (_ request: [UInt8]) -> (reply: [UInt8], delay: TimeInterval)?

  let port: UInt16
  let family: Int32
  let requests = FaultCounter()

  /// Owned by the serve thread, which closes it as it exits.
  private let fd: Int32
  private let script: Script
  private let lock = NSLock()
  private var stopped = false

  init(family: Int32 = AF_INET, script: @escaping Script) throws {
    self.family = family
    self.script = script
    (fd, port) = try bindLoopback(family: family, type: SOCK_DGRAM)
    setReceiveTimeout(fd, seconds: 0.02)
    let thread = Thread { [self] in self.serve() }
    thread.start()
  }

  deinit { stop() }

  var address: (sockaddr_storage, socklen_t) { loopbackAddress(family: family, port: port) }

  /// Stops answering, without waiting: no reply is sent once this returns, delayed ones included,
  /// and the serve thread closes the socket when it next wakes, within its 20 ms receive timeout.
  /// Safe to call from `defer` in an async test, since it parks no thread.
  func stop() {
    lock.lock()
    stopped = true
    lock.unlock()
  }

  private var isStopped: Bool {
    lock.lock()
    defer { lock.unlock() }
    return stopped
  }

  private func serve() {
    // The serve thread owns `fd`. It closes it under the lock that a delivery checks `stopped`
    // under, and only once `stopped` is set, so nothing sends on the number after it is closed
    // and perhaps handed to another test's socket.
    defer {
      lock.lock()
      close(fd)
      lock.unlock()
    }
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
      lock.lock()
      let done = stopped
      lock.unlock()
      if done { return }
      var source = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let n = buffer.withUnsafeMutableBytes { raw in
        withUnsafeMutablePointer(to: &source) {
          $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
          }
        }
      }
      // A request that arrives after `stop()` is neither counted nor scripted.
      if isStopped { return }
      // A zero-byte datagram is a valid request; only a failed or timed-out receive is not.
      guard n >= 0 else { continue }
      requests.increment()
      guard let (reply, delay) = script(Array(buffer.prefix(n))) else { continue }
      let deliver: @Sendable () -> Void = { [self, source, length] in
        self.lock.lock()
        defer { self.lock.unlock() }
        guard !self.stopped else { return }
        var destination = source
        _ = reply.withUnsafeBytes { raw in
          withUnsafePointer(to: &destination) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              sendto(self.fd, raw.baseAddress, raw.count, 0, $0, length)
            }
          }
        }
      }
      if delay <= 0 {
        deliver()
      } else {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
      }
    }
  }
}

// MARK: - Stub resolvers

/// An ASN resolver that answers at once with nothing, so classification never reaches the network.
struct EmptyASNResolver: ASNResolver {
  func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
    [:]
  }
}

/// A reverse-DNS cache whose lookups stall until `gate` opens or `limit` passes, ignoring
/// cancellation the way a blocked `getnameinfo` does.
func stallingRDNSCache(gate: StallGate, limit: TimeInterval, deadline: TimeInterval = 30)
  -> RDNSCache
{
  RDNSCache(lookupDeadline: deadline) { _ in
    await withCheckedContinuation { continuation in
      DispatchQueue.global().async {
        gate.wait(limit: limit)
        continuation.resume(returning: nil)
      }
    }
  }
}

/// A tracer whose reverse DNS and ASN enrichment are local stubs, so no test of the probe window
/// reaches the system resolver.
func offlineTracer(
  _ config: SwiftFTRConfig,
  rdns: RDNSCache = RDNSCache { _ in nil },
  publicIP: String? = nil
) -> SwiftFTR {
  SwiftFTR(
    config: config, rdnsCache: rdns, asnResolver: EmptyASNResolver(), cachedPublicIP: publicIP)
}

// MARK: - Offline substitutes for live dependencies

/// A loopback TCP port that never answers a connection attempt, reserved for the fixture's
/// lifetime.
///
/// The port belongs to a socket that is bound but not listening. Darwin drops a SYN to such a
/// port rather than resetting it (see ``RefusingTCPPort``), so a client sees what it sees for a
/// host that does not answer: its connect waits until its own timeout.
final class SilentTCPPort: @unchecked Sendable {
  let port: UInt16
  private let fd: Int32

  init(family: Int32 = AF_INET) throws {
    (fd, port) = try bindLoopback(family: family, type: SOCK_STREAM)
  }

  deinit { close(fd) }
}

/// Public-IP discovery that finds nothing, at once, and counts how often it was asked.
///
/// A classification that is given no public address starts discovery, which is live STUN with a
/// DNS fallback unless a substitute is bound. Run such a call inside ``install(_:)`` so it never
/// reaches the network, and read ``calls`` to check that discovery reached this substitute.
final class OfflinePublicIPDiscovery: Sendable {
  let calls = FaultCounter()

  func install<T>(_ body: () async throws -> T) async rethrows -> T {
    let calls = self.calls
    let discover: TestSeams.DiscoverPublicIPv4 = {
      calls.increment()
      throw PublicIPError.allMethodsFailed(stunError: "offline test", dnsError: "offline test")
    }
    return try await TestSeams.$discoverPublicIPv4.withValue(discover) { try await body() }
  }
}

/// A complete HTTP/1.1 response with `status` and an empty body, for ``LoopbackTCPServer``.
func httpResponse(status: Int, reason: String) -> [UInt8] {
  Array("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
}
