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

  public init(
    count: Int = 5,
    interval: TimeInterval = 1.0,
    timeout: TimeInterval = 2.0,
    payloadSize: Int = 56
  ) {
    self.count = count
    self.interval = interval
    self.timeout = timeout
    self.payloadSize = payloadSize
  }
}

/// Result from a ping operation
public struct PingResult: Sendable, Codable {
  /// Target hostname or IP
  public let target: String

  /// Resolved IP address
  public let resolvedIP: String

  /// Individual ping responses (ordered by sequence)
  public let responses: [PingResponse]

  /// Computed statistics
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
  /// Sequence number (1-indexed)
  public let sequence: Int

  /// Round-trip time in seconds (nil if timeout)
  public let rtt: TimeInterval?

  /// TTL from response packet (nil if timeout)
  public let ttl: Int?

  /// Timestamp when ping was sent
  public let timestamp: Date

  /// Whether this ping timed out
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
  /// Total packets sent
  public let sent: Int

  /// Total packets received
  public let received: Int

  /// Packet loss ratio (0.0 - 1.0)
  public let packetLoss: Double

  /// Minimum RTT in seconds (nil if no responses)
  public let minRTT: TimeInterval?

  /// Average RTT in seconds (nil if no responses)
  public let avgRTT: TimeInterval?

  /// Maximum RTT in seconds (nil if no responses)
  public let maxRTT: TimeInterval?

  /// Standard deviation of RTT (jitter), nil if <2 responses
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

/// Parsed Echo Reply from ICMP response
struct ParsedEchoReply {
  let sequence: UInt16
  let ttl: Int?
}

/// Actor to collect send/receive times from concurrent tasks
actor ResponseCollector {
  private var sentTimes: [Int: TimeInterval] = [:]
  private var receiveTimes: [Int: TimeInterval] = [:]
  private var ttls: [Int: Int] = [:]

  func recordSend(seq: Int, sendTime: TimeInterval) {
    sentTimes[seq] = sendTime
  }

  func recordResponse(seq: Int, receiveTime: TimeInterval, ttl: Int?) {
    receiveTimes[seq] = receiveTime
    if let ttl = ttl {
      ttls[seq] = ttl
    }
  }

  func getResponseCount() -> Int {
    receiveTimes.count
  }

  func getResults() -> ([Int: TimeInterval], [Int: TimeInterval], [Int: Int]) {
    (sentTimes, receiveTimes, ttls)
  }
}

/// Internal ping implementation
actor PingExecutor {
  private let swiftFTRConfig: SwiftFTRConfig

  init(config: SwiftFTRConfig) {
    self.swiftFTRConfig = config
  }

  /// Perform ping operation
  func ping(to target: String, config: PingConfig) async throws -> PingResult {
    // 1. Resolve target to IPv4
    let resolved = try resolveIPv4(host: target)

    // 2. Create ICMP datagram socket
    let sockfd = try createICMPSocket()
    defer { close(sockfd) }

    // 3. Apply interface/sourceIP bindings from swiftFTRConfig
    try applyBindings(sockfd: sockfd)

    // 4. Set non-blocking mode
    try setNonBlocking(sockfd: sockfd)

    // 5. Generate stable identifier for this ping session
    let identifier = generateIdentifier()

    // 6. Use structured concurrency: receiver task runs continuously while sender sends on schedule
    let actor = ResponseCollector()

    let receiverTask = Task {
      var recvBuffer = [UInt8](repeating: 0, count: 1500)
      let startTime = monotonicTime()
      let deadline = startTime + Double(config.count) * config.interval + config.timeout + 1.0

      while monotonicTime() < deadline {
        guard !Task.isCancelled else { break }

        let timeLeft = deadline - monotonicTime()
        if timeLeft <= 0 { break }

        if let parsed = try? pollAndReceive(
          sockfd: sockfd,
          buffer: &recvBuffer,
          timeout: min(0.1, timeLeft),  // Short poll for responsiveness
          identifier: identifier
        ) {
          let receiveTime = monotonicTime()
          await actor.recordResponse(
            seq: Int(parsed.sequence), receiveTime: receiveTime, ttl: parsed.ttl)
        }

        // Check if we've received all responses
        let count = await actor.getResponseCount()
        if count >= config.count {
          break
        }
      }
    }

    // Send pings on schedule
    for seq in 1...config.count {
      let sendTime = monotonicTime()
      let packet = makeICMPEchoRequest(
        identifier: identifier,
        sequence: UInt16(seq),
        payloadSize: config.payloadSize
      )
      try sendPacket(sockfd: sockfd, packet: packet, to: resolved)
      await actor.recordSend(seq: seq, sendTime: sendTime)

      // Wait interval before next (except last)
      if seq < config.count {
        try await Task.sleep(nanoseconds: UInt64(config.interval * 1_000_000_000))
      }
    }

    // Wait a bit longer for remaining responses
    try await Task.sleep(nanoseconds: UInt64(config.timeout * 1_000_000_000))

    // Cancel receiver and collect results
    receiverTask.cancel()
    _ = await receiverTask.value

    let (sentTimes, receiveTimes, ttls) = await actor.getResults()

    // 7. Build response list
    var responses: [PingResponse] = []
    for seq in 1...config.count {
      if let receiveTime = receiveTimes[seq], let sendTime = sentTimes[seq] {
        let rtt = receiveTime - sendTime
        responses.append(
          PingResponse(
            sequence: seq,
            rtt: rtt,
            ttl: ttls[seq],
            timestamp: Date(timeIntervalSinceNow: -rtt)
          ))
      } else {
        responses.append(
          PingResponse(
            sequence: seq,
            rtt: nil,
            ttl: nil,
            timestamp: Date()
          ))
      }
    }

    // 8. Sort by sequence and compute statistics
    responses.sort { $0.sequence < $1.sequence }
    let stats = computeStatistics(responses: responses, sent: config.count)

    return PingResult(
      target: target,
      resolvedIP: resolved,
      responses: responses,
      statistics: stats
    )
  }

  /// Compute statistics from ping responses
  private func computeStatistics(responses: [PingResponse], sent: Int) -> PingStatistics {
    let rtts = responses.compactMap { $0.rtt }
    let received = rtts.count
    let packetLoss = 1.0 - (Double(received) / Double(sent))

    guard !rtts.isEmpty else {
      return PingStatistics(
        sent: sent,
        received: 0,
        packetLoss: 1.0,
        minRTT: nil,
        avgRTT: nil,
        maxRTT: nil,
        jitter: nil
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
      sent: sent,
      received: received,
      packetLoss: packetLoss,
      minRTT: minRTT,
      avgRTT: avgRTT,
      maxRTT: maxRTT,
      jitter: jitter
    )
  }

  // MARK: - Socket Operations

  private func createICMPSocket() throws -> Int32 {
    #if canImport(Darwin)
      let sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
      guard sockfd >= 0 else {
        let err = errno
        throw TracerouteError.socketCreateFailed(
          errno: err,
          details: "Failed to create ICMP datagram socket. Ensure macOS 13+ and proper permissions."
        )
      }
      return sockfd
    #else
      throw TracerouteError.platformNotSupported(
        details: "Ping requires ICMP datagram sockets (macOS 13+)")
    #endif
  }

  private func setNonBlocking(sockfd: Int32) throws {
    let flags = fcntl(sockfd, F_GETFL, 0)
    guard flags >= 0 else {
      throw TracerouteError.socketCreateFailed(
        errno: errno, details: "fcntl F_GETFL failed")
    }
    guard fcntl(sockfd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
      throw TracerouteError.socketCreateFailed(
        errno: errno, details: "fcntl F_SETFL O_NONBLOCK failed")
    }
  }

  private func applyBindings(sockfd: Int32) throws {
    // Apply interface binding if specified
    if let iface = swiftFTRConfig.interface {
      #if canImport(Darwin)
        let ifaceIndex = if_nametoindex(iface)
        guard ifaceIndex != 0 else {
          throw TracerouteError.interfaceBindFailed(
            interface: iface,
            errno: errno,
            details: "Interface '\(iface)' not found. Use 'ifconfig' to list available interfaces."
          )
        }

        var index = ifaceIndex
        let result = setsockopt(
          sockfd, IPPROTO_IP, IP_BOUND_IF,
          &index, socklen_t(MemoryLayout<UInt32>.size))

        guard result >= 0 else {
          throw TracerouteError.interfaceBindFailed(
            interface: iface,
            errno: errno,
            details: nil
          )
        }
      #endif
    }

    // Apply source IP binding if specified
    if let sourceIPStr = swiftFTRConfig.sourceIP {
      var addr = sockaddr_in()
      addr.sin_family = sa_family_t(AF_INET)
      addr.sin_port = 0

      guard inet_pton(AF_INET, sourceIPStr, &addr.sin_addr) == 1 else {
        throw TracerouteError.sourceIPBindFailed(
          sourceIP: sourceIPStr,
          errno: errno,
          details: "Invalid IPv4 address format"
        )
      }

      let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          Darwin.bind(sockfd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }

      guard bindResult >= 0 else {
        throw TracerouteError.sourceIPBindFailed(
          sourceIP: sourceIPStr,
          errno: errno,
          details:
            "Ensure the IP is assigned to the interface and not already in use"
        )
      }
    }
  }

  private func sendPacket(sockfd: Int32, packet: [UInt8], to ipAddr: String) throws {
    var destAddr = sockaddr_in()
    destAddr.sin_family = sa_family_t(AF_INET)
    destAddr.sin_port = 0

    guard inet_pton(AF_INET, ipAddr, &destAddr.sin_addr) == 1 else {
      throw TracerouteError.resolutionFailed(host: ipAddr, details: "Invalid IP address")
    }

    let sent = withUnsafePointer(to: &destAddr) { destPtr in
      destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        packet.withUnsafeBytes { bufPtr in
          sendto(
            sockfd,
            bufPtr.baseAddress,
            packet.count,
            0,
            sa,
            socklen_t(MemoryLayout<sockaddr_in>.size)
          )
        }
      }
    }

    guard sent == packet.count else {
      throw TracerouteError.sendFailed(errno: errno)
    }
  }

  private func pollAndReceive(
    sockfd: Int32,
    buffer: inout [UInt8],
    timeout: TimeInterval,
    identifier: UInt16
  ) throws -> ParsedEchoReply? {
    var pollfd = pollfd()
    pollfd.fd = sockfd
    pollfd.events = Int16(POLLIN)

    let timeoutMs = Int32(max(0, timeout * 1000))
    let pollResult = poll(&pollfd, 1, timeoutMs)

    guard pollResult > 0 else {
      return nil  // Timeout or error
    }

    var fromAddr = sockaddr_storage()
    var fromLen = socklen_t(MemoryLayout<sockaddr_storage>.size)

    let bufferSize = buffer.count
    let received = buffer.withUnsafeMutableBytes { bufPtr in
      withUnsafeMutablePointer(to: &fromAddr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          recvfrom(sockfd, bufPtr.baseAddress, bufferSize, 0, sa, &fromLen)
        }
      }
    }

    guard received > 0 else {
      return nil
    }

    // Parse Echo Reply
    return parseEchoReply(
      buffer: UnsafeRawBufferPointer(
        start: buffer.withUnsafeBytes { $0.baseAddress },
        count: Int(received)
      ),
      expectedIdentifier: identifier
    )
  }

  private func parseEchoReply(buffer: UnsafeRawBufferPointer, expectedIdentifier: UInt16)
    -> ParsedEchoReply?
  {
    guard buffer.count >= 8 else { return nil }

    let bytes = buffer.bindMemory(to: UInt8.self)
    var icmpOffset = 0

    // Detect and skip IPv4 header if present
    let first = bytes[0]
    if (first >> 4) == 4 {
      let ihl = Int(first & 0x0F) * 4
      if ihl >= 20 && ihl < buffer.count {
        icmpOffset = ihl
      }
    }

    guard buffer.count - icmpOffset >= 8 else { return nil }

    let type = bytes[icmpOffset]
    guard type == ICMPv4Type.echoReply.rawValue else { return nil }

    func read16(_ off: Int) -> UInt16 {
      let hi = UInt16(bytes[off])
      let lo = UInt16(bytes[off + 1])
      return (hi << 8) | lo
    }

    let id = read16(icmpOffset + 4)
    guard id == expectedIdentifier else { return nil }

    let seq = read16(icmpOffset + 6)

    // Extract TTL from IP header if present
    let ttl: Int? = {
      if icmpOffset > 0 && icmpOffset >= 9 {
        return Int(bytes[8])  // TTL is at byte 8 in IPv4 header
      }
      return nil
    }()

    return ParsedEchoReply(sequence: seq, ttl: ttl)
  }

  // MARK: - Utilities

  private func generateIdentifier() -> UInt16 {
    // Generate stable but unique identifier per ping session
    // Use timestamp + random to avoid collisions
    let timestamp = UInt16(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1000))
    let random = UInt16.random(in: 0...0xFFF)
    return timestamp ^ random
  }

  private func resolveIPv4(host: String) throws -> String {
    // Check if already an IP address
    var testAddr = in_addr()
    if inet_pton(AF_INET, host, &testAddr) == 1 {
      return host
    }

    // Perform DNS resolution
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_DGRAM

    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, nil, &hints, &result)

    guard status == 0, let addrInfo = result else {
      throw TracerouteError.resolutionFailed(
        host: host,
        details: String(cString: gai_strerror(status))
      )
    }

    defer { freeaddrinfo(result) }

    guard let sockaddr = addrInfo.pointee.ai_addr else {
      throw TracerouteError.resolutionFailed(host: host, details: "No address returned")
    }

    let sinPtr = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0 }
    var sin = sinPtr.pointee
    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))

    guard inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else {
      throw TracerouteError.resolutionFailed(host: host, details: "inet_ntop failed")
    }

    // Find null terminator and convert CChar to UInt8
    let count = buf.firstIndex(of: 0) ?? buf.count
    let bytes = buf.prefix(count).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }

  private func monotonicTime() -> TimeInterval {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let numer = TimeInterval(info.numer)
    let denom = TimeInterval(info.denom)
    let rawTime = TimeInterval(mach_absolute_time())
    return (rawTime * numer / denom) / 1_000_000_000.0
  }
}
