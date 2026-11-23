import Foundation
import Testing

@testable import SwiftFTR

/// Where the bufferbloat upload load goes, observed offline: a `URLProtocol` registered for the
/// shared session answers the test's own upload requests itself, so nothing leaves the machine,
/// and records what was asked for.
///
/// The shared session is process-wide. The recorder claims only POST requests, and lets every
/// other request (a download load's GETs included) through untouched. The upload load is the only
/// code that POSTs on the shared session: no other code in the library or the tests uses
/// `URLSession.shared` or registers a `URLProtocol`, and the HTTP probe builds its own sessions.
/// Claiming every POST rather than only the expected URL keeps a regression that posts elsewhere
/// offline too. The whole registration is held under ``NetworkTestGate``, which the live
/// bufferbloat tests also hold, so a live load never runs while the recorder is installed.
@Suite("Bufferbloat upload target", .serialized)
struct BufferbloatUploadTargetTests {
  static let watchdog: TimeInterval = 20

  /// A load duration past the watchdog: a load that ends inside it was ended by the test.
  static let loadDuration: TimeInterval = 60

  struct Request: Sendable {
    let method: String?
    let url: URL?
    let bodyLength: Int
  }

  final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recording = false
    private var requests: [Request] = []

    var recorded: [Request] { lock.withLock { requests } }

    /// Whether the recorder answers `request`: a POST, while a test is recording.
    func claims(_ request: URLRequest) -> Bool {
      lock.withLock { recording && request.httpMethod == "POST" }
    }

    func start() { lock.withLock { (recording, requests) = (true, []) } }
    func stop() { lock.withLock { recording = false } }
    func record(_ request: Request) { lock.withLock { requests.append(request) } }
  }

  static let recorder = Recorder()

  final class InterceptingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool {
      BufferbloatUploadTargetTests.recorder.claims(request)
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

  /// Runs the upload load until the recorder has seen a request, then cancels it, and returns
  /// what was recorded. A load that never posts records nothing and is cancelled at the watchdog.
  static func uploads(_ config: BufferbloatConfig) async throws -> [Request] {
    try await NetworkTestGate.shared.withPermit {
      recorder.start()
      URLProtocol.registerClass(InterceptingProtocol.self)
      defer {
        URLProtocol.unregisterClass(InterceptingProtocol.self)
        recorder.stop()
      }
      let load = Task {
        await LoadGenerator(config: config).startLoad(duration: loadDuration, type: .upload)
      }
      defer { load.cancel() }
      _ = await eventually(within: watchdog) { !recorder.recorded.isEmpty }
      load.cancel()
      // The load ends on cancellation, well before its own duration.
      _ = try await measure(within: watchdog) { await load.value }
      return recorder.recorded
    }
  }

  @Test("The default upload load posts to Cloudflare's speed-test upload endpoint")
  func defaultUploadTarget() async throws {
    let requests = try await Self.uploads(BufferbloatConfig(loadType: .upload, parallelStreams: 1))
    try #require(!requests.isEmpty, "no upload request was made")
    let urls = Set(requests.map { $0.url?.absoluteString ?? "nil" })
    #expect(urls == ["https://speed.cloudflare.com/__up"], "\(requests.count) requests to \(urls)")
    #expect(Set(requests.map { $0.method ?? "nil" }) == ["POST"])
    #expect(Set(requests.map(\.bodyLength)) == [256 * 1024])
  }

  @Test("A caller's upload URL is used instead of the default")
  func customUploadTarget() async throws {
    let requests = try await Self.uploads(
      BufferbloatConfig(
        loadType: .upload, parallelStreams: 1, uploadURL: "https://upload.example.test/sink"))
    try #require(!requests.isEmpty, "no upload request was made")
    #expect(requests.allSatisfy { $0.url?.absoluteString == "https://upload.example.test/sink" })
  }
}
