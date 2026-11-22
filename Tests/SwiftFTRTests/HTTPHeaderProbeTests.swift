import Darwin
import Foundation
import Testing

@testable import SwiftFTR

@Suite("HTTP Header Probe Tests", .serialized)
struct HTTPHeaderProbeTests {
  @Test("Stops loading a large, slow body after receiving headers")
  func stopsLoadingBodyAfterHeaders() async throws {
    let generation = await HTTPProbeProtocolRecorder.shared.reset()

    let startedAt = Date()
    let result = try await httpProbe(
      config: HTTPProbeConfig(url: probeURL("/large-body", generation: generation), timeout: 5),
      sessionConfiguration: testSessionConfiguration())

    try await HTTPProbeProtocolRecorder.shared.waitUntilStopped()
    let snapshot = await HTTPProbeProtocolRecorder.shared.snapshot()

    #expect(result.isReachable)
    #expect(result.statusCode == 200)
    #expect(Date().timeIntervalSince(startedAt) < 1)
    #expect(snapshot.bodyBytesDelivered < HTTPProbeURLProtocol.totalBodyBytes)
    #expect(snapshot.stoppedCount == 1)
  }

  @Test("Honors redirect configuration")
  func honorsRedirectConfiguration() async throws {
    let noRedirectServer = try LocalHTTPServer(expectedRequestCount: 1)

    let noRedirectResult = try await httpProbe(
      config: HTTPProbeConfig(
        url: noRedirectServer.redirectURL.absoluteString,
        timeout: 2,
        followRedirects: false))
    noRedirectServer.stop()
    try await noRedirectServer.waitUntilFinished()

    #expect(noRedirectResult.statusCode == 302)
    #expect(noRedirectServer.requestPaths == ["/redirect"])

    let redirectServer = try LocalHTTPServer(expectedRequestCount: 2)

    let redirectResult = try await httpProbe(
      config: HTTPProbeConfig(
        url: redirectServer.redirectURL.absoluteString,
        timeout: 2,
        followRedirects: true))
    redirectServer.stop()
    try await redirectServer.waitUntilFinished()

    #expect(redirectResult.statusCode == 204)
    #expect(redirectServer.requestPaths == ["/redirect", "/final"])
  }

  @Test("Rejects invalid URLs and timeouts without starting URL loading")
  func rejectsInvalidConfigurationWithoutLoading() async throws {
    let configurations = [
      HTTPProbeConfig(url: "not a valid url", timeout: 1),
      HTTPProbeConfig(url: "file:///tmp/example", timeout: 1),
      HTTPProbeConfig(url: "ftp://probe.test/example", timeout: 1),
      HTTPProbeConfig(url: "http:///missing-host", timeout: 1),
      HTTPProbeConfig(url: "http://probe.test/never", timeout: 0),
      HTTPProbeConfig(url: "http://probe.test/never", timeout: -1),
      HTTPProbeConfig(url: "http://probe.test/never", timeout: .infinity),
      HTTPProbeConfig(url: "http://probe.test/never", timeout: .nan),
    ]

    for template in configurations {
      let generation = await HTTPProbeProtocolRecorder.shared.reset()
      let config = HTTPProbeConfig(
        url: template.url.contains("probe.test")
          ? "\(template.url)?generation=\(generation)" : template.url,
        timeout: template.timeout)
      let result = try await httpProbe(
        config: config,
        sessionConfiguration: testSessionConfiguration())
      let snapshot = await HTTPProbeProtocolRecorder.shared.snapshot()

      #expect(!result.isReachable)
      #expect(result.error != nil)
      #expect(snapshot.startedCount == 0)
    }
  }

  @Test("Caller cancellation promptly stops URL loading")
  func cancellationStopsLoading() async throws {
    let generation = await HTTPProbeProtocolRecorder.shared.reset()

    let probe = Task {
      try await httpProbe(
        config: HTTPProbeConfig(url: probeURL("/never", generation: generation), timeout: 30),
        sessionConfiguration: testSessionConfiguration())
    }
    try await HTTPProbeProtocolRecorder.shared.waitUntilStarted()

    let cancelledAt = Date()
    probe.cancel()
    let result = try await probe.value
    let cancellationDuration = Date().timeIntervalSince(cancelledAt)

    try await HTTPProbeProtocolRecorder.shared.waitUntilStopped()
    let snapshot = await HTTPProbeProtocolRecorder.shared.snapshot()

    #expect(cancellationDuration < 1)
    #expect(!result.isReachable)
    #expect(result.error == "Cancelled")
    #expect(snapshot.stoppedCount == 1)
  }

  @Test("A request from an earlier generation does not change a later test's counts")
  func staleRequestDoesNotCount() async throws {
    // A request made for one test that starts only after the next test has reset the recorder,
    // as a request left over from a test that gave up would.
    let stale = await HTTPProbeProtocolRecorder.shared.reset()
    _ = await HTTPProbeProtocolRecorder.shared.reset()

    let result = try await httpProbe(
      config: HTTPProbeConfig(url: probeURL("/large-body", generation: stale), timeout: 5),
      sessionConfiguration: testSessionConfiguration())
    #expect(result.isReachable)

    // Its start and its stop both arrive, and neither is counted.
    let bothArrived = await eventually(within: 10) {
      await HTTPProbeProtocolRecorder.shared.staleEventCount >= 2
    }
    #expect(bothArrived, "the stale request's start and stop never arrived")
    let snapshot = await HTTPProbeProtocolRecorder.shared.snapshot()
    #expect(snapshot.startedCount == 0)
    #expect(snapshot.stoppedCount == 0)
    #expect(snapshot.bodyBytesDelivered == 0)
  }

  /// A URL the test protocol serves, carrying the recorder generation its events belong to.
  private func probeURL(_ path: String, generation: Int) -> String {
    "http://probe.test\(path)?generation=\(generation)"
  }

  private func testSessionConfiguration() -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HTTPProbeURLProtocol.self]
    return configuration
  }
}

private actor HTTPProbeProtocolRecorder {
  struct Snapshot: Sendable {
    let startedCount: Int
    let stoppedCount: Int
    let bodyBytesDelivered: Int
    let requestPaths: [String]
  }

  static let shared = HTTPProbeProtocolRecorder()

  /// Advanced by every `reset()`. Each request carries the generation it was created for, and
  /// its events count only while that is the current one, so a request left over from an
  /// earlier test cannot change this test's counts.
  private var generation = 0
  /// Start, stop and body events that arrived for an earlier generation and were not counted.
  private(set) var staleEventCount = 0
  private var startedCount = 0
  private var stoppedCount = 0
  private var bodyBytesDelivered = 0
  private var requestPaths: [String] = []

  /// Starts a new generation for the calling test and returns it.
  @discardableResult
  func reset() -> Int {
    generation += 1
    defer { staleEventCount = 0 }
    startedCount = 0
    stoppedCount = 0
    bodyBytesDelivered = 0
    requestPaths = []
    return generation
  }

  /// Whether an event for `eventGeneration` counts; one that does not is tallied as stale.
  private func isCurrent(_ eventGeneration: Int) -> Bool {
    guard eventGeneration == generation else {
      staleEventCount += 1
      return false
    }
    return true
  }

  func recordStarted(path: String, generation: Int) {
    guard isCurrent(generation) else { return }
    startedCount += 1
    requestPaths.append(path)
  }

  func recordStopped(generation: Int) {
    guard isCurrent(generation) else { return }
    stoppedCount += 1
  }

  func recordBodyBytes(_ count: Int, generation: Int) {
    guard isCurrent(generation) else { return }
    bodyBytesDelivered += count
  }

  // The waits poll the counts rather than register a continuation, so one that gives up leaves
  // nothing behind in this shared recorder for a later test to trip over.

  /// Fails the test if `count` requests have not started within ten seconds.
  nonisolated func waitUntilStarted(count: Int = 1) async throws {
    let started = await eventually(within: 10) { await self.snapshot().startedCount >= count }
    try #require(started, "\(count) request(s) never started")
  }

  /// Fails the test if `count` requests have not stopped within ten seconds.
  nonisolated func waitUntilStopped(count: Int = 1) async throws {
    let stopped = await eventually(within: 10) { await self.snapshot().stoppedCount >= count }
    try #require(stopped, "\(count) request(s) never stopped")
  }

  func snapshot() -> Snapshot {
    Snapshot(
      startedCount: startedCount,
      stoppedCount: stoppedCount,
      bodyBytesDelivered: bodyBytesDelivered,
      requestPaths: requestPaths)
  }
}

private final class HTTPProbeURLProtocol: URLProtocol, @unchecked Sendable {
  static let bodyChunkSize = 32 * 1_024
  static let bodyChunkCount = 128
  static let totalBodyBytes = bodyChunkSize * bodyChunkCount

  private let lock = NSLock()
  private var loadingTask: Task<Void, Never>?
  /// The recorder generation the test created this request for, from its URL; -1 if it has none.
  private var requestGeneration: Int {
    request.url
      .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?
      .first { $0.name == "generation" }?.value
      .flatMap(Int.init) ?? -1
  }

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "probe.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    // URLProtocol permits asynchronous loading, but its Objective-C API does not express
    // Sendable. The box is safe because URLProtocol lifecycle state is protected by `lock`.
    let protocolBox = UncheckedSendableBox(self)
    let loadingTask = Task { [protocolBox] in
      let loader = protocolBox.value
      guard let url = loader.request.url else { return }
      await HTTPProbeProtocolRecorder.shared.recordStarted(
        path: url.path, generation: loader.requestGeneration)

      switch url.path {
      case "/large-body":
        await loader.loadLargeBody(for: url)
      case "/never":
        do {
          try await Task.sleep(for: .seconds(60))
        } catch {
          return
        }
      default:
        loader.client?.urlProtocol(
          loader,
          didFailWithError: URLError(.resourceUnavailable))
      }
    }

    lock.lock()
    self.loadingTask = loadingTask
    lock.unlock()
  }

  override func stopLoading() {
    lock.lock()
    let loadingTask = self.loadingTask
    self.loadingTask = nil
    lock.unlock()

    loadingTask?.cancel()
    let generation = requestGeneration
    Task {
      await loadingTask?.value
      await HTTPProbeProtocolRecorder.shared.recordStopped(generation: generation)
    }
  }

  private func loadLargeBody(for url: URL) async {
    guard
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Length": String(Self.totalBodyBytes)])
    else {
      return
    }

    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let chunk = Data(repeating: 0x41, count: Self.bodyChunkSize)
    for _ in 0..<Self.bodyChunkCount {
      do {
        try await Task.sleep(for: .milliseconds(10))
        try Task.checkCancellation()
      } catch {
        return
      }
      await HTTPProbeProtocolRecorder.shared.recordBodyBytes(
        chunk.count, generation: requestGeneration)
      client?.urlProtocol(self, didLoad: chunk)
    }
    client?.urlProtocolDidFinishLoading(self)
  }
}

private struct UncheckedSendableBox<Value>: @unchecked Sendable {
  let value: Value

  init(_ value: Value) {
    self.value = value
  }
}

private final class LocalHTTPServer: @unchecked Sendable {
  private let expectedRequestCount: Int
  private let port: UInt16
  private let lock = NSLock()
  private var listeningSocket: Int32?
  private var recordedRequestPaths: [String] = []
  private var isFinished = false

  var redirectURL: URL {
    URL(string: "http://127.0.0.1:\(port)/redirect")!
  }

  var requestPaths: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedRequestPaths
  }

  init(expectedRequestCount: Int) throws {
    self.expectedRequestCount = expectedRequestCount

    let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard socketDescriptor >= 0 else {
      throw LocalHTTPServerError.systemCall("socket", errno)
    }

    var reuseAddress: Int32 = 1
    guard
      setsockopt(
        socketDescriptor,
        SOL_SOCKET,
        SO_REUSEADDR,
        &reuseAddress,
        socklen_t(MemoryLayout.size(ofValue: reuseAddress))) == 0
    else {
      let code = errno
      close(socketDescriptor)
      throw LocalHTTPServerError.systemCall("setsockopt", code)
    }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(
          socketDescriptor,
          $0,
          socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      let code = errno
      close(socketDescriptor)
      throw LocalHTTPServerError.systemCall("bind", code)
    }

    guard listen(socketDescriptor, 4) == 0 else {
      let code = errno
      close(socketDescriptor)
      throw LocalHTTPServerError.systemCall("listen", code)
    }

    var boundAddress = sockaddr_in()
    var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(socketDescriptor, $0, &boundAddressLength)
      }
    }
    guard nameResult == 0 else {
      let code = errno
      close(socketDescriptor)
      throw LocalHTTPServerError.systemCall("getsockname", code)
    }

    self.port = UInt16(bigEndian: boundAddress.sin_port)
    self.listeningSocket = socketDescriptor

    let serverBox = UncheckedSendableBox(self)
    Thread.detachNewThread {
      serverBox.value.run(socketDescriptor: socketDescriptor)
    }
  }

  deinit {
    stop()
  }

  func stop() {
    lock.lock()
    let socketDescriptor = listeningSocket
    listeningSocket = nil
    lock.unlock()

    if let socketDescriptor {
      shutdown(socketDescriptor, SHUT_RDWR)
      close(socketDescriptor)
    }
  }

  /// Fails the test if the server has not served its requests within ten seconds. Polls rather
  /// than registering a waiter, so giving up holds nothing that keeps the server alive.
  func waitUntilFinished() async throws {
    let finished = await eventually(within: 10) { self.hasFinished }
    try #require(finished, "the server never finished serving its requests")
  }

  private var hasFinished: Bool {
    lock.lock()
    defer { lock.unlock() }
    return isFinished
  }

  private func run(socketDescriptor: Int32) {
    defer { finish() }

    for _ in 0..<expectedRequestCount {
      let clientSocket = accept(socketDescriptor, nil, nil)
      guard clientSocket >= 0 else { return }

      var noSignal: Int32 = 1
      _ = setsockopt(
        clientSocket,
        SOL_SOCKET,
        SO_NOSIGPIPE,
        &noSignal,
        socklen_t(MemoryLayout.size(ofValue: noSignal)))

      let path = readRequestPath(from: clientSocket)
      recordRequest(path: path)
      sendResponse(to: clientSocket, path: path)
      close(clientSocket)
    }
  }

  private func readRequestPath(from socketDescriptor: Int32) -> String {
    var request = Data()
    var buffer = [UInt8](repeating: 0, count: 2_048)

    while request.count < 32_768 {
      let bytesRead = recv(socketDescriptor, &buffer, buffer.count, 0)
      guard bytesRead > 0 else { break }
      request.append(buffer, count: bytesRead)
      if request.range(of: Data("\r\n\r\n".utf8)) != nil { break }
    }

    guard
      let requestText = String(data: request, encoding: .utf8),
      let requestLine = requestText.split(separator: "\r\n", maxSplits: 1).first,
      requestLine.split(separator: " ").count >= 2
    else {
      return "/"
    }
    return String(requestLine.split(separator: " ")[1])
  }

  private func sendResponse(to socketDescriptor: Int32, path: String) {
    let response: String
    if path == "/redirect" {
      response = """
        HTTP/1.1 302 Found\r
        Location: http://127.0.0.1:\(port)/final\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
    } else {
      response = """
        HTTP/1.1 204 No Content\r
        Content-Length: 0\r
        Connection: close\r
        \r

        """
    }

    let bytes = Array(response.utf8)
    bytes.withUnsafeBytes { buffer in
      guard let baseAddress = buffer.baseAddress else { return }
      _ = Darwin.send(socketDescriptor, baseAddress, buffer.count, 0)
    }
  }

  private func recordRequest(path: String) {
    lock.lock()
    recordedRequestPaths.append(path)
    lock.unlock()
  }

  private func finish() {
    stop()

    lock.lock()
    isFinished = true
    lock.unlock()
  }
}

private enum LocalHTTPServerError: Error {
  case systemCall(String, Int32)
}
