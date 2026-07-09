import Dispatch
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

  /// Network interface to use for this UDP probe, or `nil` to use system routing.
  public let interface: String?

  /// Source IP address to use for this UDP probe, or `nil` to let the system choose.
  ///
  /// The address must match the resolved destination's address family and be assigned
  /// to the selected interface when ``interface`` is also set.
  public let sourceIP: String?

  /// IP family preference. Defaults to `.auto` (let the resolved address decide).
  /// See `PreferredFamily` and `docs/IPV6.md`.
  public let preferredFamily: PreferredFamily

  /// Creates a UDP probe configuration.
  ///
  /// - Parameters:
  ///   - host: The destination hostname or IP address.
  ///   - port: The destination UDP port.
  ///   - timeout: The maximum time to wait for a response, in seconds.
  ///   - payload: The datagram payload. An empty value sends a zero-byte datagram.
  ///   - interface: The network interface to use, or `nil` to use system routing.
  ///   - sourceIP: The source address to use, or `nil` to let the system choose.
  ///   - preferredFamily: The address family to prefer during resolution.
  public init(
    host: String,
    port: Int,
    timeout: TimeInterval = 2.0,
    payload: Data = Data(),
    interface: String? = nil,
    sourceIP: String? = nil,
    preferredFamily: PreferredFamily = .auto
  ) {
    self.host = host
    self.port = port
    self.timeout = timeout
    self.payload = payload
    self.interface = interface
    self.sourceIP = sourceIP
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

/// Sends a UDP datagram and waits for a response or ICMP port-unreachable message.
///
/// The probe uses a connected UDP socket so the kernel can deliver ICMP errors
/// without requiring a raw socket.
///
/// - Parameters:
///   - host: The destination hostname or IP address.
///   - port: The destination UDP port.
///   - timeout: The maximum time to wait for a response, in seconds.
///   - payload: The datagram payload. An empty value sends a zero-byte datagram.
///   - interface: The network interface to use, or `nil` to use system routing.
///   - sourceIP: The source address to use, or `nil` to let the system choose.
/// - Returns: The probe result, including reachability, timing, and any operation error.
/// - Throws: `CancellationError` if the calling task is canceled.
#if compiler(>=6.2)
  @concurrent
#endif
public func udpProbe(
  host: String,
  port: Int,
  timeout: TimeInterval = 2.0,
  payload: Data = Data(),
  interface: String? = nil,
  sourceIP: String? = nil
) async throws -> UDPProbeResult {
  let config = UDPProbeConfig(
    host: host,
    port: port,
    timeout: timeout,
    payload: payload,
    interface: interface,
    sourceIP: sourceIP
  )
  return try await udpProbe(config: config)
}

/// Sends a UDP probe using the supplied configuration.
///
/// - Parameter config: The destination, payload, routing, and timeout settings.
/// - Returns: The probe result, including reachability, timing, and any operation error.
/// - Throws: `CancellationError` if the calling task is canceled.
#if compiler(>=6.2)
  @concurrent
#endif
public func udpProbe(config: UDPProbeConfig) async throws -> UDPProbeResult {
  try Task.checkCancellation()
  let startTime = Date()

  // Resolve via the shared dual-stack helper (Hostname.swift).
  let resolved: ResolvedHost
  do {
    resolved = try resolveHost(host: config.host, prefer: config.preferredFamily)
  } catch {
    try Task.checkCancellation()
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
    interface: config.interface,
    sourceIP: config.sourceIP
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
  interface: String?,
  sourceIP: String?
) async throws -> UDPProbeResultInternal {
  try Task.checkCancellation()

  // Family-aware socket. v4 → AF_INET, v6 → AF_INET6.
  let sockfd = socket(resolved.family, SOCK_DGRAM, IPPROTO_UDP)
  guard sockfd >= 0 else {
    return UDPProbeResultInternal(
      isReachable: false, rtt: nil, responseType: nil,
      error: "Failed to create UDP socket")
  }

  var operationOwnsSocket = false
  defer {
    if !operationOwnsSocket {
      close(sockfd)
    }
  }

  if let interface {
    #if canImport(Darwin)
      let interfaceIndex = if_nametoindex(interface)
      guard interfaceIndex != 0 else {
        return UDPProbeResultInternal(
          isReachable: false,
          rtt: nil,
          responseType: nil,
          error: "Interface '\(interface)' not found"
        )
      }
      if let error = bindInterface(
        sockfd: sockfd,
        family: resolved.family,
        ifIndex: interfaceIndex
      ) {
        return UDPProbeResultInternal(
          isReachable: false,
          rtt: nil,
          responseType: nil,
          error: "Failed to bind to interface '\(interface)': \(error)"
        )
      }
    #else
      return UDPProbeResultInternal(
        isReachable: false,
        rtt: nil,
        responseType: nil,
        error: "Interface binding is not supported on this platform"
      )
    #endif
  }

  if let sourceIP,
    let error = bindSourceIP(
      sockfd: sockfd,
      family: resolved.family,
      sourceIP: sourceIP
    )
  {
    return UDPProbeResultInternal(
      isReachable: false,
      rtt: nil,
      responseType: nil,
      error: error
    )
  }

  try Task.checkCancellation()

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
  let sendResult = payload.withUnsafeBytes { buffer -> ssize_t in
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

  // Use DispatchSource for non-blocking async I/O
  let operation = UDPProbeOperation(
    sockfd: sockfd,
    timeout: timeout,
    probeStartTime: probeStartTime
  )
  operationOwnsSocket = true

  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      operation.start(continuation: continuation)
    }
  } onCancel: {
    operation.cancel()
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

/// Manages a single UDP probe operation using DispatchSource for non-blocking I/O.
///
/// Cross-task completion state is protected by `lock`; descriptor I/O and source
/// ownership are confined to `queue`. The unchecked conformance records those
/// synchronization guarantees for Dispatch callbacks.
private final class UDPProbeOperation: @unchecked Sendable {
  private let sockfd: Int32
  private let timeout: TimeInterval
  private let probeStartTime: TimeInterval

  private var continuation: CheckedContinuation<UDPProbeResultInternal, Error>?
  private var terminalResult: Result<UDPProbeResultInternal, Error>?
  private var readSource: DispatchSourceRead?
  private var timerSource: DispatchSourceTimer?
  private var isCleanedUp = false

  private let queue: DispatchQueue
  private let lock = NSLock()

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

  func start(continuation: CheckedContinuation<UDPProbeResultInternal, Error>) {
    lock.lock()
    if let terminalResult {
      lock.unlock()
      continuation.resume(with: terminalResult)
      return
    }
    self.continuation = continuation
    lock.unlock()

    queue.async {
      self.setupSources()
    }
  }

  func cancel() {
    queue.async {
      self.finish(error: CancellationError())
    }
  }

  private func setupSources() {
    lock.lock()
    let isFinished = terminalResult != nil
    lock.unlock()
    guard !isFinished else { return }

    // DispatchSourceRead fires when socket becomes readable (response arrives or ICMP error)
    let source = DispatchSource.makeReadSource(fileDescriptor: sockfd, queue: queue)
    source.setEventHandler { [weak self] in
      self?.handleRead()
    }
    source.setCancelHandler { [self] in
      completeCleanup()
    }
    self.readSource = source
    source.activate()

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
    if terminalResult != nil {
      lock.unlock()
      return
    }
    lock.unlock()

    // Try to receive data
    let bytesRead = recv(sockfd, &recvBuffer, recvBuffer.count, 0)

    if bytesRead >= 0 {
      // Got a UDP reply. A zero-byte UDP datagram is a valid reply.
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
    finish(with: .success(result))
  }

  private func finish(error: any Error) {
    finish(with: .failure(error))
  }

  private func finish(with result: Result<UDPProbeResultInternal, Error>) {
    lock.lock()
    if terminalResult != nil {
      lock.unlock()
      return
    }
    terminalResult = result
    lock.unlock()

    // Cancel the timer first, then use the read source's cancellation handler
    // as a barrier before closing the descriptor. This prevents an already
    // enqueued read handler from observing a reused descriptor.
    timerSource?.cancel()
    timerSource = nil

    if let readSource {
      self.readSource = nil
      readSource.cancel()
    } else {
      completeCleanup()
    }
  }

  private func completeCleanup() {
    lock.lock()
    guard !isCleanedUp, let terminalResult else {
      lock.unlock()
      return
    }
    isCleanedUp = true
    let currentContinuation = continuation
    continuation = nil
    lock.unlock()

    close(sockfd)
    currentContinuation?.resume(with: terminalResult)
  }
}

// MARK: - Errors

public enum UDPProbeError: Error {
  case resolutionFailed
  case socketCreationFailed
  case sendFailed
  case timeout
}
