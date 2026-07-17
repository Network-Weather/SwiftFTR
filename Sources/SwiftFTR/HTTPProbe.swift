import Foundation

/// Configuration for an HTTP or HTTPS probe.
public struct HTTPProbeConfig: Sendable {
  /// The URL to probe.
  public let url: String

  /// The timeout in seconds.
  public let timeout: TimeInterval

  /// A Boolean value that indicates whether the probe follows redirects.
  public let followRedirects: Bool

  /// Creates a configuration for an HTTP or HTTPS probe.
  ///
  /// - Parameters:
  ///   - url: The URL to probe.
  ///   - timeout: The timeout in seconds. The value must be finite and greater than zero.
  ///   - followRedirects: Whether the probe follows redirects.
  public init(
    url: String,
    timeout: TimeInterval = 2.0,
    followRedirects: Bool = false
  ) {
    self.url = url
    self.timeout = timeout
    self.followRedirects = followRedirects
  }
}

/// The result of an HTTP or HTTPS probe.
public struct HTTPProbeResult: Sendable, Codable {
  /// The target URL.
  public let url: String

  /// A Boolean value that indicates whether the server responded.
  public let isReachable: Bool

  /// The HTTP status code, or `nil` if the server did not return HTTP headers.
  public let statusCode: Int?

  /// The elapsed time through receipt of the response headers, including connection setup.
  public let rtt: TimeInterval?

  /// The elapsed time from completing the request to receiving the response headers.
  public let networkRTT: TimeInterval?

  /// The TCP connection-establishment time reported by URLSession.
  public let tcpHandshakeRTT: TimeInterval?

  /// The error message, if the probe failed.
  public let error: String?

  /// The time at which the probe started.
  public let timestamp: Date

  /// Creates an HTTP probe result.
  ///
  /// - Parameters:
  ///   - url: The target URL.
  ///   - isReachable: Whether the server responded.
  ///   - statusCode: The HTTP status code, if available.
  ///   - rtt: The elapsed time through receipt of the response headers.
  ///   - networkRTT: The request-to-response timing reported by URLSession.
  ///   - tcpHandshakeRTT: The connection-establishment timing reported by URLSession.
  ///   - error: The error message, if the probe failed.
  ///   - timestamp: The time at which the probe started.
  public init(
    url: String,
    isReachable: Bool,
    statusCode: Int?,
    rtt: TimeInterval?,
    networkRTT: TimeInterval? = nil,
    tcpHandshakeRTT: TimeInterval? = nil,
    error: String?,
    timestamp: Date = Date()
  ) {
    self.url = url
    self.statusCode = statusCode
    self.isReachable = isReachable
    self.rtt = rtt
    self.networkRTT = networkRTT
    self.tcpHandshakeRTT = tcpHandshakeRTT
    self.error = error
    self.timestamp = timestamp
  }
}

/// Tests whether a web server returns HTTP response headers.
///
/// Any HTTP response, including a 4xx or 5xx response, indicates reachability. The probe stops
/// downloading after the response headers arrive.
///
/// - Parameters:
///   - url: The HTTP or HTTPS URL to probe.
///   - timeout: The timeout in seconds. The value must be finite and greater than zero.
/// - Returns: The probe result.
#if compiler(>=6.2)
  @concurrent
#endif
public func httpProbe(
  url: String,
  timeout: TimeInterval = 2.0
) async throws -> HTTPProbeResult {
  let config = HTTPProbeConfig(url: url, timeout: timeout)
  return try await httpProbe(config: config)
}

/// Tests whether a web server returns HTTP response headers using the specified configuration.
///
/// Any HTTP response, including a 4xx or 5xx response, indicates reachability. The probe stops
/// downloading after the response headers arrive.
///
/// - Parameter config: The probe configuration.
/// - Returns: The probe result.
#if compiler(>=6.2)
  @concurrent
#endif
public func httpProbe(config: HTTPProbeConfig) async throws -> HTTPProbeResult {
  try await httpProbe(config: config, sessionConfiguration: .ephemeral)
}

/// Test seam for deterministic URL loading tests.
func httpProbe(
  config: HTTPProbeConfig,
  sessionConfiguration: URLSessionConfiguration
) async throws -> HTTPProbeResult {
  let startTime = Date()

  guard config.timeout.isFinite, config.timeout > 0 else {
    return failedHTTPProbe(
      config: config,
      startedAt: startTime,
      error: "Invalid timeout: expected a finite value greater than zero")
  }

  guard let url = validatedHTTPURL(from: config.url) else {
    return failedHTTPProbe(config: config, startedAt: startTime, error: "Invalid HTTP URL")
  }

  sessionConfiguration.timeoutIntervalForRequest = config.timeout
  sessionConfiguration.timeoutIntervalForResource = config.timeout
  sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData

  let delegate = HTTPHeaderProbeDelegate(followRedirects: config.followRedirects)
  let session = URLSession(
    configuration: sessionConfiguration,
    delegate: delegate,
    delegateQueue: nil)
  defer { session.invalidateAndCancel() }

  do {
    let response = try await delegate.response(for: url, using: session)
    return HTTPProbeResult(
      url: config.url,
      isReachable: true,
      statusCode: response.statusCode,
      rtt: response.receivedAt.timeIntervalSince(startTime),
      networkRTT: response.networkRTT,
      tcpHandshakeRTT: response.tcpHandshakeRTT,
      error: nil,
      timestamp: startTime
    )
  } catch {
    return resultForHTTPProbeError(error, config: config, startedAt: startTime)
  }
}

private func validatedHTTPURL(from value: String) -> URL? {
  guard
    let components = URLComponents(string: value),
    let scheme = components.scheme?.lowercased(),
    scheme == "http" || scheme == "https",
    let host = components.host,
    !host.isEmpty,
    let url = components.url
  else {
    return nil
  }
  return url
}

private func failedHTTPProbe(
  config: HTTPProbeConfig,
  startedAt: Date,
  rtt: TimeInterval? = nil,
  isReachable: Bool = false,
  error: String
) -> HTTPProbeResult {
  HTTPProbeResult(
    url: config.url,
    isReachable: isReachable,
    statusCode: nil,
    rtt: rtt,
    error: error,
    timestamp: startedAt)
}

private func resultForHTTPProbeError(
  _ error: any Error,
  config: HTTPProbeConfig,
  startedAt: Date
) -> HTTPProbeResult {
  if error is CancellationError {
    return failedHTTPProbe(
      config: config,
      startedAt: startedAt,
      rtt: Date().timeIntervalSince(startedAt),
      error: "Cancelled")
  }

  let urlError = error as? URLError
  switch urlError?.code {
  case .timedOut:
    return failedHTTPProbe(config: config, startedAt: startedAt, error: "Timeout")
  case .cannotConnectToHost, .networkConnectionLost:
    return failedHTTPProbe(
      config: config,
      startedAt: startedAt,
      rtt: Date().timeIntervalSince(startedAt),
      error: "Connection failed: \(error.localizedDescription)")
  case .serverCertificateUntrusted, .secureConnectionFailed:
    return failedHTTPProbe(
      config: config,
      startedAt: startedAt,
      rtt: Date().timeIntervalSince(startedAt),
      isReachable: true,
      error: "SSL/TLS error (server reachable): \(error.localizedDescription)")
  default:
    return failedHTTPProbe(
      config: config,
      startedAt: startedAt,
      rtt: Date().timeIntervalSince(startedAt),
      error: error.localizedDescription)
  }
}

private struct HTTPHeaderProbeResponse: Sendable {
  let statusCode: Int
  let receivedAt: Date
  let networkRTT: TimeInterval?
  let tcpHandshakeRTT: TimeInterval?
}

private struct HTTPResponseHeaders: Sendable {
  let statusCode: Int
  let receivedAt: Date
}

private final class HTTPHeaderProbeDelegate: NSObject, URLSessionDataDelegate,
  @unchecked Sendable
{
  private struct State {
    var continuation: CheckedContinuation<HTTPHeaderProbeResponse, any Error>?
    var task: URLSessionDataTask?
    var headers: HTTPResponseHeaders?
    var metrics: URLSessionTaskMetrics?
    var isCancellationRequested = false
    var isComplete = false
  }

  private let followRedirects: Bool
  private let lock = NSLock()
  private var state = State()

  init(followRedirects: Bool) {
    self.followRedirects = followRedirects
  }

  func response(for url: URL, using session: URLSession) async throws -> HTTPHeaderProbeResponse {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let task = session.dataTask(with: url)
        install(task: task, continuation: continuation)
      }
    } onCancel: {
      self.cancel()
    }
  }

  private func install(
    task: URLSessionDataTask,
    continuation: CheckedContinuation<HTTPHeaderProbeResponse, any Error>
  ) {
    lock.lock()
    if state.isCancellationRequested {
      state.isComplete = true
      lock.unlock()
      task.cancel()
      continuation.resume(throwing: CancellationError())
      return
    }

    state.task = task
    state.continuation = continuation
    lock.unlock()
    task.resume()
  }

  private func cancel() {
    lock.lock()
    state.isCancellationRequested = true
    guard !state.isComplete, let continuation = state.continuation else {
      lock.unlock()
      return
    }

    state.isComplete = true
    let task = state.task
    state.task = nil
    state.continuation = nil
    lock.unlock()

    task?.cancel()
    continuation.resume(throwing: CancellationError())
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void
  ) {
    completionHandler(followRedirects ? request : nil)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    if !state.isComplete, let response = response as? HTTPURLResponse {
      state.headers = HTTPResponseHeaders(statusCode: response.statusCode, receivedAt: Date())
    }
    lock.unlock()

    // Reachability only needs response headers. Cancelling here prevents URLSession from buffering
    // an arbitrarily large or unbounded response body.
    completionHandler(.cancel)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    lock.lock()
    state.metrics = metrics
    lock.unlock()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    lock.lock()
    guard !state.isComplete, let continuation = state.continuation else {
      lock.unlock()
      return
    }

    state.isComplete = true
    state.task = nil
    state.continuation = nil
    let headers = state.headers
    let metrics = state.metrics
    lock.unlock()

    if let headers {
      let timing = extractTimingMetrics(from: metrics)
      continuation.resume(
        returning: HTTPHeaderProbeResponse(
          statusCode: headers.statusCode,
          receivedAt: headers.receivedAt,
          networkRTT: timing.networkRTT,
          tcpHandshakeRTT: timing.tcpHandshakeRTT))
    } else if let error {
      continuation.resume(throwing: error)
    } else {
      continuation.resume(throwing: URLError(.badServerResponse))
    }
  }
}

private func extractTimingMetrics(from taskMetrics: URLSessionTaskMetrics?) -> (
  networkRTT: TimeInterval?, tcpHandshakeRTT: TimeInterval?
) {
  guard let transaction = taskMetrics?.transactionMetrics.last else {
    return (nil, nil)
  }

  let tcpHandshakeRTT: TimeInterval? =
    if let connectStart = transaction.connectStartDate,
      let connectEnd = transaction.connectEndDate
    {
      connectEnd.timeIntervalSince(connectStart)
    } else {
      nil
    }

  #if DEBUG
    if ProcessInfo.processInfo.environment["SWIFTFTR_VERBOSE_HTTP_TIMING"] == "1",
      let domainLookupStart = transaction.domainLookupStartDate,
      let domainLookupEnd = transaction.domainLookupEndDate,
      let connectStart = transaction.connectStartDate,
      let connectEnd = transaction.connectEndDate,
      let requestStart = transaction.requestStartDate,
      let requestEnd = transaction.requestEndDate,
      let responseStart = transaction.responseStartDate,
      let responseEnd = transaction.responseEndDate
    {

      let dnsTime = domainLookupEnd.timeIntervalSince(domainLookupStart) * 1000
      let tcpTime = connectEnd.timeIntervalSince(connectStart) * 1000
      let requestTime = requestEnd.timeIntervalSince(requestStart) * 1000
      let networkRTTTime = responseStart.timeIntervalSince(requestEnd) * 1000
      let responseTime = responseEnd.timeIntervalSince(responseStart) * 1000
      let tlsTime: Double? =
        if let secureConnectionStart = transaction.secureConnectionStartDate,
          let secureConnectionEnd = transaction.secureConnectionEndDate
        {
          secureConnectionEnd.timeIntervalSince(secureConnectionStart) * 1000
        } else {
          nil
        }

      let summary = [
        "dns=\(String(format: "%.1f", dnsTime))ms",
        "tcp=\(String(format: "%.1f", tcpTime))ms",
        tlsTime.map { "tls=\(String(format: "%.1f", $0))ms" },
        "req=\(String(format: "%.1f", requestTime))ms",
        "networkRTT=\(String(format: "%.1f", networkRTTTime))ms",
        "resp=\(String(format: "%.1f", responseTime))ms",
      ].compactMap { $0 }.joined(separator: " ")

      print("📊 HTTP timing \(summary)")
    }
  #endif

  let networkRTT: TimeInterval?
  if let requestEnd = transaction.requestEndDate,
    let responseStartDate = transaction.responseStartDate
  {
    let rtt = responseStartDate.timeIntervalSince(requestEnd)
    networkRTT = rtt > 0 && rtt < 60 ? rtt : nil
  } else {
    networkRTT = nil
  }

  return (networkRTT, tcpHandshakeRTT)
}
