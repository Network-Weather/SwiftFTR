import Foundation

#if canImport(Darwin)
  import Darwin
#endif

// Darwin socket constant not bridged into Swift's `Darwin` overlay.
// `IPV6_RECVHOPLIMIT = 37` per `<netinet6/in6.h>`; instructs the kernel to deliver
// the hop limit of incoming packets as ancillary data on `recvmsg`. Stable since
// macOS 10.x. Naming mirrors the C macro for cross-reference clarity.
// swift-format-ignore: AlwaysUseLowerCamelCase
private let IPV6_RECVHOPLIMIT_OPT: Int32 = 37
// `IPV6_HOPLIMIT` cmsg type varies by which RFC API the SDK selects: 20 (RFC 2292,
// the default without `_DARWIN_C_SOURCE`) or 47 (RFC 3542). Accept both when scanning
// ancillary data.
// swift-format-ignore: AlwaysUseLowerCamelCase
private let IPV6_HOPLIMIT_CMSG_2292: Int32 = 20
// swift-format-ignore: AlwaysUseLowerCamelCase
private let IPV6_HOPLIMIT_CMSG_3542: Int32 = 47

/// Preferred IP family for a SwiftFTR operation. Default `.auto`: literal IPs use
/// the literal's family; hostnames take the first `getaddrinfo(AF_UNSPEC)` answer.
///
/// Use `.v4` or `.v6` to force a specific family — e.g. to test a v6-only path even
/// when the target hostname resolves to both A and AAAA records.
public enum PreferredFamily: Sendable, Codable {
  /// Auto-detect: literal IPs use their literal family; hostnames take the first
  /// resolver answer with no family preference.
  case auto
  /// Force IPv4. Throws `resolutionFailed` if the target cannot be resolved to v4.
  case v4
  /// Force IPv6. Throws `resolutionFailed` if the target cannot be resolved to v6.
  case v6
}

/// Configuration for ping operations
public struct PingConfig: Sendable {
  /// Number of pings to send (default: 5)
  public let count: Int

  /// Interval between pings in seconds (default: 1.0)
  public let interval: TimeInterval

  /// Timeout for each ping in seconds (default: 2.0)
  public let timeout: TimeInterval

  /// ICMP payload size in bytes (default: 56)
  public let payloadSize: Int

  /// Network interface to bind to for this operation.
  public let interface: String?

  /// Source IP address to bind to for this operation. Family auto-detected from
  /// the supplied address — pass an IPv4 string for v4 ops, an IPv6 string (with
  /// optional `%zone` suffix for link-local) for v6 ops.
  public let sourceIP: String?

  /// IP family preference. Defaults to `.auto` (let the resolved address decide).
  public let preferredFamily: PreferredFamily

  public init(
    count: Int = 5,
    interval: TimeInterval = 1.0,
    timeout: TimeInterval = 2.0,
    payloadSize: Int = 56,
    interface: String? = nil,
    sourceIP: String? = nil,
    preferredFamily: PreferredFamily = .auto
  ) {
    self.count = count
    self.interval = interval
    self.timeout = timeout
    self.payloadSize = payloadSize
    self.interface = interface
    self.sourceIP = sourceIP
    self.preferredFamily = preferredFamily
  }
}

/// Result from a ping operation
public struct PingResult: Sendable, Codable {
  public let target: String
  public let resolvedIP: String
  public let responses: [PingResponse]
  public let statistics: PingStatistics

  public init(
    target: String,
    resolvedIP: String,
    responses: [PingResponse],
    statistics: PingStatistics
  ) {
    self.target = target
    self.resolvedIP = resolvedIP
    self.responses = responses
    self.statistics = statistics
  }
}

/// Individual ping response
public struct PingResponse: Sendable, Codable {
  public let sequence: Int
  public let rtt: TimeInterval?
  /// For IPv4 replies: the TTL field from the IP header (RFC 791 §3.1). For IPv6
  /// replies: the IPv6 hop limit, delivered via `recvmsg` ancillary data
  /// (`IPV6_HOPLIMIT` cmsg). Same field, same units (1–255); the family is
  /// implicit from the `PingResult.resolvedIP` form.
  public let ttl: Int?
  public let timestamp: Date

  public var didTimeout: Bool { rtt == nil }

  public init(sequence: Int, rtt: TimeInterval?, ttl: Int?, timestamp: Date) {
    self.sequence = sequence
    self.rtt = rtt
    self.ttl = ttl
    self.timestamp = timestamp
  }
}

/// Computed ping statistics
public struct PingStatistics: Sendable, Codable {
  public let sent: Int
  public let received: Int
  public let packetLoss: Double
  public let minRTT: TimeInterval?
  public let avgRTT: TimeInterval?
  public let maxRTT: TimeInterval?
  public let jitter: TimeInterval?

  public init(
    sent: Int,
    received: Int,
    packetLoss: Double,
    minRTT: TimeInterval?,
    avgRTT: TimeInterval?,
    maxRTT: TimeInterval?,
    jitter: TimeInterval?
  ) {
    self.sent = sent
    self.received = received
    self.packetLoss = packetLoss
    self.minRTT = minRTT
    self.avgRTT = avgRTT
    self.maxRTT = maxRTT
    self.jitter = jitter
  }
}

/// Parsed ICMP message relevant to a ping operation
enum ParsedPingMessage {
  case echoReply(sequence: UInt16, ttl: Int?)
  case timeExceeded(originalSequence: UInt16, ttl: Int?, code: UInt8)
  case destinationUnreachable(originalSequence: UInt16, ttl: Int?, code: UInt8)
}

/// Thread-safe collector (Kept for tests compatibility, though mostly superseded by PingOperation logic)
final class ResponseCollector: @unchecked Sendable {
  private var sentTimes: [Int: TimeInterval] = [:]
  private var receiveTimes: [Int: TimeInterval] = [:]
  private var ttls: [Int: Int] = [:]
  private let lock = NSLock()

  func recordSend(seq: Int, sendTime: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    sentTimes[seq] = sendTime
  }

  func recordResponse(seq: Int, receiveTime: TimeInterval, ttl: Int?) {
    lock.lock()
    defer { lock.unlock() }
    receiveTimes[seq] = receiveTime
    if let ttl = ttl {
      ttls[seq] = ttl
    }
  }

  func getResponseCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return receiveTimes.count
  }

  func getResults() -> ([Int: TimeInterval], [Int: TimeInterval], [Int: Int]) {
    lock.lock()
    defer { lock.unlock() }
    return (sentTimes, receiveTimes, ttls)
  }
}

/// Internal ping implementation
struct PingExecutor: Sendable {
  private let swiftFTRConfig: SwiftFTRConfig

  init(config: SwiftFTRConfig) {
    self.swiftFTRConfig = config
  }

  #if compiler(>=6.2)
    @concurrent
  #endif
  /// Perform ping operation. Dispatches on the resolved destination's family —
  /// IPv4 via `IPPROTO_ICMP`, IPv6 via `IPPROTO_ICMPV6`. Each call allocates its
  /// own ephemeral socket, so concurrent `ping()` calls from a shared `SwiftFTR`
  /// instance never share identifier/sequence space (NWX contract).
  func ping(to target: String, config: PingConfig) async throws -> PingResult {
    // 1. Resolve target, honoring PreferredFamily.
    let resolved = try resolveHost(host: target, prefer: config.preferredFamily)

    // 2. Create datagram ICMP socket for the resolved family.
    let sockfd = try createICMPSocket(family: resolved.family)

    // 3. Apply interface/sourceIP bindings (operation config overrides global).
    try applyBindings(sockfd: sockfd, family: resolved.family, pingConfig: config)

    // 4. Set non-blocking mode.
    try setNonBlocking(sockfd: sockfd)

    // 4b. Increase receive buffer.
    var recvBufSize: Int32 = 256 * 1024
    _ = setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, &recvBufSize, socklen_t(MemoryLayout<Int32>.size))

    // 4c. Unique identifier per ping session to avoid cross-socket collisions.
    let identifier = generateIdentifier()

    // 5. Delegate to PingOperation (which knows the family for parse-time dispatch).
    let operation = PingOperation(
      sockfd: sockfd,
      target: target,
      resolved: resolved,
      config: config,
      identifier: identifier,
      executor: self
    )

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        operation.start(continuation: continuation)
      }
    } onCancel: {
      operation.cancel()
    }
  }

  // MARK: - Socket Operations

  private func createICMPSocket(family: Int32) throws -> Int32 {
    #if canImport(Darwin)
      let sockfd: Int32
      switch family {
      case AF_INET:
        sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
      case AF_INET6:
        sockfd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
      default:
        throw TracerouteError.platformNotSupported(
          details: "Unsupported address family: \(family)")
      }
      guard sockfd >= 0 else {
        throw TracerouteError.socketCreateFailed(
          errno: errno, details: "Failed to create ICMP/ICMPv6 socket")
      }

      // Set outbound hop count (v4 TTL / v6 hop limit) to 64 — plenty for any internet hop.
      var hops: CInt = 64
      if family == AF_INET {
        if setsockopt(sockfd, IPPROTO_IP, IP_TTL, &hops, socklen_t(MemoryLayout<CInt>.size)) < 0 {
          // Non-fatal — default TTL is usually fine.
        }
      } else {
        if setsockopt(
          sockfd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &hops, socklen_t(MemoryLayout<CInt>.size)) < 0
        {
          // Non-fatal.
        }
        // Ask the kernel to deliver the reply's hop limit as ancillary data on recvmsg
        // so we can populate PingResponse.ttl. Without this, hop limit is unrecoverable
        // for v6 (the IPv6 header is stripped by the kernel — verified with icmpv6probe).
        var on: Int32 = 1
        if setsockopt(
          sockfd, IPPROTO_IPV6, IPV6_RECVHOPLIMIT_OPT, &on, socklen_t(MemoryLayout<Int32>.size)) < 0
        {
          // Non-fatal — ttl will just be nil in responses.
        }
      }
      return sockfd
    #else
      throw TracerouteError.platformNotSupported(details: "Ping requires ICMP datagram sockets")
    #endif
  }

  private func setNonBlocking(sockfd: Int32) throws {
    let flags = fcntl(sockfd, F_GETFL, 0)
    guard flags >= 0 else {
      throw TracerouteError.socketCreateFailed(errno: errno, details: "fcntl F_GETFL failed")
    }
    guard fcntl(sockfd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      throw TracerouteError.socketCreateFailed(errno: errno, details: "fcntl F_SETFL failed")
    }
  }

  private func applyBindings(sockfd: Int32, family: Int32, pingConfig: PingConfig) throws {
    let effectiveInterface = pingConfig.interface ?? swiftFTRConfig.interface
    let effectiveSourceIP = pingConfig.sourceIP ?? swiftFTRConfig.sourceIP

    if let iface = effectiveInterface {
      #if canImport(Darwin)
        let ifaceIndex = if_nametoindex(iface)
        guard ifaceIndex != 0 else {
          throw TracerouteError.interfaceBindFailed(
            interface: iface, errno: errno, details: "Interface not found")
        }
        var index = ifaceIndex
        // IP_BOUND_IF for v4, IPV6_BOUND_IF for v6 — same caller-visible semantics, NWX contract.
        let level = (family == AF_INET6) ? IPPROTO_IPV6 : IPPROTO_IP
        let optname = (family == AF_INET6) ? IPV6_BOUND_IF : IP_BOUND_IF
        if setsockopt(sockfd, level, optname, &index, socklen_t(MemoryLayout<UInt32>.size)) < 0 {
          throw TracerouteError.interfaceBindFailed(interface: iface, errno: errno, details: nil)
        }
      #endif
    }

    if let sourceIPStr = effectiveSourceIP {
      switch family {
      case AF_INET:
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        if inet_pton(AF_INET, sourceIPStr, &addr.sin_addr) != 1 {
          throw TracerouteError.sourceIPBindFailed(
            sourceIP: sourceIPStr, errno: errno, details: "Invalid IPv4")
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
          ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
        if bindResult < 0 {
          throw TracerouteError.sourceIPBindFailed(
            sourceIP: sourceIPStr, errno: errno, details: "bind() failed")
        }
      case AF_INET6:
        // Honor link-local scope suffix (fe80::xxxx%en0) via parseIPv6Scoped.
        let (bare, scopeID) = parseIPv6Scoped(sourceIPStr)
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_scope_id = scopeID
        if inet_pton(AF_INET6, bare, &addr.sin6_addr) != 1 {
          throw TracerouteError.sourceIPBindFailed(
            sourceIP: sourceIPStr, errno: errno, details: "Invalid IPv6")
        }
        let bindResult = withUnsafePointer(to: &addr) { ptr in
          ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
          }
        }
        if bindResult < 0 {
          throw TracerouteError.sourceIPBindFailed(
            sourceIP: sourceIPStr, errno: errno, details: "bind() failed")
        }
      default:
        throw TracerouteError.sourceIPBindFailed(
          sourceIP: sourceIPStr, errno: 0,
          details: "Unsupported address family for source bind: \(family)")
      }
    }
  }

  // Fileprivate to allow access from PingOperation. Sends to a pre-resolved
  // sockaddr_storage rather than re-parsing a string each call.
  fileprivate func sendPacket(
    sockfd: Int32, packet: [UInt8], to resolved: ResolvedHost
  ) throws {
    var addr = resolved.address
    let sent = withUnsafePointer(to: &addr) { destPtr in
      destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        packet.withUnsafeBytes { bufPtr in
          sendto(
            sockfd, bufPtr.baseAddress, packet.count, 0, sa, resolved.addressLen)
        }
      }
    }
    if sent != packet.count { throw TracerouteError.sendFailed(errno: errno) }
  }

  fileprivate func monotonicTime() -> TimeInterval {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let rawTime = TimeInterval(mach_absolute_time())
    return (rawTime * TimeInterval(info.numer) / TimeInterval(info.denom)) / 1_000_000_000.0
  }

  // MARK: - Identifier generation

  private func generateIdentifier() -> UInt16 {
    final class IdentifierState: @unchecked Sendable {
      private var counter: UInt16 = 0
      private let lock = NSLock()
      static let shared = IdentifierState()

      func next() -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        let value = counter
        counter = counter &+ 1  // wrapping increment
        return value
      }
    }

    let value = IdentifierState.shared.next()
    let pid = UInt16(truncatingIfNeeded: getpid())
    return value ^ pid
  }

  // MARK: - Utilities

}

/// Manages a single ping operation using DispatchSource for efficient I/O
private final class PingOperation: @unchecked Sendable {
  let sockfd: Int32
  let target: String
  let resolved: ResolvedHost
  let config: PingConfig
  let executor: PingExecutor
  let identifier: UInt16
  var family: Int32 { resolved.family }

  private var continuation: CheckedContinuation<PingResult, Error>?
  private var readSource: DispatchSourceRead?
  private var timerSource: DispatchSourceTimer?

  // Guarded by lock
  private var sentTimes: [Int: TimeInterval] = [:]
  private var receiveTimes: [Int: TimeInterval] = [:]
  private var ttls: [Int: Int] = [:]

  // Thread-local or protected by serial execution guarantees?
  // recvBuffer is only used in handleRead. handleRead is serial with respect to itself.
  // BUT we are on a concurrent queue now.
  // DispatchSource guarantees that the event handler is not re-entered concurrently.
  // So recvBuffer is safe.
  private var recvBuffer = [UInt8](repeating: 0, count: 1500)
  // Ancillary buffer for recvmsg cmsg data (v6 hop limit). 64 bytes is comfortably
  // larger than CMSG_SPACE(sizeof(int)) = 20 on Darwin; leaves headroom in case the
  // kernel emits other cmsgs we don't care about (we filter by level/type).
  private var cmsgBuffer = [UInt8](repeating: 0, count: 64)

  // Private serial queue for this operation to ensure race-free execution and reliable event delivery
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var isFinished = false
  private var isStarted = false

  init(
    sockfd: Int32,
    target: String,
    resolved: ResolvedHost,
    config: PingConfig,
    identifier: UInt16,
    executor: PingExecutor
  ) {
    self.sockfd = sockfd
    self.target = target
    self.resolved = resolved
    self.config = config
    self.identifier = identifier
    self.executor = executor
    self.queue = DispatchQueue(
      label: "com.swiftftr.ping.\(UInt64.random(in: 0...UInt64.max))", qos: .userInitiated)
  }

  func start(continuation: CheckedContinuation<PingResult, Error>) {
    lock.lock()
    if isFinished {
      lock.unlock()
      continuation.resume(throwing: TracerouteError.cancelled)
      return
    }
    self.continuation = continuation
    self.isStarted = true
    lock.unlock()

    queue.async {
      self.setupSources()
      self.startSending()
    }
  }

  func cancel() {
    finish()
  }

  private func setupSources() {
    let source = DispatchSource.makeReadSource(fileDescriptor: sockfd, queue: queue)
    // Strong self capture to keep operation alive until finish()
    source.setEventHandler { self.handleRead() }
    // Socket closure handled in finish()
    source.setCancelHandler {}
    source.activate()
    self.readSource = source

    // The deadline timer plays two roles. Until the send loop has issued all `count`
    // sendto calls it acts purely as a safety net (a generous upper bound that prevents
    // an indefinite hang if something goes wrong). Once all sends are attempted, the
    // send loop re-arms it to (last-send-time + config.timeout) so the final ping gets
    // a full `timeout` budget regardless of any accumulated Task.sleep drift.
    //
    // We must not anchor the deadline to the per-send wall clock *during* the send
    // loop: that would let the timer fire while later sleeps were still in progress
    // (e.g., count=3, interval=2.0, timeout=0.5 → seq=1 sent at t=0, timer at t=0.5,
    // but seq=2 isn't scheduled to send until t=2.0).
    let safetyBudget =
      2.0 * (Double(max(config.count - 1, 0)) * max(config.interval, 0) + config.timeout) + 5.0
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + .nanoseconds(Int(safetyBudget * 1_000_000_000)))
    timer.setEventHandler { self.finish() }
    timer.activate()
    self.timerSource = timer
  }

  private func startSending() {
    Task.detached {
      for seq in 1...self.config.count {
        if await self.checkFinished() { break }

        let packet: [UInt8]
        if self.family == AF_INET6 {
          packet = makeICMPv6EchoRequest(
            identifier: self.identifier,
            sequence: UInt16(seq),
            payloadSize: self.config.payloadSize
          )
        } else {
          packet = makeICMPEchoRequest(
            identifier: self.identifier,
            sequence: UInt16(seq),
            payloadSize: self.config.payloadSize
          )
        }

        // Dispatch send to serial queue. sendTime is captured on the queue, immediately
        // before sendto, so it reflects what actually went on the wire (not when this
        // Task.detached iteration enqueued the work).
        self.queue.async {
          if self.checkFinishedSync() { return }
          do {
            let sendTime = self.executor.monotonicTime()
            try self.executor.sendPacket(
              sockfd: self.sockfd, packet: packet, to: self.resolved)

            self.lock.lock()
            self.sentTimes[seq] = sendTime
            self.lock.unlock()
          } catch {
            // Send error (e.g., ENOBUFS): leave sentTimes[seq] unset so this packet is
            // excluded from the "sent" count rather than masquerading as transport loss.
          }
        }

        if seq < self.config.count && self.config.interval > 0 {
          try? await Task.sleep(nanoseconds: UInt64(self.config.interval * 1_000_000_000))
        }
      }

      // All sends have been attempted. On the serial queue (so we observe a consistent
      // snapshot of sentTimes), anchor the deadline timer to (last send time + timeout).
      // If no send ever succeeded, finish immediately — there is nothing more to wait
      // for, and the timeout-budget assumption ("at least one packet went out") is moot.
      self.queue.async {
        if self.checkFinishedSync() { return }
        self.lock.lock()
        let lastSendTime = self.sentTimes.values.max()
        self.lock.unlock()

        guard let lastSendTime = lastSendTime else {
          self.finish()
          return
        }

        let nowMono = self.executor.monotonicTime()
        let deadlineDelta = max(0, lastSendTime + self.config.timeout - nowMono)
        self.timerSource?.schedule(
          deadline: .now() + .nanoseconds(Int(deadlineDelta * 1_000_000_000)))
      }
    }
  }

  private func handleRead() {
    if checkFinishedSync() { return }

    while true {
      var fromAddr = sockaddr_storage()
      var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
      var hopLimit: Int? = nil
      let received: ssize_t

      if family == AF_INET6 {
        // v6: use recvmsg so we can recover the hop limit from cmsg ancillary data.
        // The kernel strips the IPv6 header for SOCK_DGRAM ICMPV6 (verified via
        // icmpv6probe spike), so hop limit is unrecoverable from the buffer itself.
        received = recvBuffer.withUnsafeMutableBytes { bufPtr -> ssize_t in
          cmsgBuffer.withUnsafeMutableBufferPointer { cb -> ssize_t in
            withUnsafeMutablePointer(to: &fromAddr) { faPtr -> ssize_t in
              var iov = iovec(
                iov_base: bufPtr.baseAddress, iov_len: bufPtr.count)
              return withUnsafeMutablePointer(to: &iov) { iovPtr -> ssize_t in
                var msg = msghdr()
                msg.msg_name = UnsafeMutableRawPointer(faPtr)
                msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
                msg.msg_iov = iovPtr
                msg.msg_iovlen = 1
                msg.msg_control = UnsafeMutableRawPointer(cb.baseAddress)
                msg.msg_controllen = socklen_t(cb.count)
                msg.msg_flags = 0
                let n = recvmsg(sockfd, &msg, 0)
                if n >= 0 {
                  fromLen = msg.msg_namelen
                  // If the kernel had to truncate the ancillary buffer (extra cmsgs
                  // we didn't account for), our hop-limit reading would be unreliable.
                  // Skip the cmsg walk and let ttl be nil so callers see that as a
                  // real condition rather than a silently lost field.
                  if (msg.msg_flags & MSG_CTRUNC) == 0 {
                    hopLimit = extractIPv6HopLimit(msg: msg)
                  }
                }
                return n
              }
            }
          }
        }
      } else {
        received = recvBuffer.withUnsafeMutableBytes { bufPtr in
          withUnsafeMutablePointer(to: &fromAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
              recvfrom(sockfd, bufPtr.baseAddress, 1500, 0, $0, &fromLen)
            }
          }
        }
      }

      if received < 0 { break }  // EAGAIN

      // Extra defensive check for negative count to prevent crash
      guard received >= 0 else { break }

      let parsedMessage: ParsedPingMessage? = recvBuffer.withUnsafeBytes { bufPtr in
        let slice = UnsafeRawBufferPointer(start: bufPtr.baseAddress, count: Int(received))
        if family == AF_INET6 {
          return swiftftrParseV6PingMessage(
            buffer: slice, hopLimit: hopLimit, expectedIdentifier: self.identifier)
        } else {
          return swiftftrParsePingMessage(
            buffer: slice, expectedIdentifier: self.identifier)
        }
      }

      if let parsed = parsedMessage {
        let receiveTime = executor.monotonicTime()

        lock.lock()
        switch parsed {
        case .echoReply(let sequence, let ttl):
          receiveTimes[Int(sequence)] = receiveTime
          if let ttl = ttl { ttls[Int(sequence)] = ttl }
        case .timeExceeded(let originalSequence, let ttl, _):
          // A Time Exceeded message implies the packet was lost at an intermediate hop.
          // We record a timeout for the original sequence for statistical purposes,
          // but we don't count it as a successful 'receive'.
          // The actual timeout will be handled by the overall operation timer.
          // Still, record the TTL if available for diagnostic purposes.
          // Only set if not already set by a prior Time Exceeded.
          if ttls[Int(originalSequence)] == nil {
            if let ttl = ttl { ttls[Int(originalSequence)] = ttl }
          }
        // Do not record a receive time for Time Exceeded, as it's not a successful reply.

        case .destinationUnreachable(let originalSequence, let ttl, _):
          // Similar to Time Exceeded, record TTL for diagnostic purposes.
          // Only set if not already set by a prior destination unreachable.
          if ttls[Int(originalSequence)] == nil {
            if let ttl = ttl { ttls[Int(originalSequence)] = ttl }
          }
        // Do not record a receive time for Destination Unreachable.
        }
        let count = receiveTimes.count
        lock.unlock()

        if count >= config.count {
          finish()
          return
        }
      }
    }
  }

  private func finish() {
    lock.lock()
    if isFinished {
      lock.unlock()
      return
    }
    isFinished = true
    let currentContinuation = self.continuation
    self.continuation = nil

    // Capture data under lock for result building
    let finalSentTimes = self.sentTimes
    let finalReceiveTimes = self.receiveTimes
    let finalTtls = self.ttls

    lock.unlock()

    timerSource?.cancel()
    readSource?.cancel()
    timerSource = nil
    readSource = nil

    // Close socket AFTER sources are cancelled and we're done with them.
    close(self.sockfd)

    guard let continuation = currentContinuation else { return }

    // Build result without lock (we have copies) on private serial queue
    queue.async {
      self.buildAndResume(
        continuation: continuation,
        sentTimes: finalSentTimes,
        receiveTimes: finalReceiveTimes,
        ttls: finalTtls
      )
    }
  }

  private func buildAndResume(
    continuation: CheckedContinuation<PingResult, Error>,
    sentTimes: [Int: TimeInterval],
    receiveTimes: [Int: TimeInterval],
    ttls: [Int: Int]
  ) {
    var responses: [PingResponse] = []
    for seq in 1...config.count {
      if let receiveTime = receiveTimes[seq], let sendTime = sentTimes[seq] {
        let rtt = receiveTime - sendTime
        responses.append(
          PingResponse(
            sequence: seq, rtt: rtt, ttl: ttls[seq], timestamp: Date(timeIntervalSinceNow: -rtt)))
      } else {
        responses.append(PingResponse(sequence: seq, rtt: nil, ttl: nil, timestamp: Date()))
      }
    }
    responses.sort { $0.sequence < $1.sequence }
    // Use actual sends rather than the configured count so that local send failures
    // (ENOBUFS etc.) don't masquerade as transport packet loss. When all sends succeed
    // this equals config.count; when every send fails this honestly reports sent=0
    // (PingStatistics.compute returns packetLoss=1.0 in that case).
    let stats = PingStatistics.compute(responses: responses, sent: sentTimes.count)
    let result = PingResult(
      target: target, resolvedIP: resolved.canonical, responses: responses, statistics: stats)
    continuation.resume(returning: result)
  }

  private func checkFinished() async -> Bool { checkFinishedSync() }
  private func checkFinishedSync() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return isFinished
  }

  private func parsePingMessage(buffer: UnsafeRawBufferPointer, expectedIdentifier: UInt16)
    -> ParsedPingMessage?
  {
    return swiftftrParsePingMessage(buffer: buffer, expectedIdentifier: expectedIdentifier)
  }

}

/// Walks the cmsg ancillary buffer attached to a `msghdr` to find an IPv6
/// hop-limit field. Darwin's `<sys/socket.h>` `CMSG_*` macros aren't bridged to
/// Swift, so we do the pointer arithmetic explicitly: cmsg data follows the
/// header at a 4-byte aligned offset; the next cmsg starts `cmsg_len` bytes
/// after the current one, also aligned. Returns nil if no hop-limit cmsg
/// is present (e.g. if `IPV6_RECVHOPLIMIT` setsockopt didn't take).
///
/// Free function so Stage 2 (v6 traceroute) can reuse it without depending on
/// `PingOperation`'s state.
internal func extractIPv6HopLimit(msg: msghdr) -> Int? {
  guard msg.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size),
    let base = msg.msg_control
  else { return nil }
  let alignedHeader = (MemoryLayout<cmsghdr>.size + 3) & ~3
  let end = base.advanced(by: Int(msg.msg_controllen))
  var cursor = base
  while cursor.advanced(by: MemoryLayout<cmsghdr>.size) <= end {
    let hdr = cursor.assumingMemoryBound(to: cmsghdr.self).pointee
    if hdr.cmsg_level == IPPROTO_IPV6
      && (hdr.cmsg_type == IPV6_HOPLIMIT_CMSG_2292
        || hdr.cmsg_type == IPV6_HOPLIMIT_CMSG_3542)
      && Int(hdr.cmsg_len) >= alignedHeader + MemoryLayout<Int32>.size
    {
      let dataPtr = cursor.advanced(by: alignedHeader).assumingMemoryBound(to: Int32.self)
      return Int(dataPtr.pointee)
    }
    let advance = (Int(hdr.cmsg_len) + 3) & ~3
    guard advance > 0 else { break }
    cursor = cursor.advanced(by: advance)
  }
  return nil
}

/// Free-function parser used by `PingOperation.parsePingMessage` and exposed via
/// `@_spi(Test)` for unit-testing the wire-format edge cases (notably TTL extraction).
internal func swiftftrParsePingMessage(
  buffer: UnsafeRawBufferPointer, expectedIdentifier: UInt16
) -> ParsedPingMessage? {
  guard buffer.count >= 8 else { return nil }
  let bytes = buffer.bindMemory(to: UInt8.self)
  var icmpOffset = 0
  let first = bytes[0]
  if (first >> 4) == 4 {
    let ihl = Int(first & 0x0F) * 4
    guard ihl >= 20, ihl <= buffer.count, bytes[9] == UInt8(IPPROTO_ICMP) else {
      return nil
    }
    icmpOffset = ihl
  }

  guard buffer.count - icmpOffset >= 8 else { return nil }
  let type = bytes[icmpOffset]
  let code = bytes[icmpOffset + 1]

  func read16(_ off: Int) -> UInt16 {
    let hi = UInt16(bytes[off])
    let lo = UInt16(bytes[off + 1])
    return (hi << 8) | lo
  }

  // TTL lives at byte 8 of the IPv4 header (RFC 791 §3.1). Only available when the
  // kernel handed us the IP header (icmpOffset > 0). On Darwin SOCK_DGRAM ICMP the
  // IP header is sometimes stripped, in which case TTL is unrecoverable from this
  // buffer — leave it nil.
  let ttl: Int? = (icmpOffset > 0 && buffer.count > 8) ? Int(bytes[8]) : nil

  switch type {
  case ICMPv4Type.echoReply.rawValue:
    guard code == 0 else { return nil }
    let id = read16(icmpOffset + 4)
    guard id == expectedIdentifier else { return nil }
    let seq = read16(icmpOffset + 6)
    return .echoReply(sequence: seq, ttl: ttl)

  case ICMPv4Type.timeExceeded.rawValue, ICMPv4Type.destinationUnreachable.rawValue:
    let embedStart = icmpOffset + 8
    guard buffer.count - embedStart >= 28 else { return nil }
    let embeddedIPHeaderStart = embedStart
    let embeddedFirstByte = bytes[embeddedIPHeaderStart]
    guard (embeddedFirstByte >> 4) == 4 else { return nil }
    let embeddedIHL = Int(embeddedFirstByte & 0x0F) * 4
    guard embeddedIHL >= 20 else { return nil }
    let embeddedICMPHeaderStart = embeddedIPHeaderStart + embeddedIHL
    guard buffer.count - embeddedICMPHeaderStart >= 8 else { return nil }
    guard bytes[embeddedIPHeaderStart + 9] == UInt8(IPPROTO_ICMP) else { return nil }
    guard bytes[embeddedICMPHeaderStart] == ICMPv4Type.echoRequest.rawValue else { return nil }
    guard bytes[embeddedICMPHeaderStart + 1] == 0 else { return nil }
    let embeddedID = read16(embeddedICMPHeaderStart + 4)
    guard embeddedID == expectedIdentifier else { return nil }
    let originalSeq = read16(embeddedICMPHeaderStart + 6)
    if type == ICMPv4Type.timeExceeded.rawValue {
      return .timeExceeded(originalSequence: originalSeq, ttl: ttl, code: code)
    } else {
      return .destinationUnreachable(originalSequence: originalSeq, ttl: ttl, code: code)
    }

  default:
    return nil
  }
}

/// IPv6 counterpart to `swiftftrParsePingMessage`. The hop limit arrives via cmsg
/// (caller-provided), and the embedded packet inside Time Exceeded / Destination
/// Unreachable is an IPv6 header (fixed 40 bytes) + ICMPv6 Echo Request.
internal func swiftftrParseV6PingMessage(
  buffer: UnsafeRawBufferPointer, hopLimit: Int?, expectedIdentifier: UInt16
) -> ParsedPingMessage? {
  guard buffer.count >= 8 else { return nil }
  let bytes = buffer.bindMemory(to: UInt8.self)
  let type = bytes[0]
  let code = bytes[1]

  @inline(__always) func read16(_ off: Int) -> UInt16 {
    (UInt16(bytes[off]) << 8) | UInt16(bytes[off + 1])
  }

  switch type {
  case ICMPv6Type.echoReply.rawValue:
    guard code == 0 else { return nil }
    let id = read16(4)
    guard id == expectedIdentifier else { return nil }
    let seq = read16(6)
    return .echoReply(sequence: seq, ttl: hopLimit)

  case ICMPv6Type.timeExceeded.rawValue, ICMPv6Type.destinationUnreachable.rawValue:
    // 8-byte ICMPv6 error header + embedded IPv6 (40) + ICMPv6 (8) = 56 min.
    let embedStart = 8
    guard buffer.count - embedStart >= 48 else { return nil }
    let ipFirst = bytes[embedStart]
    guard (ipFirst >> 4) == 6 else { return nil }
    guard bytes[embedStart + 6] == UInt8(IPPROTO_ICMPV6) else { return nil }
    let innerICMP = embedStart + 40
    guard buffer.count - innerICMP >= 8 else { return nil }
    guard bytes[innerICMP] == ICMPv6Type.echoRequest.rawValue else { return nil }
    guard bytes[innerICMP + 1] == 0 else { return nil }
    let embeddedID = read16(innerICMP + 4)
    guard embeddedID == expectedIdentifier else { return nil }
    let originalSeq = read16(innerICMP + 6)
    if type == ICMPv6Type.timeExceeded.rawValue {
      return .timeExceeded(originalSequence: originalSeq, ttl: hopLimit, code: code)
    } else {
      return .destinationUnreachable(originalSequence: originalSeq, ttl: hopLimit, code: code)
    }

  default:
    return nil
  }
}

/// SPI test surface mirroring `ParsedPingMessage` for unit tests.
@_spi(Test)
public enum TestParsedPingMessage: Sendable, Equatable {
  case echoReply(sequence: UInt16, ttl: Int?)
  case timeExceeded(originalSequence: UInt16, ttl: Int?, code: UInt8)
  case destinationUnreachable(originalSequence: UInt16, ttl: Int?, code: UInt8)
}

/// SPI parser entry point for unit tests. Use this to feed synthetic ICMP buffers
/// and assert correct parsing of fields like TTL.
// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __parsePingMessage(
  buffer: UnsafeRawBufferPointer, expectedIdentifier: UInt16
) -> TestParsedPingMessage? {
  guard let p = swiftftrParsePingMessage(buffer: buffer, expectedIdentifier: expectedIdentifier)
  else { return nil }
  switch p {
  case .echoReply(let seq, let ttl):
    return .echoReply(sequence: seq, ttl: ttl)
  case .timeExceeded(let seq, let ttl, let code):
    return .timeExceeded(originalSequence: seq, ttl: ttl, code: code)
  case .destinationUnreachable(let seq, let ttl, let code):
    return .destinationUnreachable(originalSequence: seq, ttl: ttl, code: code)
  }
}

/// SPI parser entry point for ICMPv6 unit tests. Mirrors `__parsePingMessage` but
/// takes the hop limit out-of-band (as the kernel delivers it via cmsg, not in the
/// buffer).
// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __parseV6PingMessage(
  buffer: UnsafeRawBufferPointer, hopLimit: Int?, expectedIdentifier: UInt16
) -> TestParsedPingMessage? {
  guard
    let p = swiftftrParseV6PingMessage(
      buffer: buffer, hopLimit: hopLimit, expectedIdentifier: expectedIdentifier)
  else { return nil }
  switch p {
  case .echoReply(let seq, let ttl):
    return .echoReply(sequence: seq, ttl: ttl)
  case .timeExceeded(let seq, let ttl, let code):
    return .timeExceeded(originalSequence: seq, ttl: ttl, code: code)
  case .destinationUnreachable(let seq, let ttl, let code):
    return .destinationUnreachable(originalSequence: seq, ttl: ttl, code: code)
  }
}

extension PingStatistics {
  static func compute(responses: [PingResponse], sent: Int) -> PingStatistics {
    let rtts = responses.compactMap { $0.rtt }
    let received = rtts.count
    let packetLoss = 1.0 - (Double(received) / Double(sent))
    guard !rtts.isEmpty else {
      return PingStatistics(
        sent: sent, received: 0, packetLoss: 1.0, minRTT: nil, avgRTT: nil, maxRTT: nil, jitter: nil
      )
    }
    let minRTT = rtts.min()!
    let maxRTT = rtts.max()!
    let avgRTT = rtts.reduce(0, +) / Double(rtts.count)
    let jitter: TimeInterval? = {
      guard rtts.count >= 2 else { return nil }
      let variance = rtts.map { pow($0 - avgRTT, 2) }.reduce(0, +) / Double(rtts.count)
      return sqrt(variance)
    }()
    return PingStatistics(
      sent: sent, received: received, packetLoss: packetLoss, minRTT: minRTT, avgRTT: avgRTT,
      maxRTT: maxRTT, jitter: jitter)
  }
}
