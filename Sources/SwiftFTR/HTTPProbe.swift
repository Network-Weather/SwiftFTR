import Foundation

/// Configuration for HTTP/HTTPS probe
public struct HTTPProbeConfig: Sendable {
  /// URL to probe
  public let url: String

  /// Timeout in seconds (default: 2.0)
  public let timeout: TimeInterval

  /// Whether to follow redirects (default: false)
  public let followRedirects: Bool

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

/// Result from HTTP/HTTPS probe
public struct HTTPProbeResult: Sendable, Codable {
  /// Target URL
  public let url: String

  /// Whether server responded (success even on 4xx/5xx)
  public let isReachable: Bool

  /// HTTP status code (nil if timeout or connection error)
  public let statusCode: Int?

  /// Round-trip time (nil if timeout)
  /// NOTE: This is total time including DNS, TCP, TLS setup
  public let rtt: TimeInterval?

  /// Network RTT (request start → response start) on established connection
  /// This is the true network latency after TCP+TLS handshake
  public let networkRTT: TimeInterval?

  /// TCP handshake time (SYN → SYN-ACK)
  /// This is the purest measure of network latency without application overhead
  public let tcpHandshakeRTT: TimeInterval?

  /// Error message (if any)
  public let error: String?

  /// Timestamp
  public let timestamp: Date

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

/// HTTP/HTTPS probe - tests if web server responds
/// Returns success if ANY HTTP response received (even 4xx/5xx)
/// Returns failure only on timeout or connection error
public func httpProbe(
  url: String,
  timeout: TimeInterval = 2.0
) async throws -> HTTPProbeResult {
  let config = HTTPProbeConfig(url: url, timeout: timeout)
  return try await httpProbe(config: config)
}

public func httpProbe(config: HTTPProbeConfig) async throws -> HTTPProbeResult {
  let startTime = Date()

  guard let url = URL(string: config.url) else {
    return HTTPProbeResult(
      url: config.url,
      isReachable: false,
      statusCode: nil,
      rtt: nil,
      error: "Invalid URL",
      timestamp: startTime
    )
  }

  // Configure URLSession
  let sessionConfig = URLSessionConfiguration.ephemeral
  sessionConfig.timeoutIntervalForRequest = config.timeout
  sessionConfig.timeoutIntervalForResource = config.timeout
  sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData

  if !config.followRedirects {
    // Use custom delegate to prevent redirects AND capture metrics
    let delegate = NoRedirectDelegate()
    let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
    return await performProbe(
      url: url, session: session, startTime: startTime, config: config, delegate: delegate)
  } else {
    // Use metrics delegate to capture timing
    let delegate = MetricsDelegate()
    let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
    return await performProbe(
      url: url, session: session, startTime: startTime, config: config, delegate: delegate)
  }
}

private func performProbe<D: URLSessionTaskDelegate>(
  url: URL,
  session: URLSession,
  startTime: Date,
  config: HTTPProbeConfig,
  delegate: D
) async -> HTTPProbeResult where D: AnyObject {
  do {
    let (_, response) = try await session.data(from: url)

    let rtt = Date().timeIntervalSince(startTime)

    // Extract network RTT and TCP handshake RTT from URLSessionTaskMetrics
    let (networkRTT, tcpHandshakeRTT) = extractTimingMetrics(from: delegate)

    if let httpResponse = response as? HTTPURLResponse {
      // Any HTTP response (even 4xx/5xx) means server is reachable
      return HTTPProbeResult(
        url: config.url,
        isReachable: true,
        statusCode: httpResponse.statusCode,
        rtt: rtt,
        networkRTT: networkRTT,
        tcpHandshakeRTT: tcpHandshakeRTT,
        error: nil,
        timestamp: startTime
      )
    } else {
      // Non-HTTP response (shouldn't happen for http/https URLs)
      return HTTPProbeResult(
        url: config.url,
        isReachable: true,
        statusCode: nil,
        rtt: rtt,
        networkRTT: networkRTT,
        tcpHandshakeRTT: tcpHandshakeRTT,
        error: "Non-HTTP response",
        timestamp: startTime
      )
    }
  } catch let error as NSError {
    let rtt = Date().timeIntervalSince(startTime)

    // Check error type
    if error.code == NSURLErrorTimedOut {
      return HTTPProbeResult(
        url: config.url,
        isReachable: false,
        statusCode: nil,
        rtt: nil,
        error: "Timeout",
        timestamp: startTime
      )
    } else if error.code == NSURLErrorCannotConnectToHost
      || error.code == NSURLErrorNetworkConnectionLost
    {
      return HTTPProbeResult(
        url: config.url,
        isReachable: false,
        statusCode: nil,
        rtt: rtt,
        error: "Connection failed: \(error.localizedDescription)",
        timestamp: startTime
      )
    } else if error.code == NSURLErrorServerCertificateUntrusted
      || error.code == NSURLErrorSecureConnectionFailed
    {
      // SSL/TLS error - server is reachable but certificate invalid
      // This counts as success for reachability testing!
      return HTTPProbeResult(
        url: config.url,
        isReachable: true,
        statusCode: nil,
        rtt: rtt,
        error: "SSL/TLS error (server reachable): \(error.localizedDescription)",
        timestamp: startTime
      )
    } else {
      // Other error
      return HTTPProbeResult(
        url: config.url,
        isReachable: false,
        statusCode: nil,
        rtt: rtt,
        error: error.localizedDescription,
        timestamp: startTime
      )
    }
  }
}

/// Extract timing metrics from URLSessionTaskMetrics
/// Returns (networkRTT, tcpHandshakeRTT)
/// - networkRTT: responseStartDate - requestEndDate (request sent → response arrives)
/// - tcpHandshakeRTT: connectEnd - connectStart (TCP 3-way handshake = ~1 RTT)
private func extractTimingMetrics<D: AnyObject>(from delegate: D) -> (TimeInterval?, TimeInterval?)
{
  // Try to access taskMetrics via reflection
  guard let metricsDelegate = delegate as? (any URLSessionTaskDelegate),
    let taskMetrics = (metricsDelegate as? NoRedirectDelegate)?.taskMetrics
      ?? (metricsDelegate as? MetricsDelegate)?.taskMetrics
  else {
    return (nil, nil)
  }

  // Get last transaction metrics (in case of redirects)
  guard let transaction = taskMetrics.transactionMetrics.last else {
    return (nil, nil)
  }

  // Calculate TCP handshake RTT (SYN → SYN-ACK → ACK)
  var tcpHandshakeRTT: TimeInterval? = nil
  if let connectStart = transaction.connectStartDate,
    let connectEnd = transaction.connectEndDate
  {
    tcpHandshakeRTT = connectEnd.timeIntervalSince(connectStart)
  }

  // Log detailed timing breakdown for debugging
  if let domainLookupStart = transaction.domainLookupStartDate,
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

    print("📊 HTTP Timing Breakdown:")
    print("  DNS:             \(String(format: "%6.1fms", dnsTime))")
    print("  TCP handshake:   \(String(format: "%6.1fms", tcpTime)) ← PURE network RTT!")

    // TLS timing (if HTTPS)
    if let secureConnectionStart = transaction.secureConnectionStartDate,
      let secureConnectionEnd = transaction.secureConnectionEndDate
    {
      let tlsTime = secureConnectionEnd.timeIntervalSince(secureConnectionStart) * 1000
      print("  TLS handshake:   \(String(format: "%6.1fms", tlsTime))")
    }

    print("  Request:         \(String(format: "%6.1fms", requestTime))")
    print(
      "  NetworkRTT:      \(String(format: "%6.1fms", networkRTTTime)) (req→resp, includes server processing)"
    )
    print("  Response:        \(String(format: "%6.1fms", responseTime))")
  }

  // Calculate network RTT: responseStartDate - requestEndDate
  // This includes network latency + server processing time
  var networkRTT: TimeInterval? = nil
  if let requestEndDate = transaction.requestEndDate,
    let responseStartDate = transaction.responseStartDate
  {
    let rtt = responseStartDate.timeIntervalSince(requestEndDate)
    // Sanity check: should be positive and reasonable
    if rtt > 0 && rtt < 60.0 {
      networkRTT = rtt
    }
  }

  return (networkRTT, tcpHandshakeRTT)
}

// MARK: - No Redirect Delegate

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  var taskMetrics: URLSessionTaskMetrics?

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    // Prevent redirect by returning nil
    completionHandler(nil)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    // Capture metrics for network RTT calculation
    self.taskMetrics = metrics
  }
}

// MARK: - Metrics Delegate

private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  var taskMetrics: URLSessionTaskMetrics?

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didFinishCollecting metrics: URLSessionTaskMetrics
  ) {
    // Capture metrics for network RTT calculation
    self.taskMetrics = metrics
  }
}
