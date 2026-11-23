import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// A caller's public-IP resolver whose answer each test scripts, recording every request.
final class ScriptedPublicIPResolver: PublicIPResolver, @unchecked Sendable {
  enum Behavior: Sendable {
    /// Answers at once.
    case answer(PublicIPObservation?)
    /// Throws at once.
    case fail
    /// Suspends until its task is cancelled, then throws.
    case never
    /// Waits for `gate` whatever happens to its task, then answers.
    case ignoringCancellation(StallGate, PublicIPObservation)
  }

  struct Failure: Error {}

  let behavior: Behavior
  /// Called on every request, before the resolver answers.
  let onAsk: @Sendable () -> Void
  let asked = FaultCounter()
  let returned = FaultCounter()
  let cancelled = FaultCounter()
  private let lock = NSLock()
  private var recorded: [PublicIPRequest] = []

  init(_ behavior: Behavior, onAsk: @escaping @Sendable () -> Void = {}) {
    self.behavior = behavior
    self.onAsk = onAsk
  }

  var requests: [PublicIPRequest] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  private func record(_ request: PublicIPRequest) {
    lock.lock()
    recorded.append(request)
    lock.unlock()
  }

  func publicIP(for request: PublicIPRequest) async throws -> PublicIPObservation? {
    record(request)
    onAsk()
    asked.increment()
    defer { returned.increment() }
    switch behavior {
    case .answer(let observation):
      return observation
    case .fail:
      throw Failure()
    case .never:
      do {
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
      } catch {
        cancelled.increment()
        throw error
      }
      return nil
    case .ignoringCancellation(let gate, let observation):
      await gate.waitAsync(limit: 60)
      return observation
    }
  }
}

/// The public-IP seam of classified traces: the strategy, the per-family cache and its precedence,
/// the deadline the tracer holds a caller's resolver to, and the checks on every answer.
///
/// Every trace runs against ``FakeICMPNetwork`` on loopback, with the library's discovery
/// substituted by one that fails at once, so nothing leaves the host. No test bounds from above how
/// long a call took: each runs under ``watchdog``, and every timeout that could end it on the wrong
/// path is set well past it.
@Suite("Public-IP resolver seam")
struct PublicIPResolverTests {
  static let watchdog: TimeInterval = 20
  static let hostApp = PublicIPObservationSource(rawValue: "host-app")

  static func observation(_ address: String, _ family: IPAddressFamily = .v4)
    -> PublicIPObservation
  {
    PublicIPObservation(address: address, family: family, source: hostApp)
  }

  static func tracer(
    _ resolver: PublicIPResolverStrategy, budget: TimeInterval = 3 * watchdog,
    publicIP: String? = nil, sourceIP: String? = nil
  ) -> SwiftFTR {
    offlineTracer(
      SwiftFTRConfig(
        maxHops: 4, maxWaitMs: 2000, publicIP: publicIP, noReverseDNS: true,
        publicIPDiscoveryTimeout: budget, sourceIP: sourceIP, publicIPResolver: resolver))
  }

  /// One classified trace through `network`, under the watchdog.
  static func classify(_ tracer: SwiftFTR, on network: FakeICMPNetwork) async throws
    -> ClassifiedTrace
  {
    try await network.install {
      try await measure(within: Self.watchdog) {
        try await tracer.traceClassified(to: "fake.test", resolver: EmptyASNResolver())
      }.0
    }
  }

  // MARK: Configuration

  static func isLibrary(_ strategy: PublicIPResolverStrategy) -> Bool {
    if case .library = strategy { return true }
    return false
  }

  @Test(
    "Existing SwiftFTRConfig calls keep their meaning, and the strategy defaults to the library")
  func configInitializerSelection() {
    // The initializer published before the strategy, used as a function value with its type
    // stated: it must still resolve, and to the library's resolver.
    let legacy:
      (
        Int, Int, Int, String?, Bool, Bool, TimeInterval?, Int?, TimeInterval?, TimeInterval?,
        String?, String?, ASNResolverStrategy, PreferredFamily
      ) -> SwiftFTRConfig = SwiftFTRConfig.init
    let viaLegacy = legacy(
      40, 1000, 56, nil, false, false, nil, nil, nil, nil, nil, nil, .dns, .auto)
    #expect(Self.isLibrary(viaLegacy.publicIPResolver))
    #expect(Self.isLibrary(SwiftFTRConfig().publicIPResolver))
    #expect(Self.isLibrary(SwiftFTRConfig(maxHops: 3, noReverseDNS: true).publicIPResolver))
    let disabled = SwiftFTRConfig(maxHops: 3, publicIPResolver: .disabled)
    #expect(!Self.isLibrary(disabled.publicIPResolver))
    #expect(disabled.maxHops == 3)
  }

  // MARK: Asking

  @Test("A caller's resolver is asked once, after the probes, and its answer classifies the trace")
  func askedOnceAfterProbes() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let repliesAtAsk = TimeStamp()
    let resolver = ScriptedPublicIPResolver(.answer(Self.observation("9.9.9.9"))) {
      repliesAtAsk.set(TimeInterval(network.repliesSent.value))
    }
    let tracer = Self.tracer(.custom(resolver), sourceIP: "127.0.0.1")

    let first = try await Self.classify(tracer, on: network)
    let second = try await Self.classify(tracer, on: network)

    #expect(resolver.asked.value == 1, "the cached answer should serve the second trace")
    let replies = try #require(repliesAtAsk.value)
    #expect(replies >= 2, "asked before the probes were answered")
    for trace in [first, second] {
      #expect(trace.publicIP == "9.9.9.9")
      #expect(trace.publicIPSource == Self.hostApp)
    }
    let request = try #require(resolver.requests.first)
    #expect(request.family == .v4)
    #expect(request.interface == nil)
    #expect(request.sourceIP == "127.0.0.1")
    // The deadline is the configured budget from when the question was built.
    let budgetLeft = secondsUntil(request.deadline)
    #expect(budgetLeft > 0)
    #expect(budgetLeft <= 3 * Self.watchdog)
    #expect(await tracer.publicIP(for: .v4) == Self.observation("9.9.9.9"))
  }

  @Test("An IPv6 trace asks for IPv6, and an IPv4 seed does not answer it")
  func ipv6TraceAsksForIPv6() async throws {
    let network = try FakeICMPNetwork(
      family: AF_INET6, script: pathScript(family: AF_INET6, destinationTTL: 2))
    defer { network.stop() }
    let resolver = ScriptedPublicIPResolver(
      .answer(Self.observation("2606:4700:4700:0::1111", .v6)))
    let tracer = Self.tracer(.custom(resolver))
    #expect(await tracer.seedPublicIP("8.8.8.8", source: .gatewayReported))

    let trace = try await Self.classify(tracer, on: network)

    #expect(resolver.requests.map(\.family) == [.v6])
    #expect(trace.publicIP == "2606:4700:4700::1111", "the answer is reported in canonical form")
    #expect(trace.publicIPSource == Self.hostApp)
    #expect(await tracer.publicIP(for: .v4)?.address == "8.8.8.8")
  }

  @Test("An IPv6 seed does not label an IPv4 trace")
  func ipv6SeedThenIPv4Trace() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let resolver = ScriptedPublicIPResolver(.answer(Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver))
    #expect(await tracer.seedPublicIP("2606:4700::1111", source: .gatewayReported))

    let trace = try await Self.classify(tracer, on: network)

    #expect(resolver.requests.map(\.family) == [.v4])
    #expect(trace.publicIP == "9.9.9.9")
    #expect(await tracer.publicIP(for: .v6)?.source == .gatewayReported)
  }

  @Test("A seed of the trace's family answers it without asking, and names its source")
  func seedAnswersWithoutAsking() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let resolver = ScriptedPublicIPResolver(.answer(Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver))
    #expect(await tracer.seedPublicIP("8.8.8.8", source: .gatewayReported))

    let trace = try await Self.classify(tracer, on: network)

    #expect(resolver.asked.value == 0)
    #expect(trace.publicIP == "8.8.8.8")
    #expect(trace.publicIPSource == .gatewayReported)
  }

  @Test("A configured address answers only traces of its family, and only if it is public")
  func configuredAddressPrecedence() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    for (configured, expectAsked) in [
      ("9.9.9.9", false), ("2606:4700::1111", true), ("10.0.0.1", true),
    ] {
      let resolver = ScriptedPublicIPResolver(.answer(Self.observation("8.8.8.8")))
      let tracer = Self.tracer(.custom(resolver), publicIP: configured)
      let trace = try await Self.classify(tracer, on: network)
      #expect(resolver.asked.value == (expectAsked ? 1 : 0), "configured \(configured)")
      #expect(trace.publicIP == (expectAsked ? "8.8.8.8" : configured), "configured \(configured)")
      let source = expectAsked ? Self.hostApp : PublicIPObservationSource.configured
      #expect(trace.publicIPSource == source, "configured \(configured)")
    }
  }

  @Test("With the strategy disabled nothing is asked and the trace classifies without an address")
  func disabledStrategy() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let discovery = OfflinePublicIPDiscovery()
    let tracer = Self.tracer(.disabled)

    let trace = try await discovery.install { try await Self.classify(tracer, on: network) }

    #expect(discovery.calls.value == 0, "the library's discovery ran")
    #expect(trace.publicIP == nil)
    #expect(trace.publicIPSource == nil)
    #expect(trace.hops.count == 2)
  }

  @Test("Invalidation and a network change make the next trace ask again")
  func invalidationAsksAgain() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let resolver = ScriptedPublicIPResolver(.answer(Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver))

    _ = try await Self.classify(tracer, on: network)
    _ = try await Self.classify(tracer, on: network)
    #expect(resolver.asked.value == 1)
    await tracer.invalidatePublicIP()
    _ = try await Self.classify(tracer, on: network)
    #expect(resolver.asked.value == 2)
    await tracer.networkChanged()
    #expect(await tracer.publicIP(for: .v4) == nil)
    _ = try await Self.classify(tracer, on: network)
    #expect(resolver.asked.value == 3)
    await tracer.clearCaches()
    _ = try await Self.classify(tracer, on: network)
    #expect(resolver.asked.value == 4)
  }

  // MARK: Answers that are refused

  struct RefusedAnswer: CustomTestStringConvertible, Sendable {
    let address: String
    let family: IPAddressFamily
    let why: String
    var testDescription: String { why }
  }

  static let refusedAnswers: [RefusedAnswer] = [
    .init(address: "192.168.1.1", family: .v4, why: "private"),
    .init(address: "100.64.0.1", family: .v4, why: "CGNAT"),
    .init(address: "127.0.0.1", family: .v4, why: "loopback"),
    .init(address: "169.254.1.1", family: .v4, why: "link-local"),
    .init(address: "198.51.100.1", family: .v4, why: "documentation"),
    .init(address: "2606:4700::1111", family: .v6, why: "other family"),
    .init(address: "2606:4700::1111", family: .v4, why: "IPv6 address labelled IPv4"),
    .init(address: "8.8.8.8", family: .v6, why: "IPv4 address labelled IPv6"),
    .init(address: "not-an-ip", family: .v4, why: "malformed"),
    .init(address: "8.8.8.8\u{0}", family: .v4, why: "embedded NUL"),
  ]

  @Test(
    "An answer that is not a public address of the family asked for is refused",
    arguments: refusedAnswers)
  func refusedAnswer(answer: RefusedAnswer) async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let resolver = ScriptedPublicIPResolver(
      .answer(
        PublicIPObservation(address: answer.address, family: answer.family, source: Self.hostApp)))
    let tracer = Self.tracer(.custom(resolver))

    let trace = try await Self.classify(tracer, on: network)

    #expect(resolver.asked.value == 1)
    #expect(trace.publicIP == nil)
    #expect(trace.publicIPSource == nil)
    #expect(await tracer.publicIP(for: .v4) == nil)
    #expect(await tracer.publicIP(for: .v6) == nil)
  }

  @Test("A resolver that throws costs the trace its public address, not its result")
  func throwingResolver() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let resolver = ScriptedPublicIPResolver(.fail)
    let tracer = Self.tracer(.custom(resolver))

    let trace = try await Self.classify(tracer, on: network)

    #expect(resolver.asked.value == 1)
    #expect(trace.publicIP == nil)
    #expect(trace.hops.count == 2)
  }

  // MARK: The deadline

  @Test("A resolver that never returns is abandoned at the deadline and cancelled")
  func neverReturns() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let resolver = ScriptedPublicIPResolver(.never)
    // The resolver never answers, so only the 0.3 s budget can end the question in time.
    let tracer = Self.tracer(.custom(resolver), budget: 0.3)

    let trace = try await Self.classify(tracer, on: network)

    #expect(resolver.asked.value == 1)
    #expect(trace.publicIP == nil)
    #expect(trace.hops.count == 2)
    let cancelled = await eventually(within: Self.watchdog) { resolver.cancelled.value == 1 }
    #expect(cancelled, "the abandoned resolver's task was not cancelled")
  }

  @Test("A resolver that ignores cancellation and answers late is neither used nor cached")
  func lateAnswerDropped() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let resolver = ScriptedPublicIPResolver(
      .ignoringCancellation(gate, Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver), budget: 0.3)

    let trace = try await Self.classify(tracer, on: network)
    let stillWaiting = resolver.returned.value == 0
    #expect(stillWaiting, "the trace returned only once the resolver had answered")
    #expect(trace.publicIP == nil)

    gate.open()
    let answered = await eventually(within: Self.watchdog) { resolver.returned.value == 1 }
    #expect(answered)
    #expect(await tracer.publicIP(for: .v4) == nil, "the late answer was cached")
  }

  /// Who ends a classified trace while its question is outstanding.
  enum Canceller: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case taskCancel, cancelActiveTraces, networkChanged
    var testDescription: String { rawValue }
  }

  @Test(
    "Cancelling a trace during its question ends it at once, reporting who cancelled it",
    arguments: Canceller.allCases)
  func cancelledDuringQuestion(canceller: Canceller) async throws {
    let gate = StallGate()
    defer { gate.open() }
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    // It ignores cancellation, and the budget outlives the watchdog, so only the cancellation can
    // end the trace in time.
    let resolver = ScriptedPublicIPResolver(
      .ignoringCancellation(gate, Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver))

    let outcome = try await network.install {
      let task = Task {
        try await tracer.traceClassified(to: "fake.test", resolver: EmptyASNResolver())
      }
      let asked = await eventually(within: Self.watchdog) { resolver.asked.value > 0 }
      #expect(asked, "the trace never asked its question")
      switch canceller {
      case .taskCancel: task.cancel()
      case .cancelActiveTraces: await tracer.cancelActiveTraces()
      case .networkChanged: await tracer.networkChanged()
      }
      return try await measure(within: Self.watchdog) { await task.result }.0
    }
    let stillWaiting = resolver.returned.value == 0
    #expect(stillWaiting, "the trace ended only once the resolver had answered")
    switch (canceller, outcome) {
    case (.taskCancel, .failure(let error)):
      #expect(error is CancellationError, "\(error)")
    case (.cancelActiveTraces, .failure(TracerouteError.cancelled)),
      (.networkChanged, .failure(TracerouteError.cancelled)):
      break
    default:
      Issue.record("\(canceller): \(outcome)")
    }

    gate.open()
    #expect(await eventually(within: Self.watchdog) { resolver.returned.value == 1 })
    #expect(await tracer.publicIP(for: .v4) == nil, "the abandoned answer was cached")
  }

  // MARK: Results

  @Test("The source is encoded beside the address, and JSON without it still decodes")
  func sourceCodable() throws {
    let trace = ClassifiedTrace(
      destinationHost: "example.com", destinationIP: "93.184.216.34", publicIP: "8.8.8.8",
      publicIPSource: .stun, hops: [])
    let json = try #require(String(data: try JSONEncoder().encode(trace), encoding: .utf8))
    #expect(json.contains(#""publicIPSource":"stun""#), "\(json)")

    let legacy = #"{"destinationHost":"example.com","destinationIP":"93.184.216.34","hops":[]}"#
    let decoded = try JSONDecoder().decode(ClassifiedTrace.self, from: Data(legacy.utf8))
    #expect(decoded.publicIPSource == nil)
    let roundTripped = try JSONDecoder().decode(
      ClassifiedTrace.self, from: try JSONEncoder().encode(trace))
    #expect(roundTripped.publicIPSource == .stun)
  }
}
