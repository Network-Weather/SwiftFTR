import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Configuration for TCP probing
public struct TCPProbeConfig: Sendable {
  /// Target host (hostname or IP)
  public let host: String

  /// Target port
  public let port: Int

  /// Timeout for connection attempt in seconds (default: 2.0)
  public let timeout: TimeInterval

  /// Network interface to bind to for this TCP probe.
  ///
  /// When specified, this probe uses only this interface. If `nil`, uses system routing.
  ///
  /// Example:
  /// ```swift
  /// // Test TCP connectivity via specific interface
  /// let result = try await tcpProbe(
  ///   config: TCPProbeConfig(
  ///     host: "example.com",
  ///     port: 443,
  ///     interface: "en14"
  ///   )
  /// )
  /// ```
  public let interface: String?

  /// Source IP address to bind to for this TCP probe.
  ///
  /// When specified, outgoing packets use this IP as the source address.
  /// The IP must be assigned to the selected interface.
  ///
  /// **Note**: Most users only need to set ``interface``.
  public let sourceIP: String?

  public init(
    host: String,
    port: Int,
    timeout: TimeInterval = 2.0,
    interface: String? = nil,
    sourceIP: String? = nil
  ) {
    self.host = host
    self.port = port
    self.timeout = timeout
    self.interface = interface
    self.sourceIP = sourceIP
  }
}

/// Result from a TCP probe
public struct TCPProbeResult: Sendable, Codable {
  /// Target host
  public let host: String

  /// Resolved IP address
  public let resolvedIP: String

  /// Target port
  public let port: Int

  /// Whether the probe succeeded (connection established or RST received)
  public let isReachable: Bool

  /// Round-trip time to establish connection (nil if timed out)
  public let rtt: TimeInterval?

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
    error: String?,
    timestamp: Date = Date()
  ) {
    self.host = host
    self.resolvedIP = resolvedIP
    self.port = port
    self.isReachable = isReachable
    self.rtt = rtt
    self.error = error
    self.timestamp = timestamp
  }
}

/// TCP SYN probe implementation
/// Attempts to establish a TCP connection to test host/port reachability
/// Returns success if connection succeeds OR port is explicitly closed (RST)
/// Returns failure only on timeout or network unreachable
#if compiler(>=6.2)
  @concurrent
#endif
public func tcpProbe(
  host: String,
  port: Int,
  timeout: TimeInterval = 2.0
) async throws -> TCPProbeResult {
  let config = TCPProbeConfig(host: host, port: port, timeout: timeout)
  return try await tcpProbe(config: config)
}

#if compiler(>=6.2)
  @concurrent
#endif
public func tcpProbe(config: TCPProbeConfig) async throws -> TCPProbeResult {
  let startTime = Date()

  // Resolve hostname to IP address
  guard let resolvedIP = try? await resolveHostname(config.host) else {
    return TCPProbeResult(
      host: config.host,
      resolvedIP: config.host,  // Assume it's already an IP
      port: config.port,
      isReachable: false,
      rtt: nil,
      error: "Failed to resolve hostname",
      timestamp: startTime
    )
  }

  // Perform TCP SYN probe using non-blocking socket
  let result = try await performTCPProbe(
    ip: resolvedIP,
    port: config.port,
    timeout: config.timeout,
    startTime: startTime,
    interface: config.interface,
    sourceIP: config.sourceIP
  )

  return TCPProbeResult(
    host: config.host,
    resolvedIP: resolvedIP,
    port: config.port,
    isReachable: result.isReachable,
    rtt: result.rtt,
    error: result.error,
    timestamp: startTime
  )
}

// MARK: - Private Implementation

private func resolveHostname(_ host: String) async throws -> String {
  // If already an IP address, return it
  if isIPAddress(host) {
    return host
  }

  // Use getaddrinfo for DNS resolution
  var hints = addrinfo()
  hints.ai_family = AF_INET  // IPv4 for now
  hints.ai_socktype = SOCK_STREAM

  var result: UnsafeMutablePointer<addrinfo>?
  defer { if let result = result { freeaddrinfo(result) } }

  let status = getaddrinfo(host, nil, &hints, &result)
  guard status == 0, let addr = result else {
    throw TCPProbeError.resolutionFailed
  }

  // Extract IP address from result
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

private func isIPAddress(_ string: String) -> Bool {
  // Simple check for IPv4 format
  let components = string.split(separator: ".")
  guard components.count == 4 else { return false }
  return components.allSatisfy { UInt8($0) != nil }
}

private struct ProbeResult {
  let isReachable: Bool
  let rtt: TimeInterval?
  let error: String?
}

private func performTCPProbe(
  ip: String,
  port: Int,
  timeout: TimeInterval,
  startTime: Date,
  interface: String?,
  sourceIP: String?
) async throws -> ProbeResult {
  // Create socket
  let sockfd = socket(AF_INET, SOCK_STREAM, 0)
  guard sockfd >= 0 else {
    return ProbeResult(
      isReachable: false,
      rtt: nil,
      error: "Failed to create socket: \(String(cString: strerror(errno)))"
    )
  }
  defer { close(sockfd) }

  // Bind to interface if specified
  if let iface = interface {
    #if canImport(Darwin)
      let ifaceIndex = if_nametoindex(iface)
      guard ifaceIndex != 0 else {
        return ProbeResult(
          isReachable: false,
          rtt: nil,
          error: "Interface '\(iface)' not found"
        )
      }

      var index = ifaceIndex
      let result = setsockopt(
        sockfd, IPPROTO_IP, IP_BOUND_IF,
        &index, socklen_t(MemoryLayout<UInt32>.size))

      guard result >= 0 else {
        return ProbeResult(
          isReachable: false,
          rtt: nil,
          error: "Failed to bind to interface '\(iface)': \(String(cString: strerror(errno)))"
        )
      }
    #else
      return ProbeResult(
        isReachable: false,
        rtt: nil,
        error: "Interface binding not supported on this platform"
      )
    #endif
  }

  // Bind to source IP if specified
  if let srcIP = sourceIP {
    var sourceAddr = sockaddr_in()
    sourceAddr.sin_family = sa_family_t(AF_INET)
    sourceAddr.sin_port = 0  // Let system choose port

    guard inet_pton(AF_INET, srcIP, &sourceAddr.sin_addr) == 1 else {
      return ProbeResult(
        isReachable: false,
        rtt: nil,
        error: "Invalid source IP address '\(srcIP)'"
      )
    }

    let bindResult = withUnsafePointer(to: &sourceAddr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        Darwin.bind(sockfd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }

    guard bindResult >= 0 else {
      return ProbeResult(
        isReachable: false,
        rtt: nil,
        error: "Failed to bind to source IP '\(srcIP)': \(String(cString: strerror(errno)))"
      )
    }
  }

  // Set socket to non-blocking
  var flags = fcntl(sockfd, F_GETFL, 0)
  flags |= O_NONBLOCK
  _ = fcntl(sockfd, F_SETFL, flags)

  // Prepare sockaddr
  var addr = sockaddr_in()
  addr.sin_family = sa_family_t(AF_INET)
  addr.sin_port = in_port_t(port).bigEndian
  inet_pton(AF_INET, ip, &addr.sin_addr)

  // Attempt connection
  let connectResult = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }

  // If connection succeeded immediately (unlikely but possible)
  if connectResult == 0 {
    let rtt = Date().timeIntervalSince(startTime)
    return ProbeResult(isReachable: true, rtt: rtt, error: nil)
  }

  // Check if connection is in progress
  guard errno == EINPROGRESS else {
    let errorMsg = String(cString: strerror(errno))
    // ECONNREFUSED means port is closed but host is up - still success!
    if errno == ECONNREFUSED {
      let rtt = Date().timeIntervalSince(startTime)
      return ProbeResult(isReachable: true, rtt: rtt, error: nil)
    }
    return ProbeResult(isReachable: false, rtt: nil, error: errorMsg)
  }

  // Wait for connection to complete or timeout using select()
  var writeSet = fd_set()
  fdZero(&writeSet)
  fdSet(sockfd, &writeSet)

  var timeoutVal = timeval(
    tv_sec: Int(timeout),
    tv_usec: Int32((timeout.truncatingRemainder(dividingBy: 1.0)) * 1_000_000)
  )

  let selectResult = select(sockfd + 1, nil, &writeSet, nil, &timeoutVal)

  if selectResult <= 0 {
    // Timeout or error
    return ProbeResult(isReachable: false, rtt: nil, error: "Connection timeout")
  }

  // Check if connection succeeded or failed
  var error: Int32 = 0
  var errorLen = socklen_t(MemoryLayout<Int32>.size)
  getsockopt(sockfd, SOL_SOCKET, SO_ERROR, &error, &errorLen)

  let rtt = Date().timeIntervalSince(startTime)

  if error == 0 {
    // Connection succeeded
    return ProbeResult(isReachable: true, rtt: rtt, error: nil)
  } else if error == ECONNREFUSED {
    // Port closed but host reachable (RST received) - this is success!
    return ProbeResult(isReachable: true, rtt: rtt, error: nil)
  } else {
    // Other error (network unreachable, etc.)
    let errorMsg = String(cString: strerror(error))
    return ProbeResult(isReachable: false, rtt: nil, error: errorMsg)
  }
}

// MARK: - fd_set Helpers

#if canImport(Darwin)
  private func fdZero(_ set: inout fd_set) {
    // Zero out the entire fd_set structure
    _ = withUnsafeMutableBytes(of: &set) { ptr in
      ptr.baseAddress?.initializeMemory(
        as: UInt8.self, repeating: 0, count: MemoryLayout<fd_set>.size)
    }
  }

  private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    let mask: Int32 = 1 << bitOffset

    withUnsafeMutableBytes(of: &set.fds_bits) { ptr in
      let base = ptr.baseAddress!.assumingMemoryBound(to: Int32.self)
      base[intOffset] |= mask
    }
  }
#else
  private func fdZero(_ set: inout fd_set) {
    _ = withUnsafeMutableBytes(of: &set) { ptr in
      ptr.baseAddress?.initializeMemory(
        as: UInt8.self, repeating: 0, count: MemoryLayout<fd_set>.size)
    }
  }

  private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / (MemoryLayout<Int>.size * 8)
    let bitOffset = Int(fd) % (MemoryLayout<Int>.size * 8)
    let mask: Int = 1 << bitOffset

    withUnsafeMutableBytes(of: &set.__fds_bits) { ptr in
      let base = ptr.baseAddress!.assumingMemoryBound(to: Int.self)
      base[intOffset] |= mask
    }
  }
#endif

// MARK: - Errors

public enum TCPProbeError: Error {
  case resolutionFailed
  case socketCreationFailed
  case connectionFailed(String)
  case timeout
}
