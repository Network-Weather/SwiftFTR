import Foundation
import Testing

@testable import SwiftFTR

/// Team Cymru lookups run on the event-based DNS transport: they need no blocking-I/O worker, and
/// the cap on concurrent queries is waited for without a thread and gives up on cancellation.
@Suite
struct CymruEventBasedTests {
  static let watchdog: TimeInterval = 20

  @Test("With every blocking-I/O worker held, a Cymru lookup still resolves")
  func resolvesWithEveryWorkerHeld() async throws {
    let server = try LoopbackUDPResponder(accepts: CymruFixture.query) { query in
      CymruFixture.answer(query)
    }
    defer { server.stop() }
    let held = await HeldExecutor.fill()
    defer { held.release() }

    let (result, _) = try await measure(within: Self.watchdog) {
      try await TestSeams.$blockingIOExecutor.withValue(held.executor) {
        try await TestSeams.$dnsServerPort.withValue(server.port) {
          try await CymruDNSResolver(servers: ["127.0.0.1"])
            .resolve(ipv4Addrs: ["8.8.8.8"], timeout: 5)
        }
      }
    }

    // Resolved while every worker was still held, so no lookup waited for one.
    #expect(held.finished.value == 0)
    let info = try #require(result["8.8.8.8"])
    #expect(info.asn == 15169)
    #expect(info.name == "GOOGLE, US")
    #expect(info.prefix == "8.8.8.0/24")
    // One origin query and one AS-name query.
    #expect(server.requests.value == 2)
  }

  @Test("A query waiting for a free slot gives up when its task is cancelled")
  func semaphoreWaitIsCancellable() async throws {
    let semaphore = _ConcurrencySemaphore(maxConcurrent: 1)
    try await semaphore.wait()
    let waiter = Task { try await semaphore.wait() }
    // Let the waiter reach the semaphore before cancelling it; either order must end the wait.
    try await Task.sleep(nanoseconds: 50_000_000)
    waiter.cancel()

    // The only permit is still taken, so a waiter that returned was released by cancellation.
    let (thrown, _) = try await measure(within: Self.watchdog) {
      await EventBasedDNSTests.error { try await waiter.value }
    }
    #expect(thrown is CancellationError, "\(String(describing: thrown))")

    // A task cancelled before it waits is refused too.
    let early = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await semaphore.wait()
    }
    let (refused, _) = try await measure(within: Self.watchdog) {
      await EventBasedDNSTests.error { try await early.value }
    }
    #expect(refused is CancellationError, "\(String(describing: refused))")

    // The cancelled waiters took no permit: the one held is handed to the next waiter.
    let next = Task { try await semaphore.wait() }
    await semaphore.signal()
    _ = try await measure(within: Self.watchdog) { try await next.value }
  }

  @Test("Every query of a lookup ends by its deadline; a silent server leaves time for the next")
  func queriesShareTheLookupsDeadline() async throws {
    let recorder = TXTQueryRecorder()
    let resolver = CymruDNSResolver(servers: ["192.0.2.1", "192.0.2.2"]) { name, server, deadline in
      await recorder.silent(name: name, server: server, until: deadline)
    }
    // More addresses than queries run at once, so a second wave starts when the first times out.
    let addresses = (1...12).map { "198.51.100.\($0)" }
    let deadline = ContinuousClock.now + .milliseconds(600)

    let (result, _) = try await measure(within: Self.watchdog) {
      await resolver.resolve(ipv4Addrs: addresses, until: deadline)
    }

    #expect(result.isEmpty)
    let attempts = await recorder.attempts
    #expect(!attempts.isEmpty)
    let late = attempts.filter { $0.deadline > deadline }
    #expect(late.isEmpty, "\(late.count) of \(attempts.count) queries outlived the lookup")
    // A silent first server does not use up the time: the second is asked too.
    let fallbacks = Set(attempts.filter { $0.server == "192.0.2.2" }.map(\.name))
    #expect(!fallbacks.isEmpty, "no query fell back to the second server")
  }
}

/// Team Cymru's two TXT answers for 8.8.8.8, served from a loopback responder.
enum CymruFixture {
  static let origin = "15169 | 8.8.8.0/24 | US | arin | 2023-12-28"
  static let asName = "15169 | US | arin | 2000-03-30 | GOOGLE, US"

  /// A query for one of the two names ``answer(_:)`` knows, the only datagrams a Cymru fixture
  /// answers or counts.
  static let query = DatagramFilter { datagram in
    DatagramFilter.dnsQuery().accepts(datagram) && answer(datagram) != nil
  }

  static func answer(_ query: [UInt8]) -> (reply: [UInt8], delay: TimeInterval)? {
    let text: String
    switch queryName(query)?.lowercased() {
    case "8.8.8.8.origin.asn.cymru.com": text = origin
    case "as15169.asn.cymru.com": text = asName
    default: return nil
    }
    let bytes = Array(text.utf8)
    let rdata = [UInt8(bytes.count)] + bytes
    let record: [UInt8] =
      [0xC0, 0x0C, 0, 16, 0, 1, 0, 0, 0, 60, UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)]
      + rdata
    return (FaultInjectionWireTests.dnsResponse(to: query, answers: record), 0)
  }

  /// The question name of a DNS query, as dotted labels.
  static func queryName(_ query: [UInt8]) -> String? {
    var labels: [String] = []
    var offset = 12
    while offset < query.count {
      let length = Int(query[offset])
      offset += 1
      if length == 0 { return labels.joined(separator: ".") }
      guard offset + length <= query.count else { return nil }
      labels.append(String(decoding: query[offset..<(offset + length)], as: UTF8.self))
      offset += length
    }
    return nil
  }
}

/// Records each Team Cymru query a resolver makes and answers none of them, waiting out each
/// query's own deadline as a silent server would.
actor TXTQueryRecorder {
  struct Attempt {
    let name: String
    let server: String
    let deadline: ContinuousClock.Instant
  }

  private(set) var attempts: [Attempt] = []

  func silent(name: String, server: String, until deadline: ContinuousClock.Instant) async
    -> [String]?
  {
    attempts.append(Attempt(name: name, server: server, deadline: deadline))
    try? await Task.sleep(until: deadline, clock: .continuous)
    return nil
  }
}
