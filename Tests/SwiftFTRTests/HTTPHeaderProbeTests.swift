import Darwin
import Foundation
import Testing

@testable import SwiftFTR

@Suite("HTTP Header Probe Tests", .serialized)
struct HTTPHeaderProbeTests {
  @Test("Stops loading a large, slow body after receiving headers")
  func stopsLoadingBodyAfterHeaders() async throws {
    await HTTPProbeProtocolRecorder.shared.reset()

    let startedAt = Date()
    let result = try await httpProbe(
      config: HTTPProbeConfig(url: "http://probe.test/large-body", timeout: 5),
      sessionConfiguration: testSessionConfiguration())

    await HTTPProbeProtocolRecorder.shared.waitUntilStopped()
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
    await noRedirectServer.waitUntilFinished()

    #expect(noRedirectResult.statusCode == 302)
    #expect(noRedirectServer.requestPaths == ["/redirect"])

    let redirectServer = try LocalHTTPServer(expectedRequestCount: 2)

    let redirectResult = try await httpProbe(
      config: HTTPProbeConfig(
        url: redirectServer.redirectURL.absoluteString,
        timeout: 2,
        followRedirects: true))
    redirectServer.stop()
    await redirectServer.waitUntilFinished()

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

    for config in configurations {
      await HTTPProbeProtocolRecorder.shared.reset()
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
    await HTTPProbeProtocolRecorder.shared.reset()

    let probe = Task {
      try await httpProbe(
        config: HTTPProbeConfig(url: "http://probe.test/never", timeout: 30),
        sessionConfiguration: testSessionConfiguration())
    }
    await HTTPProbeProtocolRecorder.shared.waitUntilStarted()

    let cancelledAt = Date()
    probe.cancel()
    let result = try await probe.value
    let cancellationDuration = Date().timeIntervalSince(cancelledAt)

    await HTTPProbeProtocolRecorder.shared.waitUntilStopped()
    let snapshot = await HTTPProbeProtocolRecorder.shared.snapshot()

    #expect(cancellationDuration < 1)
    #expect(!result.isReachable)
    #expect(result.error == "Cancelled")
    #expect(snapshot.stoppedCount == 1)
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

  private var startedCount = 0
  private var stoppedCount = 0
  private var bodyBytesDelivered = 0
  private var requestPaths: [String] = []
  private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  private var stopWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func reset() {
    precondition(startWaiters.isEmpty && stopWaiters.isEmpty)
    startedCount = 0
    stoppedCount = 0
    bodyBytesDelivered = 0
    requestPaths = []
  }

  func recordStarted(path: String) {
    startedCount += 1
    requestPaths.append(path)
    resumeReadyStartWaiters()
  }

  func recordStopped() {
    stoppedCount += 1
    resumeReadyStopWaiters()
  }

  func recordBodyBytes(_ count: Int) {
    bodyBytesDelivered += count
  }

  func waitUntilStarted(count: Int = 1) async {
    guard startedCount < count else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append((count, continuation))
    }
  }

  func waitUntilStopped(count: Int = 1) async {
    guard stoppedCount < count else { return }
    await withCheckedContinuation { continuation in
      stopWaiters.append((count, continuation))
    }
  }

  func snapshot() -> Snapshot {
    Snapshot(
      startedCount: startedCount,
      stoppedCount: stoppedCount,
      bodyBytesDelivered: bodyBytesDelivered,
      requestPaths: requestPaths)
  }

  private func resumeReadyStartWaiters() {
    let ready = startWaiters.filter { startedCount >= $0.count }
    startWaiters.removeAll { startedCount >= $0.count }
    for waiter in ready {
      waiter.continuation.resume()
    }
  }

  private func resumeReadyStopWaiters() {
    let ready = stopWaiters.filter { stoppedCount >= $0.count }
    stopWaiters.removeAll { stoppedCount >= $0.count }
    for waiter in ready {
      waiter.continuation.resume()
    }
  }
}

private final class HTTPProbeURLProtocol: URLProtocol, @unchecked Sendable {
  static let bodyChunkSize = 32 * 1_024
  static let bodyChunkCount = 128
  static let totalBodyBytes = bodyChunkSize * bodyChunkCount

  private let lock = NSLock()
  private var loadingTask: Task<Void, Never>?

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
      await HTTPProbeProtocolRecorder.shared.recordStarted(path: url.path)

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
    Task {
      await loadingTask?.value
      await HTTPProbeProtocolRecorder.shared.recordStopped()
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
      await HTTPProbeProtocolRecorder.shared.recordBodyBytes(chunk.count)
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
  private var finishWaiters: [CheckedContinuation<Void, Never>] = []

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

  func waitUntilFinished() async {
    await withCheckedContinuation { continuation in
      lock.lock()
      let shouldResume = isFinished
      if !shouldResume {
        finishWaiters.append(continuation)
      }
      lock.unlock()

      if shouldResume {
        continuation.resume()
      }
    }
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
    let waiters = finishWaiters
    finishWaiters.removeAll()
    lock.unlock()

    for waiter in waiters {
      waiter.resume()
    }
  }
}

private enum LocalHTTPServerError: Error {
  case systemCall(String, Int32)
}
