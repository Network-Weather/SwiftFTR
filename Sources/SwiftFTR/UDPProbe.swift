import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Configuration for UDP probing
public struct UDPProbeConfig: Sendable {
  /// Target host (hostname or IP)
  public let host: String

  /// Target port
  public let port: Int

  /// Timeout for probe in seconds (default: 2.0)
  public let timeout: TimeInterval

  /// Payload to send (default: empty)
  public let payload: Data

  public init(
    host: String,
    port: Int,
    timeout: TimeInterval = 2.0,
    payload: Data = Data()
  ) {
    self.host = host
    self.port = port
    self.timeout = timeout
    self.payload = payload
  }
}

/// Result from a UDP probe
public struct UDPProbeResult: Sendable, Codable {
  /// Target host
  public let host: String

  /// Resolved IP address
  public let resolvedIP: String

  /// Target port
  public let port: Int

  /// Whether the probe succeeded (host responded or ICMP Port Unreachable)
  public let isReachable: Bool

  /// Round-trip time (nil if timed out)
  public let rtt: TimeInterval?

  /// Response type
  public let responseType: String?  // "udp_reply", "icmp_port_unreachable", "timeout"

  /// Error message (if any)
  public let error: String?

  /// Timestamp when probe was performed
  public let timestamp: Date

  public init(
    host: String,
    resolvedIP: String,
    port: Int,
    isReachable: Bool,
    rtt: TimeInterval?,
    responseType: String?,
    error: String?,
    timestamp: Date = Date()
  ) {
    self.host = host
    self.resolvedIP = resolvedIP
    self.port = port
    self.isReachable = isReachable
    self.rtt = rtt
    self.responseType = responseType
    self.error = error
    self.timestamp = timestamp
  }
}

/// UDP probe implementation using connected UDP socket (no root required)
/// Sends UDP packet and waits for response or ICMP Port Unreachable
/// Returns success if ANY response received (UDP reply or ICMP Port Unreachable)
/// Returns failure only on timeout (no response)
///
/// Implementation: Uses connect() on UDP socket so kernel delivers ICMP errors
/// as ECONNREFUSED on recv(), avoiding need for raw ICMP socket
public func udpProbe(
  host: String,
  port: Int,
  timeout: TimeInterval = 2.0,
  payload: Data = Data()
) async throws -> UDPProbeResult {
  let config = UDPProbeConfig(host: host, port: port, timeout: timeout, payload: payload)
  return try await udpProbe(config: config)
}

public func udpProbe(config: UDPProbeConfig) async throws -> UDPProbeResult {
  let startTime = Date()

  // Resolve hostname to IP address
  guard let resolvedIP = try? await resolveHostnameUDP(config.host) else {
    return UDPProbeResult(
      host: config.host,
      resolvedIP: config.host,
      port: config.port,
      isReachable: false,
      rtt: nil,
      responseType: nil,
      error: "Failed to resolve hostname",
      timestamp: startTime
    )
  }

  // Perform UDP probe
  let result = try await performUDPProbe(
    ip: resolvedIP,
    port: config.port,
    payload: config.payload,
    timeout: config.timeout,
    startTime: startTime
  )

  return UDPProbeResult(
    host: config.host,
    resolvedIP: resolvedIP,
    port: config.port,
    isReachable: result.isReachable,
    rtt: result.rtt,
    responseType: result.responseType,
    error: result.error,
    timestamp: startTime
  )
}

// MARK: - Private Implementation

private func resolveHostnameUDP(_ host: String) async throws -> String {
  // If already an IP address, return it
  if isIPAddressUDP(host) {
    return host
  }

  // Use getaddrinfo for DNS resolution
  var hints = addrinfo()
  hints.ai_family = AF_INET  // IPv4
  hints.ai_socktype = SOCK_DGRAM

  var result: UnsafeMutablePointer<addrinfo>?
  defer { if let result = result { freeaddrinfo(result) } }

  let status = getaddrinfo(host, nil, &hints, &result)
  guard status == 0, let addr = result else {
    throw UDPProbeError.resolutionFailed
  }

  // Extract IP address
  var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
  getnameinfo(
    addr.pointee.ai_addr,
    socklen_t(addr.pointee.ai_addrlen),
    &hostname,
    socklen_t(hostname.count),
    nil,
    0,
    NI_NUMERICHOST
  )

  // Convert to String, truncating at null terminator
  let nullIndex = hostname.firstIndex(of: 0) ?? hostname.count
  let bytes = hostname[..<nullIndex].map { UInt8(bitPattern: $0) }
  return String(decoding: bytes, as: UTF8.self)
}

private func isIPAddressUDP(_ string: String) -> Bool {
  let components = string.split(separator: ".")
  guard components.count == 4 else { return false }
  return components.allSatisfy { UInt8($0) != nil }
}

private struct UDPProbeResultInternal {
  let isReachable: Bool
  let rtt: TimeInterval?
  let responseType: String?
  let error: String?
}

private func performUDPProbe(
  ip: String,
  port: Int,
  payload: Data,
  timeout: TimeInterval,
  startTime: Date
) async throws -> UDPProbeResultInternal {
  // Create UDP socket
  let sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
  guard sockfd >= 0 else {
    return UDPProbeResultInternal(
      isReachable: false,
      rtt: nil,
      responseType: nil,
      error: "Failed to create UDP socket"
    )
  }
  defer { close(sockfd) }

  // Set socket to non-blocking
  var flags = fcntl(sockfd, F_GETFL, 0)
  flags |= O_NONBLOCK
  _ = fcntl(sockfd, F_SETFL, flags)

  // Prepare destination address
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = in_port_t(port).bigEndian
  inet_pton(AF_INET, ip, &addr.sin_addr)

  // Connect the UDP socket - this allows kernel to deliver ICMP errors
  let connectResult = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }

  guard connectResult == 0 else {
    return UDPProbeResultInternal(
      isReachable: false,
      rtt: nil,
      responseType: nil,
      error: "Failed to connect: \(String(cString: strerror(errno)))"
    )
  }

  // Send UDP packet using send() (not sendto() - socket is connected)
  let payloadBytes = payload.count > 0 ? Array(payload) : [0x00]
  let sendResult = payloadBytes.withUnsafeBufferPointer { buffer in
    send(sockfd, buffer.baseAddress, buffer.count, 0)
  }

  guard sendResult >= 0 else {
    return UDPProbeResultInternal(
      isReachable: false,
      rtt: nil,
      responseType: nil,
      error: "Failed to send: \(String(cString: strerror(errno)))"
    )
  }

  // Wait for response using select() with timeout
  let endTime = startTime.addingTimeInterval(timeout)

  while Date() < endTime {
    let remaining = endTime.timeIntervalSinceNow
    guard remaining > 0 else { break }

    var readSet = fd_set()
    udpFdZero(&readSet)
    udpFdSet(sockfd, &readSet)

    var timeoutVal = timeval(
      tv_sec: Int(remaining),
      tv_usec: Int32((remaining.truncatingRemainder(dividingBy: 1.0)) * 1_000_000)
    )

    let selectResult = select(sockfd + 1, &readSet, nil, nil, &timeoutVal)

    if selectResult <= 0 {
      // Timeout or error
      break
    }

    // Socket is readable - try to receive
    var buffer = [UInt8](repeating: 0, count: 1024)
    let bytesRead = recv(sockfd, &buffer, buffer.count, 0)

    if bytesRead > 0 {
      // Got UDP reply
      let rtt = Date().timeIntervalSince(startTime)
      return UDPProbeResultInternal(
        isReachable: true,
        rtt: rtt,
        responseType: "udp_reply",
        error: nil
      )
    } else if bytesRead < 0 {
      // Check for ICMP errors delivered via connected socket
      let err = errno

      // ECONNREFUSED = ICMP Port Unreachable (host is up!)
      if err == ECONNREFUSED {
        let rtt = Date().timeIntervalSince(startTime)
        return UDPProbeResultInternal(
          isReachable: true,
          rtt: rtt,
          responseType: "icmp_port_unreachable",
          error: nil
        )
      }

      // EAGAIN/EWOULDBLOCK = no data available (try again)
      if err == EAGAIN || err == EWOULDBLOCK {
        continue  // Keep polling
      }

      // Network unreachable errors = host down
      if err == EHOSTUNREACH || err == ENETUNREACH || err == EHOSTDOWN {
        return UDPProbeResultInternal(
          isReachable: false,
          rtt: nil,
          responseType: nil,
          error: "Network unreachable: \(String(cString: strerror(err)))"
        )
      }

      // Other errors (ENOTCONN, EBADF, etc.)
      return UDPProbeResultInternal(
        isReachable: false,
        rtt: nil,
        responseType: nil,
        error: "Receive error: \(String(cString: strerror(err)))"
      )
    }
  }

  // Timeout - no response
  return UDPProbeResultInternal(
    isReachable: false,
    rtt: nil,
    responseType: "timeout",
    error: "No response within timeout"
  )
}

// MARK: - fd_set Helpers for UDP

#if canImport(Darwin)
  private func udpFdZero(_ set: inout fd_set) {
    _ = withUnsafeMutableBytes(of: &set) { ptr in
      ptr.baseAddress?.initializeMemory(
        as: UInt8.self, repeating: 0, count: MemoryLayout<fd_set>.size)
    }
  }

  private func udpFdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    let mask: Int32 = 1 << bitOffset

    withUnsafeMutableBytes(of: &set.fds_bits) { ptr in
      let base = ptr.baseAddress!.assumingMemoryBound(to: Int32.self)
      base[intOffset] |= mask
    }
  }

  private func udpFdIsSet(_ fd: Int32, _ set: inout fd_set) -> Bool {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    let mask: Int32 = 1 << bitOffset

    return withUnsafeMutableBytes(of: &set.fds_bits) { ptr in
      let base = ptr.baseAddress!.assumingMemoryBound(to: Int32.self)
      return (base[intOffset] & mask) != 0
    }
  }
#else
  private func udpFdZero(_ set: inout fd_set) {
    _ = withUnsafeMutableBytes(of: &set) { ptr in
      ptr.baseAddress?.initializeMemory(
        as: UInt8.self, repeating: 0, count: MemoryLayout<fd_set>.size)
    }
  }

  private func udpFdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / (MemoryLayout<Int>.size * 8)
    let bitOffset = Int(fd) % (MemoryLayout<Int>.size * 8)
    let mask: Int = 1 << bitOffset

    withUnsafeMutableBytes(of: &set.__fds_bits) { ptr in
      let base = ptr.baseAddress!.assumingMemoryBound(to: Int.self)
      base[intOffset] |= mask
    }
  }

  private func udpFdIsSet(_ fd: Int32, _ set: inout fd_set) -> Bool {
    let intOffset = Int(fd) / (MemoryLayout<Int>.size * 8)
    let bitOffset = Int(fd) % (MemoryLayout<Int>.size * 8)
    let mask: Int = 1 << bitOffset

    return withUnsafeMutableBytes(of: &set.__fds_bits) { ptr in
      let base = ptr.baseAddress!.assumingMemoryBound(to: Int.self)
      return (base[intOffset] & mask) != 0
    }
  }
#endif

// MARK: - Errors

public enum UDPProbeError: Error {
  case resolutionFailed
  case socketCreationFailed
  case sendFailed
  case timeout
}
