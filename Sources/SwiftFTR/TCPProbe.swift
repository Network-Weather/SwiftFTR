import Dispatch
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

  /// IP family preference. Defaults to `.auto` (let the resolved address decide).
  /// See `PreferredFamily` and `docs/IPV6.md`.
  public let preferredFamily: PreferredFamily

  public init(
    host: String,
    port: Int,
    timeout: TimeInterval = 2.0,
    interface: String? = nil,
    sourceIP: String? = nil,
    preferredFamily: PreferredFamily = .auto
  ) {
    self.host = host
    self.port = port
    self.timeout = timeout
    self.interface = interface
    self.sourceIP = sourceIP
    self.preferredFamily = preferredFamily
  }
}

/// TCP connection state after probing
public enum TCPConnectionState: String, Sendable, Codable {
  /// Port is open (SYN-ACK received, connection established)
  case open
  /// Port is closed (RST received - host is up but port not listening)
  case closed
  /// Port is filtered (timeout - no response, possibly firewalled)
  case filtered
  /// Other error (network unreachable, etc.)
  case error
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

  /// TCP connection state: open (SYN-ACK), closed (RST), filtered (timeout), or error
  public let connectionState: TCPConnectionState

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
    connectionState: TCPConnectionState,
    rtt: TimeInterval?,
    error: String?,
    timestamp: Date = Date()
  ) {
    self.host = host
    self.resolvedIP = resolvedIP
    self.port = port
    self.isReachable = isReachable
    self.connectionState = connectionState
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

  // Resolve via the shared dual-stack helper (Hostname.swift).
  let resolved: ResolvedHost
  do {
    resolved = try resolveHost(host: config.host, prefer: config.preferredFamily)
  } catch {
    return TCPProbeResult(
      host: config.host,
      resolvedIP: config.host,
      port: config.port,
      isReachable: false,
      connectionState: .error,
      rtt: nil,
      error: "Failed to resolve hostname",
      timestamp: startTime
    )
  }

  let result = try await performTCPProbe(
    resolved: resolved,
    port: config.port,
    timeout: config.timeout,
    startTime: startTime,
    interface: config.interface,
    sourceIP: config.sourceIP
  )

  return TCPProbeResult(
    host: config.host,
    resolvedIP: resolved.canonical,
    port: config.port,
    isReachable: result.isReachable,
    connectionState: result.connectionState,
    rtt: result.rtt,
    error: result.error,
    timestamp: startTime
  )
}

// MARK: - Private Implementation

private struct ProbeResult {
  let isReachable: Bool
  let connectionState: TCPConnectionState
  let rtt: TimeInterval?
  let error: String?
}

private func performTCPProbe(
  resolved: ResolvedHost,
  port: Int,
  timeout: TimeInterval,
  startTime: Date,
  interface: String?,
  sourceIP: String?
) async throws -> ProbeResult {
  // Family-aware socket. v4 → AF_INET, v6 → AF_INET6.
  let sockfd = socket(resolved.family, SOCK_STREAM, 0)
  guard sockfd >= 0 else {
    return ProbeResult(
      isReachable: false, connectionState: .error, rtt: nil,
      error: "Failed to create socket: \(String(cString: strerror(errno)))")
  }

  if let iface = interface {
    #if canImport(Darwin)
      let ifaceIndex = if_nametoindex(iface)
      guard ifaceIndex != 0 else {
        close(sockfd)
        return ProbeResult(
          isReachable: false, connectionState: .error, rtt: nil,
          error: "Interface '\(iface)' not found")
      }
      if let errMsg = bindInterface(sockfd: sockfd, family: resolved.family, ifIndex: ifaceIndex) {
        close(sockfd)
        return ProbeResult(
          isReachable: false, connectionState: .error, rtt: nil,
          error: "Failed to bind to interface '\(iface)': \(errMsg)")
      }
    #else
      close(sockfd)
      return ProbeResult(
        isReachable: false, connectionState: .error, rtt: nil,
        error: "Interface binding not supported on this platform")
    #endif
  }

  if let srcIP = sourceIP {
    if let err = bindSourceIP(sockfd: sockfd, family: resolved.family, sourceIP: srcIP) {
      close(sockfd)
      return ProbeResult(
        isReachable: false, connectionState: .error, rtt: nil, error: err)
    }
  }

  // Non-blocking.
  var flags = fcntl(sockfd, F_GETFL, 0)
  flags |= O_NONBLOCK
  _ = fcntl(sockfd, F_SETFL, flags)

  // Build the destination sockaddr from the resolved family + port.
  var destAddr = resolved.address
  // sockaddr_in.sin_port and sockaddr_in6.sin6_port are both at the same
  // offset (after the 2-byte family field), so a single overwrite works.
  // We do it via family-aware rebinding to keep things explicit.
  let destLen: socklen_t
  if resolved.family == AF_INET6 {
    destLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
    withUnsafeMutablePointer(to: &destAddr) { ptr in
      ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
        $0.pointee.sin6_port = in_port_t(port).bigEndian
      }
    }
  } else {
    destLen = socklen_t(MemoryLayout<sockaddr_in>.size)
    withUnsafeMutablePointer(to: &destAddr) { ptr in
      ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee.sin_port = in_port_t(port).bigEndian
      }
    }
  }

  let probeStartTime = monotonicTime()
  let connectResult = withUnsafePointer(to: &destAddr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(sockfd, $0, destLen)
    }
  }

  // If connection succeeded immediately (unlikely but possible)
  if connectResult == 0 {
    let rtt = monotonicTime() - probeStartTime
    close(sockfd)
    return ProbeResult(isReachable: true, connectionState: .open, rtt: rtt, error: nil)
  }

  // Check if connection is in progress
  guard errno == EINPROGRESS else {
    let errorCode = errno
    let errorMsg = String(cString: strerror(errorCode))
    close(sockfd)
    // ECONNREFUSED means port is closed but host is up - still success!
    if errorCode == ECONNREFUSED {
      let rtt = monotonicTime() - probeStartTime
      return ProbeResult(isReachable: true, connectionState: .closed, rtt: rtt, error: nil)
    }
    return ProbeResult(isReachable: false, connectionState: .error, rtt: nil, error: errorMsg)
  }

  // Use DispatchSource for non-blocking async I/O
  let operation = TCPProbeOperation(
    sockfd: sockfd,
    timeout: timeout,
    probeStartTime: probeStartTime
  )

  return await withCheckedContinuation { continuation in
    operation.start(continuation: continuation)
  }
}

// MARK: - Monotonic Time

/// Returns monotonic time in seconds for accurate RTT measurement
private func monotonicTime() -> TimeInterval {
  var info = mach_timebase_info_data_t()
  mach_timebase_info(&info)
  let rawTime = TimeInterval(mach_absolute_time())
  return (rawTime * TimeInterval(info.numer) / TimeInterval(info.denom)) / 1_000_000_000.0
}

// MARK: - TCP Probe Operation

/// Manages a single TCP probe operation using DispatchSource for non-blocking I/O
private final class TCPProbeOperation: @unchecked Sendable {
  private let sockfd: Int32
  private let timeout: TimeInterval
  private let probeStartTime: TimeInterval

  private var continuation: CheckedContinuation<ProbeResult, Never>?
  private var writeSource: DispatchSourceWrite?
  private var timerSource: DispatchSourceTimer?

  private let queue: DispatchQueue
  private let lock = NSLock()
  private var isFinished = false

  init(sockfd: Int32, timeout: TimeInterval, probeStartTime: TimeInterval) {
    self.sockfd = sockfd
    self.timeout = timeout
    self.probeStartTime = probeStartTime
    self.queue = DispatchQueue(
      label: "com.swiftftr.tcpprobe.\(UInt64.random(in: 0...UInt64.max))",
      qos: .userInitiated
    )
  }

  func start(continuation: CheckedContinuation<ProbeResult, Never>) {
    lock.lock()
    if isFinished {
      lock.unlock()
      continuation.resume(
        returning: ProbeResult(
          isReachable: false, connectionState: .error, rtt: nil,
          error: "Operation already finished"))
      return
    }
    self.continuation = continuation
    lock.unlock()

    queue.async {
      self.setupSources()
    }
  }

  private func setupSources() {
    // DispatchSourceWrite fires when socket becomes writable (connect completes)
    let source = DispatchSource.makeWriteSource(fileDescriptor: sockfd, queue: queue)
    source.setEventHandler { [weak self] in
      self?.handleConnectComplete()
    }
    source.setCancelHandler {}
    source.activate()
    self.writeSource = source

    // Timer for timeout
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { [weak self] in
      self?.handleTimeout()
    }
    timer.activate()
    self.timerSource = timer
  }

  private func handleConnectComplete() {
    lock.lock()
    if isFinished {
      lock.unlock()
      return
    }
    lock.unlock()

    // Check if connection succeeded or failed via SO_ERROR
    var error: Int32 = 0
    var errorLen = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(sockfd, SOL_SOCKET, SO_ERROR, &error, &errorLen)

    let rtt = monotonicTime() - probeStartTime

    if error == 0 {
      // Connection succeeded (SYN-ACK received)
      finish(
        result: ProbeResult(
          isReachable: true, connectionState: .open, rtt: rtt, error: nil))
    } else if error == ECONNREFUSED {
      // Port closed but host reachable (RST received)
      finish(
        result: ProbeResult(
          isReachable: true, connectionState: .closed, rtt: rtt, error: nil))
    } else {
      // Other error (network unreachable, etc.)
      let errorMsg = String(cString: strerror(error))
      finish(
        result: ProbeResult(
          isReachable: false, connectionState: .error, rtt: nil, error: errorMsg))
    }
  }

  private func handleTimeout() {
    finish(
      result: ProbeResult(
        isReachable: false, connectionState: .filtered, rtt: nil, error: "Connection timeout"))
  }

  private func finish(result: ProbeResult) {
    lock.lock()
    if isFinished {
      lock.unlock()
      return
    }
    isFinished = true
    let currentContinuation = self.continuation
    self.continuation = nil
    lock.unlock()

    // Cancel sources
    writeSource?.cancel()
    timerSource?.cancel()
    writeSource = nil
    timerSource = nil

    // Close socket
    close(sockfd)

    // Resume continuation
    currentContinuation?.resume(returning: result)
  }
}

// MARK: - Errors

public enum TCPProbeError: Error {
  case resolutionFailed
  case socketCreationFailed
  case connectionFailed(String)
  case timeout
}
