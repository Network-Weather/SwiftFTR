import Foundation

#if canImport(Darwin)
  import Darwin
#endif

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

  /// Source IP address to bind to for this operation.
  public let sourceIP: String?

  public init(
    count: Int = 5,
    interval: TimeInterval = 1.0,
    timeout: TimeInterval = 2.0,
    payloadSize: Int = 56,
    interface: String? = nil,
    sourceIP: String? = nil
  ) {
    self.count = count
    self.interval = interval
    self.timeout = timeout
    self.payloadSize = payloadSize
    self.interface = interface
    self.sourceIP = sourceIP
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
  /// Perform ping operation
  func ping(to target: String, config: PingConfig) async throws -> PingResult {
    // 1. Resolve target to IPv4
    let resolved = try resolveIPv4(host: target)

    // 2. Create ICMP datagram socket
    let sockfd = try createICMPSocket()

    // 3. Apply interface/sourceIP bindings (operation config overrides global)
    try applyBindings(sockfd: sockfd, pingConfig: config)

    // 4. Set non-blocking mode
    try setNonBlocking(sockfd: sockfd)

    // 4b. Increase receive buffer
    var recvBufSize: Int32 = 256 * 1024
    _ = setsockopt(sockfd, SOL_SOCKET, SO_RCVBUF, &recvBufSize, socklen_t(MemoryLayout<Int32>.size))

    // 4c. Unique identifier per ping session to avoid cross-socket collisions.
    let identifier = generateIdentifier()

    // 5. Delegate to PingOperation
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

  private func createICMPSocket() throws -> Int32 {
    #if canImport(Darwin)
      let sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
      guard sockfd >= 0 else {
        throw TracerouteError.socketCreateFailed(
          errno: errno, details: "Failed to create ICMP socket")
      }

      // Set TTL to a reasonable value (e.g., 64) to ensure packets reach destination
      var ttl: CInt = 64
      if setsockopt(sockfd, IPPROTO_IP, IP_TTL, &ttl, socklen_t(MemoryLayout<CInt>.size)) < 0 {
        // Log or handle error, but don't fail, as default TTL might still work
        print("[" + String(sockfd) + "] Warning: Failed to set IP_TTL on socket: " + String(errno))
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

  private func applyBindings(sockfd: Int32, pingConfig: PingConfig) throws {
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
        if setsockopt(sockfd, IPPROTO_IP, IP_BOUND_IF, &index, socklen_t(MemoryLayout<UInt32>.size))
          < 0
        {
          throw TracerouteError.interfaceBindFailed(interface: iface, errno: errno, details: nil)
        }
      #endif
    }

    if let sourceIPStr = effectiveSourceIP {
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
    }
  }

  // Fileprivate to allow access from PingOperation
  fileprivate func sendPacket(sockfd: Int32, packet: [UInt8], to ipAddr: String) throws {
    var destAddr = sockaddr_in()
    destAddr.sin_family = sa_family_t(AF_INET)
    if inet_pton(AF_INET, ipAddr, &destAddr.sin_addr) != 1 {
      throw TracerouteError.resolutionFailed(host: ipAddr, details: "Invalid IP")
    }

    let sent = withUnsafePointer(to: &destAddr) { destPtr in
      destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        packet.withUnsafeBytes { bufPtr in
          sendto(
            sockfd, bufPtr.baseAddress, packet.count, 0, sa,
            socklen_t(MemoryLayout<sockaddr_in>.size))
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

  private func resolveIPv4(host: String) throws -> String {
    var testAddr = in_addr()
    if inet_pton(AF_INET, host, &testAddr) == 1 { return host }

    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_DGRAM
    var result: UnsafeMutablePointer<addrinfo>?
    if getaddrinfo(host, nil, &hints, &result) == 0, let res = result {
      defer { freeaddrinfo(result) }
      if let addr = res.pointee.ai_addr {
        var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        if inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil {
          // Convert C string to Swift String safely
          return buf.withUnsafeBufferPointer { ptr in
            String(cString: ptr.baseAddress!)
          }
        }
      }
    }
    throw TracerouteError.resolutionFailed(host: host, details: "Resolution failed")
  }
}

/// Manages a single ping operation using DispatchSource for efficient I/O
private final class PingOperation: @unchecked Sendable {
  let sockfd: Int32
  let target: String
  let resolved: String
  let config: PingConfig
  let executor: PingExecutor
  let identifier: UInt16

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

  // Private serial queue for this operation to ensure race-free execution and reliable event delivery
  private let queue: DispatchQueue
  private let lock = NSLock()
  private var isFinished = false
  private var isStarted = false

  init(
    sockfd: Int32,
    target: String,
    resolved: String,
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
    // Use a serial queue for safety and reliability
    // Use a random label since we don't have identifier anymore
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

    let timer = DispatchSource.makeTimerSource(queue: queue)
    let totalTimeout = (Double(max(config.count - 1, 0)) * max(config.interval, 0)) + config.timeout
    timer.schedule(deadline: .now() + totalTimeout)
    // Strong self capture
    timer.setEventHandler { self.finish() }
    timer.activate()
    self.timerSource = timer
  }

  private func startSending() {
    Task.detached {
      for seq in 1...self.config.count {
        if await self.checkFinished() { break }

        let sendTime = self.executor.monotonicTime()
        let packet = makeICMPEchoRequest(
          identifier: self.identifier,
          sequence: UInt16(seq),
          payloadSize: self.config.payloadSize
        )

        // Dispatch send to serial queue
        self.queue.async {
          if self.checkFinishedSync() { return }
          do {
            try self.executor.sendPacket(
              sockfd: self.sockfd, packet: packet, to: self.resolved)

            self.lock.lock()
            self.sentTimes[seq] = sendTime
            self.lock.unlock()
          } catch {
            // Ignore send errors
          }
        }

        if seq < self.config.count && self.config.interval > 0 {
          try? await Task.sleep(nanoseconds: UInt64(self.config.interval * 1_000_000_000))
        }
      }
    }
  }

  private func handleRead() {
    if checkFinishedSync() { return }

    while true {
      var fromAddr = sockaddr_storage()
      var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let received = recvBuffer.withUnsafeMutableBytes { bufPtr in
        withUnsafeMutablePointer(to: &fromAddr) { addrPtr in
          addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            recvfrom(sockfd, bufPtr.baseAddress, 1500, 0, $0, &fromLen)
          }
        }
      }

      if received < 0 { break }  // EAGAIN

      // Extra defensive check for negative count to prevent crash
      guard received >= 0 else { break }

      let parsedMessage = recvBuffer.withUnsafeBytes { bufPtr in
        self.parsePingMessage(
          buffer: UnsafeRawBufferPointer(start: bufPtr.baseAddress, count: Int(received)),
          expectedIdentifier: self.identifier
        )
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
    let stats = PingStatistics.compute(responses: responses, sent: config.count)
    let result = PingResult(
      target: target, resolvedIP: resolved, responses: responses, statistics: stats)
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
    guard buffer.count >= 8 else { return nil }
    let bytes = buffer.bindMemory(to: UInt8.self)
    var icmpOffset = 0
    let first = bytes[0]
    if (first >> 4) == 4 {
      let ihl = Int(first & 0x0F) * 4
      if ihl >= 20 && ihl < buffer.count { icmpOffset = ihl }
    }

    guard buffer.count - icmpOffset >= 8 else { return nil }
    let type = bytes[icmpOffset]
    let code = bytes[icmpOffset + 1]

    func read16(_ off: Int) -> UInt16 {
      let hi = UInt16(bytes[off])
      let lo = UInt16(bytes[off + 1])
      return (hi << 8) | lo
    }

    let ttl: Int? =
      (icmpOffset > 0 && icmpOffset + 9 < buffer.count) ? Int(bytes[icmpOffset + 8]) : nil

    switch type {
    case ICMPv4Type.echoReply.rawValue:
      // Validate identifier to ensure the reply belongs to this socket.
      let id = read16(icmpOffset + 4)
      guard id == expectedIdentifier else { return nil }
      let seq = read16(icmpOffset + 6)
      return .echoReply(sequence: seq, ttl: ttl)

    case ICMPv4Type.timeExceeded.rawValue, ICMPv4Type.destinationUnreachable.rawValue:
      // For Time Exceeded and Dest Unreachable, the original IP header + ICMP header
      // of the packet that caused the error is embedded. We need to parse that.
      let embedStart = icmpOffset + 8  // After the ICMP error header
      guard buffer.count - embedStart >= 28 else { return nil }  // 20 (IP) + 8 (ICMP)

      let embeddedIPHeaderStart = embedStart
      let embeddedFirstByte = bytes[embeddedIPHeaderStart]
      guard (embeddedFirstByte >> 4) == 4 else { return nil }  // Must be IPv4
      let embeddedIHL = Int(embeddedFirstByte & 0x0F) * 4

      let embeddedICMPHeaderStart = embeddedIPHeaderStart + embeddedIHL
      guard buffer.count - embeddedICMPHeaderStart >= 8 else { return nil }

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
