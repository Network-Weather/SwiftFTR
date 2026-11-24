import Foundation
import Testing

@testable import SwiftFTR

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
    /// Answers once the clock has passed the request's deadline, whatever happens to its task.
    case afterDeadline(PublicIPObservation)
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

  var requests: [PublicIPRequest] { lock.withLock { recorded } }

  private func record(_ request: PublicIPRequest) {
    lock.withLock { recorded.append(request) }
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
    case .afterDeadline(let observation):
      while ContinuousClock.now < request.deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
      }
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

  /// One classified trace through `network`, or a fresh two-hop one, under the watchdog.
  static func classify(_ tracer: SwiftFTR, on given: FakeICMPNetwork? = nil) async throws
    -> ClassifiedTrace
  {
    let network = try given ?? FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { if given == nil { network.stop() } }
    return try await network.install {
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
    let resolver = ScriptedPublicIPResolver(.answer(Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver))
    #expect(await tracer.seedPublicIP("2606:4700::1111", source: .gatewayReported))

    let trace = try await Self.classify(tracer)

    #expect(resolver.requests.map(\.family) == [.v4])
    #expect(trace.publicIP == "9.9.9.9")
    #expect(await tracer.publicIP(for: .v6)?.source == .gatewayReported)
  }

  @Test("A seed of the trace's family answers it without asking, and names its source")
  func seedAnswersWithoutAsking() async throws {
    let resolver = ScriptedPublicIPResolver(.answer(Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver))
    #expect(await tracer.seedPublicIP("8.8.8.8", source: .gatewayReported))

    let trace = try await Self.classify(tracer)

    #expect(resolver.asked.value == 0)
    #expect(trace.publicIP == "8.8.8.8")
    #expect(trace.publicIPSource == .gatewayReported)
  }

  @Test("A configured address answers only traces of its family, and only if it is public")
  func configuredAddressPrecedence() async throws {
    for (configured, expectAsked) in [
      ("9.9.9.9", false), ("2606:4700::1111", true), ("10.0.0.1", true),
    ] {
      let resolver = ScriptedPublicIPResolver(.answer(Self.observation("8.8.8.8")))
      let tracer = Self.tracer(.custom(resolver), publicIP: configured)
      let trace = try await Self.classify(tracer)
      #expect(resolver.asked.value == (expectAsked ? 1 : 0), "configured \(configured)")
      #expect(trace.publicIP == (expectAsked ? "8.8.8.8" : configured), "configured \(configured)")
      let source = expectAsked ? Self.hostApp : PublicIPObservationSource.configured
      #expect(trace.publicIPSource == source, "configured \(configured)")
    }
  }

  @Test("With the strategy disabled nothing is asked and the trace classifies without an address")
  func disabledStrategy() async throws {
    let discovery = OfflinePublicIPDiscovery()
    let tracer = Self.tracer(.disabled)

    let trace = try await discovery.install { try await Self.classify(tracer) }

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
    let resolver = ScriptedPublicIPResolver(
      .answer(
        PublicIPObservation(address: answer.address, family: answer.family, source: Self.hostApp)))
    let tracer = Self.tracer(.custom(resolver))

    let trace = try await Self.classify(tracer)

    #expect(resolver.asked.value == 1)
    #expect(trace.publicIP == nil)
    #expect(trace.publicIPSource == nil)
    #expect(await tracer.publicIP(for: .v4) == nil)
    #expect(await tracer.publicIP(for: .v6) == nil)
  }

  @Test("A resolver that throws costs the trace its public address, not its result")
  func throwingResolver() async throws {
    let resolver = ScriptedPublicIPResolver(.fail)
    let tracer = Self.tracer(.custom(resolver))

    let trace = try await Self.classify(tracer)
    #expect(resolver.asked.value == 1)
    #expect(trace.publicIP == nil)
    #expect(trace.hops.count == 2)
    // A miss lasts for its call only: the next trace asks again.
    _ = try await Self.classify(tracer)
    #expect(resolver.asked.value == 2)
  }

  @Test("The library's own answer is checked as a caller's is")
  func libraryAnswerChecked() async throws {
    let privateAnswer: TestSeams.DiscoverPublicIP = { _ in STUNPublicIP(ip: "192.168.1.1") }
    let trace = try await TestSeams.$discoverPublicIP.withValue(privateAnswer) {
      try await Self.classify(Self.tracer(.library))
    }
    #expect(trace.publicIP == nil)
  }

  // MARK: The deadline

  @Test("A resolver that never returns is abandoned at the deadline and cancelled")
  func neverReturns() async throws {
    let resolver = ScriptedPublicIPResolver(.never)
    // The resolver never answers, so only the 0.3 s budget can end the question in time.
    let tracer = Self.tracer(.custom(resolver), budget: 0.3)

    let trace = try await Self.classify(tracer)

    #expect(trace.publicIP == nil)
    #expect(trace.hops.count == 2)
    // The resolver's task can start after the deadline has already decided the race.
    #expect(await eventually(within: Self.watchdog) { resolver.asked.value == 1 })
    let cancelled = await eventually(within: Self.watchdog) { resolver.cancelled.value == 1 }
    #expect(cancelled, "the abandoned resolver's task was not cancelled")
  }

  @Test("A resolver that ignores cancellation and answers late is neither used nor cached")
  func lateAnswerDropped() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let resolver = ScriptedPublicIPResolver(
      .ignoringCancellation(gate, Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver), budget: 0.3)

    let trace = try await Self.classify(tracer)
    let stillWaiting = resolver.returned.value == 0
    #expect(stillWaiting, "the trace returned only once the resolver had answered")
    #expect(trace.publicIP == nil)

    gate.open()
    let answered = await eventually(within: Self.watchdog) { resolver.returned.value == 1 }
    #expect(answered)
    #expect(await tracer.publicIP(for: .v4) == nil, "the late answer was cached")
  }

  @Test("An answer given once the clock has passed the deadline is refused, woken or not")
  func answerPastDeadlineRefused() async throws {
    let resolver = ScriptedPublicIPResolver(.afterDeadline(Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver), budget: 0.2)
    // No wake-up at all, so the answer is the only event: the commit rule alone must refuse it.
    let neverWake: TestSeams.ArmPublicIPDeadline = { _, _ in {} }

    let trace = try await TestSeams.$armPublicIPDeadline.withValue(neverWake) {
      try await Self.classify(tracer)
    }

    #expect(resolver.returned.value == 1, "the resolver never answered")
    #expect(trace.publicIP == nil, "a late answer was accepted")
    #expect(await tracer.publicIP(for: .v4) == nil, "a late answer was cached")
  }

  @Test("A wake-up that runs before the deadline does not end the question")
  func earlyWakeIgnored() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let resolver = ScriptedPublicIPResolver(.answer(Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver))
    // Wakes the race at once, long before the deadline, as a timer firing early would.
    let wakeAtOnce: TestSeams.ArmPublicIPDeadline = { _, wake in
      wake()
      return {}
    }

    let trace = try await TestSeams.$armPublicIPDeadline.withValue(wakeAtOnce) {
      try await Self.classify(tracer, on: network)
    }

    #expect(trace.publicIP == "9.9.9.9", "an early wake-up ended the question")
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

  // MARK: Multipath

  static let multipathConfig = MultipathConfig(
    flowVariations: 7, maxPaths: 16, earlyStopThreshold: 7, timeoutMs: 2000, maxHops: 4)

  /// One multipath run through `network`, or a fresh two-hop one, under the watchdog.
  static func discoverPaths(_ tracer: SwiftFTR, on given: FakeICMPNetwork? = nil) async throws
    -> NetworkTopology
  {
    let network = try given ?? FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { if given == nil { network.stop() } }
    return try await network.install {
      try await measure(within: Self.watchdog) {
        try await tracer.discoverPaths(to: "fake.test", config: Self.multipathConfig)
      }.0
    }
  }

  @Test("A multipath run asks once, before its first batch, and every flow uses the answer")
  func multipathAsksOnce() async throws {
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let probesAtAsk = TimeStamp()
    let resolver = ScriptedPublicIPResolver(.answer(Self.observation("9.9.9.9"))) {
      probesAtAsk.set(TimeInterval(network.probes.value))
      // The question takes a known time, which the run's reported duration must include.
      usleep(400_000)
    }
    let tracer = Self.tracer(.custom(resolver))

    let topology = try await Self.discoverPaths(tracer, on: network)

    #expect(topology.discoveryDuration >= 0.4, "the duration leaves out the question")

    #expect(resolver.asked.value == 1)
    #expect(resolver.requests.map(\.family) == [.v4])
    #expect(probesAtAsk.value == 0, "asked after a flow had started probing")
    #expect(topology.paths.count == 7, "two batches of flows")
    #expect(topology.paths.allSatisfy { $0.trace.publicIP == "9.9.9.9" })
    #expect(topology.paths.allSatisfy { $0.trace.publicIPSource == Self.hostApp })
    #expect(topology.publicIP == "9.9.9.9")
    #expect(topology.publicIPSource == Self.hostApp)
  }

  @Test("A multipath run with no answer shares its one miss with every flow")
  func multipathSharesMiss() async throws {
    let discovery = OfflinePublicIPDiscovery()
    let tracer = Self.tracer(.library)

    let topology = try await discovery.install { try await Self.discoverPaths(tracer) }

    #expect(
      discovery.calls.value == 1, "the library's discovery ran \(discovery.calls.value) times")
    #expect(topology.paths.count == 7)
    #expect(topology.paths.allSatisfy { $0.trace.publicIP == nil })
    #expect(topology.publicIP == nil)
    #expect(topology.publicIPSource == nil)
  }

  @Test("An IPv6 seed does not label a multipath run, which asks for IPv4")
  func ipv6SeedThenMultipath() async throws {
    let resolver = ScriptedPublicIPResolver(.answer(Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver))
    #expect(await tracer.seedPublicIP("2606:4700::1111", source: .gatewayReported))

    let topology = try await Self.discoverPaths(tracer)

    #expect(resolver.requests.map(\.family) == [.v4])
    #expect(topology.publicIP == "9.9.9.9")
    #expect(topology.paths.allSatisfy { $0.trace.publicIP == "9.9.9.9" })
  }

  @Test("A network change during a multipath run's question ends the run before any probe")
  func multipathQuestionCancelled() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let network = try FakeICMPNetwork(script: pathScript(destinationTTL: 2))
    defer { network.stop() }
    let resolver = ScriptedPublicIPResolver(
      .ignoringCancellation(gate, Self.observation("9.9.9.9")))
    let tracer = Self.tracer(.custom(resolver))

    let outcome = try await network.install {
      let task = Task {
        try await tracer.discoverPaths(to: "fake.test", config: Self.multipathConfig)
      }
      let asked = await eventually(within: Self.watchdog) { resolver.asked.value > 0 }
      #expect(asked, "the run never asked its question")
      await tracer.networkChanged()
      return try await measure(within: Self.watchdog) { await task.result }.0
    }
    let stillWaiting = resolver.returned.value == 0
    #expect(stillWaiting, "the run ended only once the resolver had answered")
    guard case .failure(TracerouteError.cancelled) = outcome else {
      Issue.record("expected TracerouteError.cancelled, got \(outcome)")
      return
    }
    #expect(network.probes.value == 0, "a flow probed after the run was cancelled")
  }

  @Test("An IPv4-mapped address is an IPv4 observation, from every origin; NAT64 stays IPv6")
  func ipv4MappedIsIPv4() async throws {
    let seeded = Self.tracer(.disabled)
    #expect(await seeded.seedPublicIP("::ffff:8.8.8.8", source: .gatewayReported))
    #expect(await seeded.publicIP(for: .v4)?.address == "8.8.8.8")
    #expect(await seeded.publicIP(for: .v6) == nil)
    #expect(await seeded.seedPublicIP("64:ff9b::8.8.4.4", source: .gatewayReported))
    #expect(await seeded.publicIP(for: .v6)?.address == "64:ff9b::808:404")

    let configured = Self.tracer(.disabled, publicIP: "::ffff:9.9.9.9")
    #expect(await configured.publicIP(for: .v4)?.address == "9.9.9.9")
    #expect(await configured.publicIP(for: .v6) == nil)

    let mapped = PublicIPObservation(address: "::ffff:9.9.9.9", family: .v4, source: Self.hostApp)
    #expect(validatedPublicIP(mapped, for: .v4)?.address == "9.9.9.9")
    let mappedAsV6 = PublicIPObservation(
      address: "::ffff:9.9.9.9", family: .v6, source: Self.hostApp)
    #expect(validatedPublicIP(mappedAsV6, for: .v6) == nil)
  }

  /// An input the operation rejects, and the call that must reject it before asking.
  struct RejectedInput: CustomTestStringConvertible, Sendable {
    let why: String
    var multipath = true
    var target = "127.0.0.1"
    var interface: String? = nil
    var sourceIP: String? = nil
    var socket: (@Sendable () -> Int32)? = nil
    var testDescription: String { why }
  }

  static let rejectedInputs: [RejectedInput] = [
    RejectedInput(why: "malformed source", sourceIP: "not-an-ip"),
    RejectedInput(why: "source this host cannot bind", sourceIP: "192.0.2.77"),
    RejectedInput(why: "no socket to check the source", sourceIP: "127.0.0.1", socket: { -1 }),
    RejectedInput(why: "missing interface", interface: "swiftftr-none0"),
    RejectedInput(why: "IPv6 destination literal", target: "::1"),
    RejectedInput(
      why: "classified trace, malformed source", multipath: false, sourceIP: "not-an-ip"),
  ]

  @Test(
    "An input the call rejects is rejected before the question is asked",
    arguments: rejectedInputs)
  func rejectedBeforeQuestion(input: RejectedInput) async throws {
    // Nothing is probed either: each input fails before a socket sends.
    let resolver = ScriptedPublicIPResolver(.answer(Self.observation("9.9.9.9")))
    let tracer = offlineTracer(
      SwiftFTRConfig(
        maxHops: 4, maxWaitMs: 2000, noReverseDNS: true, interface: input.interface,
        sourceIP: input.sourceIP, publicIPResolver: .custom(resolver)))
    await #expect(throws: (any Error).self, "the call accepted the input") {
      try await TestSeams.$validationSocket.withValue(input.socket) {
        if input.multipath {
          _ = try await tracer.discoverPaths(to: input.target, config: Self.multipathConfig)
        } else {
          _ = try await tracer.traceClassified(to: input.target, resolver: EmptyASNResolver())
        }
      }
    }
    #expect(resolver.asked.value == 0, "asked before rejecting the input")
  }

  @Test("A source address of the other family means no question, not one from another address")
  func sourceOfOtherFamilyAsksNothing() async throws {
    let resolver = ScriptedPublicIPResolver(.answer(Self.observation("9.9.9.9")))
    let tracer = offlineTracer(SwiftFTRConfig(sourceIP: "::1", publicIPResolver: .custom(resolver)))
    let observation = try await tracer.publicIPObservation(for: .v4, handle: nil)
    #expect(observation == nil)
    #expect(resolver.asked.value == 0)
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

    let topology = NetworkTopology(
      destination: "example.com", destinationIP: "93.184.216.34", sourceAdapter: nil,
      sourceIP: nil, publicIP: "8.8.8.8", publicIPSource: .gatewayReported, paths: [],
      uniquePathCount: 0, discoveryDuration: 0)
    let topologyJSON = try JSONEncoder().encode(topology)
    #expect(
      String(decoding: topologyJSON, as: UTF8.self).contains(#""publicIPSource":"gatewayReported""#)
    )
    let topologyBack = try JSONDecoder().decode(NetworkTopology.self, from: topologyJSON)
    #expect(topologyBack.publicIPSource == .gatewayReported)
    let legacyTopology =
      #"{"destination":"example.com","destinationIP":"93.184.216.34","publicIP":"8.8.8.8","paths":[],"uniquePathCount":0,"discoveryDuration":0}"#
    let oldTopology = try JSONDecoder().decode(
      NetworkTopology.self, from: Data(legacyTopology.utf8))
    #expect(oldTopology.publicIP == "8.8.8.8")
    #expect(oldTopology.publicIPSource == nil)
  }
}
