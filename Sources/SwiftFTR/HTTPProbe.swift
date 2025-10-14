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
  public let rtt: TimeInterval?

  /// Error message (if any)
  public let error: String?

  /// Timestamp
  public let timestamp: Date

  public init(
    url: String,
    isReachable: Bool,
    statusCode: Int?,
    rtt: TimeInterval?,
    error: String?,
    timestamp: Date = Date()
  ) {
    self.url = url
    self.statusCode = statusCode
    self.isReachable = isReachable
    self.rtt = rtt
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
    // Use custom delegate to prevent redirects
    let delegate = NoRedirectDelegate()
    let session = URLSession(configuration: sessionConfig, delegate: delegate, delegateQueue: nil)
    return await performProbe(url: url, session: session, startTime: startTime, config: config)
  } else {
    let session = URLSession(configuration: sessionConfig)
    return await performProbe(url: url, session: session, startTime: startTime, config: config)
  }
}

private func performProbe(
  url: URL,
  session: URLSession,
  startTime: Date,
  config: HTTPProbeConfig
) async -> HTTPProbeResult {
  do {
    let (_, response) = try await session.data(from: url)

    let rtt = Date().timeIntervalSince(startTime)

    if let httpResponse = response as? HTTPURLResponse {
      // Any HTTP response (even 4xx/5xx) means server is reachable
      return HTTPProbeResult(
        url: config.url,
        isReachable: true,
        statusCode: httpResponse.statusCode,
        rtt: rtt,
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

// MARK: - No Redirect Delegate

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
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
}
