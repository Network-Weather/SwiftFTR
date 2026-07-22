import Dispatch
import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#endif

/// Configuration for TCP probing.
///
/// Numeric values are validated by ``tcpProbe(config:)`` before resolution or socket creation.
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
  /// func probeTCP(interfaceName: String) async throws {
  ///   let snapshot = await NetworkInterfaceDiscovery().discover()
  ///   guard let selectedInterface = snapshot.interface(named: interfaceName),
  ///     selectedInterface.isUp
  ///   else { return }
  ///
  ///   let result = try await tcpProbe(
  ///     config: TCPProbeConfig(
  ///       host: "example.com",
  ///       port: 443,
  ///       interface: selectedInterface.name
  ///     )
  ///   )
  /// }
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

/// Tests TCP reachability by attempting a connection to a host and port.
///
/// A successful connection reports `.open`; an explicit reset reports `.closed`
/// while still marking the host reachable.
///
/// - Parameters:
///   - host: The destination hostname or numeric IP address.
///   - port: The destination TCP port.
///   - timeout: The maximum time to wait for a pending connection, in seconds.
/// - Returns: The reachability result and observed connection state.
/// - Throws: `CancellationError` when the calling task is cancelled.
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
/// Tests TCP reachability using a complete probe configuration.
///
/// - Parameter config: The destination, timeout, address-family, and route settings.
/// - Returns: The reachability result and observed connection state.
/// - Throws: `CancellationError` when the calling task is cancelled.
public func tcpProbe(config: TCPProbeConfig) async throws -> TCPProbeResult {
  try config.validateForOperation()
  try Task.checkCancellation()

  let startTime = Date()

  // Resolve via the shared dual-stack helper (Hostname.swift).
  let resolved: ResolvedHost
  do {
    resolved = try resolveHost(host: config.host, prefer: config.preferredFamily)
  } catch {
    try Task.checkCancellation()
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

  try Task.checkCancellation()

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

struct ProbeResult: Sendable {
  let isReachable: Bool
  let connectionState: TCPConnectionState
  let rtt: TimeInterval?
  let error: String?
}

/// Runs setup-owned cleanup before reporting task cancellation.
///
/// Kept internal so tests can verify that cancellation closes an owned socket
/// before control leaves the synchronous setup phase.
func checkTCPProbeSetupCancellation(onCancel: () -> Void) throws {
  guard Task.isCancelled else {
    return
  }
  onCancel()
  throw CancellationError()
}

private func performTCPProbe(
  resolved: ResolvedHost,
  port: Int,
  timeout: TimeInterval,
  startTime: Date,
  interface: String?,
  sourceIP: String?
) async throws -> ProbeResult {
  try Task.checkCancellation()

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
  let connectError = errno

  // This function owns the descriptor until it either returns an immediate
  // result or hands it to TCPProbeOperation below. Cancellation can arrive
  // during the synchronous bind/connect setup, so close before throwing.
  try checkTCPProbeSetupCancellation {
    _ = close(sockfd)
  }

  // If connection succeeded immediately (unlikely but possible)
  if connectResult == 0 {
    let rtt = monotonicTime() - probeStartTime
    close(sockfd)
    return ProbeResult(isReachable: true, connectionState: .open, rtt: rtt, error: nil)
  }

  // Check if connection is in progress
  guard connectError == EINPROGRESS else {
    let errorCode = connectError
    let errorMsg = String(cString: strerror(errorCode))
    close(sockfd)
    // ECONNREFUSED means port is closed but host is up - still success!
    if errorCode == ECONNREFUSED {
      let rtt = monotonicTime() - probeStartTime
      return ProbeResult(isReachable: true, connectionState: .closed, rtt: rtt, error: nil)
    }
    return ProbeResult(isReachable: false, connectionState: .error, rtt: nil, error: errorMsg)
  }

  // Use DispatchSource for non-blocking async I/O.
  let operation = TCPProbeOperation(
    sockfd: sockfd,
    timeout: timeout,
    probeStartTime: probeStartTime
  )

  return try await operation.run()
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

/// The pair of Dispatch sources owned by a pending TCP connection.
///
/// The cancellation closure requests cancellation of both sources on the
/// operation's private serial queue. Descriptor cleanup is deferred until the
/// write source invokes the cancellation callback supplied to its factory. The
/// unchecked conformance is limited to this wrapper because Dispatch source
/// protocols do not expose Sendable conformances on all supported toolchains.
struct TCPProbeEventSources: @unchecked Sendable {
  let cancel: () -> Void
}

/// Injectable system operations used by `TCPProbeOperation`.
///
/// The production implementation below uses Dispatch sources and socket calls.
/// Tests inject a deterministic event source so cancellation races do not depend
/// on Internet routing or wall-clock time.
struct TCPProbeOperationDependencies: Sendable {
  let makeEventSources:
    @Sendable (
      Int32,
      TimeInterval,
      DispatchQueue,
      @escaping @Sendable () -> Void,
      @escaping @Sendable () -> Void,
      @escaping @Sendable () -> Void
    ) -> TCPProbeEventSources
  let socketError: @Sendable (Int32) -> Int32
  let closeSocket: @Sendable (Int32) -> Void
  let now: @Sendable () -> TimeInterval

  static let live = TCPProbeOperationDependencies(
    makeEventSources: {
      sockfd, timeout, queue, connectCompleted, timedOut, writeSourceDidCancel in
      let writeSource = DispatchSource.makeWriteSource(fileDescriptor: sockfd, queue: queue)
      writeSource.setEventHandler(handler: connectCompleted)
      writeSource.setCancelHandler(handler: writeSourceDidCancel)
      writeSource.activate()

      let timerSource = DispatchSource.makeTimerSource(queue: queue)
      timerSource.schedule(deadline: .now() + timeout)
      timerSource.setEventHandler(handler: timedOut)
      timerSource.activate()

      return TCPProbeEventSources {
        writeSource.cancel()
        timerSource.cancel()
      }
    },
    socketError: { sockfd in
      var error: Int32 = 0
      var errorLength = socklen_t(MemoryLayout<Int32>.size)
      guard getsockopt(sockfd, SOL_SOCKET, SO_ERROR, &error, &errorLength) == 0 else {
        return errno
      }
      return error
    },
    closeSocket: { sockfd in
      _ = close(sockfd)
    },
    now: { monotonicTime() }
  )
}

/// Manages a single TCP probe operation using DispatchSource for non-blocking I/O.
///
/// All Dispatch source and descriptor access is confined to `queue`. Cancellation
/// intent is recorded synchronously under `stateLock`, then cleanup is enqueued on
/// `queue`. The descriptor is closed only after the write source's cancellation
/// handler fires, when Dispatch no longer references it. This ensures a callback
/// queued before cancellation either completes first or observes cancellation
/// before touching the descriptor; a callback can never run socket operations
/// after the descriptor has been closed and reused.
final class TCPProbeOperation: @unchecked Sendable {
  private let sockfd: Int32
  private let timeout: TimeInterval
  private let probeStartTime: TimeInterval
  private let dependencies: TCPProbeOperationDependencies

  private var continuation: CheckedContinuation<ProbeResult, Error>?
  private var eventSources: TCPProbeEventSources?
  private var resultAwaitingSourceCancellation: Result<ProbeResult, Error>?

  private let queue: DispatchQueue
  private let stateLock = NSLock()
  private var isFinished = false
  private var cancellationRequested = false

  init(
    sockfd: Int32,
    timeout: TimeInterval,
    probeStartTime: TimeInterval,
    dependencies: TCPProbeOperationDependencies = .live
  ) {
    self.sockfd = sockfd
    self.timeout = timeout
    self.probeStartTime = probeStartTime
    self.dependencies = dependencies
    self.queue = DispatchQueue(
      label: "com.swiftftr.tcpprobe.\(UInt64.random(in: 0...UInt64.max))",
      qos: .userInitiated
    )
  }

  func run() async throws -> ProbeResult {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        start(continuation: continuation)
      }
    } onCancel: {
      cancel()
    }
  }

  private func start(continuation: CheckedContinuation<ProbeResult, Error>) {
    queue.async {
      if self.finished {
        continuation.resume(throwing: CancellationError())
        return
      }

      self.continuation = continuation

      if self.cancelRequested {
        self.finish(.failure(CancellationError()))
        return
      }

      self.setupSources()

      // Cancellation can arrive while the source factory is installing its
      // callbacks. Check again so source cancellation begins without waiting
      // for the cancellation block already queued behind this setup block.
      if self.cancelRequested {
        self.finish(.failure(CancellationError()))
      }
    }
  }

  func cancel() {
    stateLock.lock()
    guard !isFinished else {
      stateLock.unlock()
      return
    }
    cancellationRequested = true
    stateLock.unlock()

    queue.async {
      self.finish(.failure(CancellationError()))
    }
  }

  private func setupSources() {
    eventSources = dependencies.makeEventSources(
      sockfd,
      timeout,
      queue,
      { [weak self] in self?.handleConnectComplete() },
      { [weak self] in self?.handleTimeout() },
      // Keep the operation alive until Dispatch has stopped referencing the
      // descriptor. `writeSourceDidCancel` breaks this ownership cycle.
      { self.writeSourceDidCancel() }
    )
  }

  private func handleConnectComplete() {
    guard !finished else {
      return
    }

    // Check if connection succeeded or failed via SO_ERROR
    let error = dependencies.socketError(sockfd)

    let rtt = dependencies.now() - probeStartTime

    if error == 0 {
      // Connection succeeded (SYN-ACK received)
      finish(
        .success(
          ProbeResult(
            isReachable: true, connectionState: .open, rtt: rtt, error: nil))
      )
    } else if error == ECONNREFUSED {
      // Port closed but host reachable (RST received)
      finish(
        .success(
          ProbeResult(
            isReachable: true, connectionState: .closed, rtt: rtt, error: nil))
      )
    } else {
      // Other error (network unreachable, etc.)
      let errorMsg = String(cString: strerror(error))
      finish(
        .success(
          ProbeResult(
            isReachable: false, connectionState: .error, rtt: nil, error: errorMsg))
      )
    }
  }

  private func handleTimeout() {
    finish(
      .success(
        ProbeResult(
          isReachable: false, connectionState: .filtered, rtt: nil,
          error: "Connection timeout"))
    )
  }

  private func finish(_ proposedResult: Result<ProbeResult, Error>) {
    stateLock.lock()
    guard !isFinished else {
      stateLock.unlock()
      return
    }
    isFinished = true
    let result: Result<ProbeResult, Error> =
      cancellationRequested ? .failure(CancellationError()) : proposedResult
    stateLock.unlock()

    // A Dispatch source may continue referencing its descriptor after cancel()
    // returns. Keep the sources and continuation alive until the write source's
    // cancellation handler confirms that the descriptor is safe to close.
    if let eventSources {
      resultAwaitingSourceCancellation = result
      eventSources.cancel()
      return
    }

    closeSocketAndResume(with: result)
  }

  /// Called on `queue` after Dispatch has released the write source's descriptor.
  private func writeSourceDidCancel() {
    guard let result = resultAwaitingSourceCancellation else {
      return
    }

    resultAwaitingSourceCancellation = nil
    eventSources = nil
    closeSocketAndResume(with: result)
  }

  private func closeSocketAndResume(with result: Result<ProbeResult, Error>) {
    dependencies.closeSocket(sockfd)

    let currentContinuation = continuation
    continuation = nil

    currentContinuation?.resume(with: result)
  }

  private var finished: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return isFinished
  }

  private var cancelRequested: Bool {
    stateLock.lock()
    defer { stateLock.unlock() }
    return cancellationRequested
  }
}

// MARK: - Errors

public enum TCPProbeError: Error {
  case resolutionFailed
  case socketCreationFailed
  case connectionFailed(String)
  case timeout
}
