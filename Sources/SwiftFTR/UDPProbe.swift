import Dispatch
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Configuration for UDP probing.
///
/// Values are validated by ``udpProbe(config:)`` before resolution or socket creation.
public struct UDPProbeConfig: Sendable {
  /// Target host (hostname or IP)
  public let host: String

  /// Target port
  public let port: Int

  /// Timeout for probe in seconds (default: 2.0)
  public let timeout: TimeInterval

  /// Payload to send (default: empty)
  public let payload: Data

  /// IP family preference. Defaults to `.auto` (let the resolved address decide).
  /// See `PreferredFamily` and `docs/IPV6.md`.
  public let preferredFamily: PreferredFamily

  public init(
    host: String,
    port: Int,
    timeout: TimeInterval = 2.0,
    payload: Data = Data(),
    preferredFamily: PreferredFamily = .auto
  ) {
    self.host = host
    self.port = port
    self.timeout = timeout
    self.payload = payload
    self.preferredFamily = preferredFamily
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
#if compiler(>=6.2)
  @concurrent
#endif
public func udpProbe(
  host: String,
  port: Int,
  timeout: TimeInterval = 2.0,
  payload: Data = Data()
) async throws -> UDPProbeResult {
  let config = UDPProbeConfig(host: host, port: port, timeout: timeout, payload: payload)
  return try await udpProbe(config: config)
}

#if compiler(>=6.2)
  @concurrent
#endif
public func udpProbe(config: UDPProbeConfig) async throws -> UDPProbeResult {
  try config.validateForOperation()

  let startTime = Date()

  // Resolve via the shared dual-stack helper (Hostname.swift).
  let resolved: ResolvedHost
  do {
    resolved = try resolveHost(host: config.host, prefer: config.preferredFamily)
  } catch {
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

  let result = try await performUDPProbe(
    resolved: resolved,
    port: config.port,
    payload: config.payload,
    timeout: config.timeout,
    startTime: startTime
  )

  return UDPProbeResult(
    host: config.host,
    resolvedIP: resolved.canonical,
    port: config.port,
    isReachable: result.isReachable,
    rtt: result.rtt,
    responseType: result.responseType,
    error: result.error,
    timestamp: startTime
  )
}

// MARK: - Private Implementation

private struct UDPProbeResultInternal {
  let isReachable: Bool
  let rtt: TimeInterval?
  let responseType: String?
  let error: String?
}

private func performUDPProbe(
  resolved: ResolvedHost,
  port: Int,
  payload: Data,
  timeout: TimeInterval,
  startTime: Date
) async throws -> UDPProbeResultInternal {
  // Family-aware socket. v4 → AF_INET, v6 → AF_INET6.
  let sockfd = socket(resolved.family, SOCK_DGRAM, IPPROTO_UDP)
  guard sockfd >= 0 else {
    return UDPProbeResultInternal(
      isReachable: false, rtt: nil, responseType: nil,
      error: "Failed to create UDP socket")
  }

  var flags = fcntl(sockfd, F_GETFL, 0)
  flags |= O_NONBLOCK
  _ = fcntl(sockfd, F_SETFL, flags)

  // Build the destination sockaddr from the resolved family + port.
  var destAddr = resolved.address
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

  // Connect the UDP socket - this allows the kernel to deliver ICMP/ICMPv6
  // errors as ECONNREFUSED on recv(), avoiding the need for a raw ICMP socket.
  let connectResult = withUnsafePointer(to: &destAddr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(sockfd, $0, destLen)
    }
  }

  guard connectResult == 0 else {
    close(sockfd)
    return UDPProbeResultInternal(
      isReachable: false,
      rtt: nil,
      responseType: nil,
      error: "Failed to connect: \(String(cString: strerror(errno)))"
    )
  }

  // Record start time using monotonic clock
  let probeStartTime = udpMonotonicTime()

  // Send UDP packet using send() (not sendto() - socket is connected)
  let payloadBytes = payload.count > 0 ? Array(payload) : [0x00]
  let sendResult = payloadBytes.withUnsafeBufferPointer { buffer in
    send(sockfd, buffer.baseAddress, buffer.count, 0)
  }

  guard sendResult >= 0 else {
    close(sockfd)
    return UDPProbeResultInternal(
      isReachable: false,
      rtt: nil,
      responseType: nil,
      error: "Failed to send: \(String(cString: strerror(errno)))"
    )
  }

  // Use DispatchSource for non-blocking async I/O
  let operation = UDPProbeOperation(
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
private func udpMonotonicTime() -> TimeInterval {
  var info = mach_timebase_info_data_t()
  mach_timebase_info(&info)
  let rawTime = TimeInterval(mach_absolute_time())
  return (rawTime * TimeInterval(info.numer) / TimeInterval(info.denom)) / 1_000_000_000.0
}

// MARK: - UDP Probe Operation

/// Manages a single UDP probe operation using DispatchSource for non-blocking I/O
private final class UDPProbeOperation: @unchecked Sendable {
  private let sockfd: Int32
  private let timeout: TimeInterval
  private let probeStartTime: TimeInterval

  private var continuation: CheckedContinuation<UDPProbeResultInternal, Never>?
  private var readSource: DispatchSourceRead?
  private var timerSource: DispatchSourceTimer?

  private let queue: DispatchQueue
  private let lock = NSLock()
  private var isFinished = false

  // Receive buffer for UDP responses
  private var recvBuffer = [UInt8](repeating: 0, count: 1024)

  init(sockfd: Int32, timeout: TimeInterval, probeStartTime: TimeInterval) {
    self.sockfd = sockfd
    self.timeout = timeout
    self.probeStartTime = probeStartTime
    self.queue = DispatchQueue(
      label: "com.swiftftr.udpprobe.\(UInt64.random(in: 0...UInt64.max))",
      qos: .userInitiated
    )
  }

  func start(continuation: CheckedContinuation<UDPProbeResultInternal, Never>) {
    lock.lock()
    if isFinished {
      lock.unlock()
      continuation.resume(
        returning: UDPProbeResultInternal(
          isReachable: false, rtt: nil, responseType: nil, error: "Operation already finished"))
      return
    }
    self.continuation = continuation
    lock.unlock()

    queue.async {
      self.setupSources()
    }
  }

  private func setupSources() {
    // DispatchSourceRead fires when socket becomes readable (response arrives or ICMP error)
    let source = DispatchSource.makeReadSource(fileDescriptor: sockfd, queue: queue)
    source.setEventHandler { [weak self] in
      self?.handleRead()
    }
    source.setCancelHandler {}
    source.activate()
    self.readSource = source

    // Timer for timeout
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { [weak self] in
      self?.handleTimeout()
    }
    timer.activate()
    self.timerSource = timer
  }

  private func handleRead() {
    lock.lock()
    if isFinished {
      lock.unlock()
      return
    }
    lock.unlock()

    // Try to receive data
    let bytesRead = recv(sockfd, &recvBuffer, recvBuffer.count, 0)

    if bytesRead > 0 {
      // Got UDP reply
      let rtt = udpMonotonicTime() - probeStartTime
      finish(
        result: UDPProbeResultInternal(
          isReachable: true,
          rtt: rtt,
          responseType: "udp_reply",
          error: nil
        ))
      return
    }

    if bytesRead < 0 {
      let err = errno

      // ECONNREFUSED = ICMP Port Unreachable (host is up!)
      if err == ECONNREFUSED {
        let rtt = udpMonotonicTime() - probeStartTime
        finish(
          result: UDPProbeResultInternal(
            isReachable: true,
            rtt: rtt,
            responseType: "icmp_port_unreachable",
            error: nil
          ))
        return
      }

      // EAGAIN/EWOULDBLOCK = no data available (spurious wakeup, keep waiting)
      if err == EAGAIN || err == EWOULDBLOCK {
        return
      }

      // Network unreachable errors = host down
      if err == EHOSTUNREACH || err == ENETUNREACH || err == EHOSTDOWN {
        finish(
          result: UDPProbeResultInternal(
            isReachable: false,
            rtt: nil,
            responseType: nil,
            error: "Network unreachable: \(String(cString: strerror(err)))"
          ))
        return
      }

      // Other errors
      finish(
        result: UDPProbeResultInternal(
          isReachable: false,
          rtt: nil,
          responseType: nil,
          error: "Receive error: \(String(cString: strerror(err)))"
        ))
    }
  }

  private func handleTimeout() {
    finish(
      result: UDPProbeResultInternal(
        isReachable: false,
        rtt: nil,
        responseType: "timeout",
        error: "No response within timeout"
      ))
  }

  private func finish(result: UDPProbeResultInternal) {
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
    readSource?.cancel()
    timerSource?.cancel()
    readSource = nil
    timerSource = nil

    // Close socket
    close(sockfd)

    // Resume continuation
    currentContinuation?.resume(returning: result)
  }
}

// MARK: - Errors

public enum UDPProbeError: Error {
  case resolutionFailed
  case socketCreationFailed
  case sendFailed
  case timeout
}
