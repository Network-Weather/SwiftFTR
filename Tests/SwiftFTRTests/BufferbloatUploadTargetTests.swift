import Foundation
import Testing

@testable import SwiftFTR

/// Where the bufferbloat upload load goes, observed offline: a `URLProtocol` registered for the
/// shared session answers every request to the load hosts itself, so nothing leaves the machine,
/// and records what was asked for.
@Suite("Bufferbloat upload target", .serialized)
struct BufferbloatUploadTargetTests {
  /// The hosts the recorder answers for: the default upload target, the former one, and the one
  /// the custom-URL control uses.
  static let interceptedHosts: Set<String> = [
    "speed.cloudflare.com", "httpbin.org", "upload.example.test",
  ]

  struct Request: Sendable {
    let method: String?
    let url: URL?
    let bodyLength: Int
  }

  final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var requests: [Request] = []

    var isRecording: Bool { lock.withLock { recording } }
    var recorded: [Request] { lock.withLock { requests } }

    func start() { lock.withLock { (recording, requests) = (true, []) } }
    func stop() { lock.withLock { recording = false } }
    func record(_ request: Request) { lock.withLock { requests.append(request) } }
  }

  static let recorder = Recorder()

  final class InterceptingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
      guard BufferbloatUploadTargetTests.recorder.isRecording, let host = request.url?.host else {
        return false
      }
      return BufferbloatUploadTargetTests.interceptedHosts.contains(host)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
      var length = request.httpBody?.count ?? 0
      if let stream = request.httpBodyStream {
        stream.open()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
          let n = stream.read(&buffer, maxLength: buffer.count)
          if n <= 0 { break }
          length += n
        }
        stream.close()
      }
      BufferbloatUploadTargetTests.recorder.record(
        Request(method: request.httpMethod, url: request.url, bodyLength: length))
      if let url = request.url,
        let response = HTTPURLResponse(
          url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
      {
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      }
      client?.urlProtocol(self, didLoad: Data())
      client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
  }

  /// Runs the upload load for a moment with the recorder installed and returns what it sent.
  static func uploads(_ config: BufferbloatConfig) async -> [Request] {
    recorder.start()
    URLProtocol.registerClass(InterceptingProtocol.self)
    defer {
      URLProtocol.unregisterClass(InterceptingProtocol.self)
      recorder.stop()
    }
    await LoadGenerator(config: config).startLoad(duration: 0.3, type: .upload)
    return recorder.recorded
  }

  @Test("The default upload load posts to Cloudflare's speed-test upload endpoint")
  func defaultUploadTarget() async throws {
    let requests = await Self.uploads(BufferbloatConfig(loadType: .upload, parallelStreams: 1))
    try #require(!requests.isEmpty, "no upload request was made")
    let urls = Set(requests.map { $0.url?.absoluteString ?? "nil" })
    #expect(urls == ["https://speed.cloudflare.com/__up"], "\(requests.count) requests to \(urls)")
    #expect(Set(requests.map { $0.method ?? "nil" }) == ["POST"])
    #expect(Set(requests.map(\.bodyLength)) == [256 * 1024])
  }

  @Test("A caller's upload URL is used instead of the default")
  func customUploadTarget() async throws {
    let requests = await Self.uploads(
      BufferbloatConfig(
        loadType: .upload, parallelStreams: 1, uploadURL: "https://upload.example.test/sink"))
    try #require(!requests.isEmpty, "no upload request was made")
    #expect(requests.allSatisfy { $0.url?.absoluteString == "https://upload.example.test/sink" })
  }
}
