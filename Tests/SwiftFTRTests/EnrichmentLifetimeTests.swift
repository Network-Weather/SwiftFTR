import Foundation
import Testing

@testable import SwiftFTR

/// An ASN lookup's timeout bounds the whole call through every resolver it passes; a caller
/// returns at its deadline with every answer learned so far; and no caller leaving stops or
/// poisons shared work. Deadlines are passed by moving a test clock (`MovableClock`), so no test
/// has a real-time window to beat: each resolver timeout is 60 s, past the 20 s watchdog.
@Suite
struct EnrichmentLifetimeTests {
  static let watchdog: TimeInterval = 20
  static let timeout: TimeInterval = 60

  enum Leave: CaseIterable { case deadline, cancellation }

  // MARK: - Team Cymru

  @Test("Both Cymru query phases end at the caller's deadline", arguments: [false, true])
  func cymruPhasesEndAtTheDeadline(originAnswers: Bool) async throws {
    let fixture = try CymruTXTFixture(answersOrigin: originAnswers, name: .silent)
    defer { fixture.stop() }
    let clock = MovableClock()
    let lookup = Task {
      try await fixture.bind(clock) {
        try await CymruDNSResolver(servers: ["127.0.0.1"])
          .resolve(ipv4Addrs: [fixture.address], timeout: Self.timeout)
      }
    }
    // The query of the silent phase has reached the server, so the call is waiting on it.
    let waiting = await eventually(within: Self.watchdog) {
      (originAnswers ? fixture.nameQueries.value : fixture.originQueries.value) > 0
    }
    #expect(waiting)
    clock.jump(by: 2 * Self.timeout)

    let (found, _) = try await measure(within: Self.watchdog) { try await lookup.value }
    if originAnswers {
      // An origin whose name had not arrived is still an answer.
      #expect(found[fixture.address]?.asn == CymruTXTFixture.asn)
      #expect(found[fixture.address]?.name == "")
    } else {
      #expect(found.isEmpty)
    }
  }

  // MARK: - Caching resolver

  @Test("A caller leaving a cached lookup at its deadline gets the origin; a later one, the name")
  func cachedLookupReturnsTheOriginThenTheName() async throws {
    // The AS-name reply is held, then refused, so the shared flight outlives the second caller.
    let nameGate = StallGate()
    defer { nameGate.open() }
    let fixture = try CymruTXTFixture(answersOrigin: true, name: .refuse(after: nameGate))
    defer { fixture.stop() }
    let caching = CachingASNResolver(base: CymruDNSResolver(servers: ["127.0.0.1"]))
    let (ownerClock, joinerClock) = (MovableClock(), MovableClock())
    let owner = Task {
      try await fixture.bind(ownerClock) {
        try await caching.resolve(ipv4Addrs: [fixture.address], timeout: Self.timeout)
      }
    }
    let waiting = await eventually(within: Self.watchdog) { fixture.nameQueries.value > 0 }
    #expect(waiting)
    let joiner = Task {
      try await fixture.bind(joinerClock) {
        try await caching.resolve(ipv4Addrs: [fixture.address], timeout: Self.timeout)
      }
    }
    let joined = await eventually(within: Self.watchdog) { caching.joinCount == 1 }
    #expect(joined)
    joinerClock.jump(by: 2 * Self.timeout)

    // The flight is still waiting for its name; what it published is returned.
    let (partial, _) = try await measure(within: Self.watchdog) { try await joiner.value }
    #expect(partial[fixture.address]?.asn == CymruTXTFixture.asn)
    #expect(partial[fixture.address]?.name == "")

    // The flight ran on after the joiner left, and ends without the name.
    nameGate.open()
    let (owned, _) = try await measure(within: Self.watchdog) { try await owner.value }
    #expect(owned[fixture.address]?.name == "")

    // The entry without its name was not cached as complete: the next lookup asks again.
    fixture.name.set(.answer)
    let (named, _) = try await measure(within: Self.watchdog) {
      try await fixture.bind(joinerClock) {
        try await caching.resolve(ipv4Addrs: [fixture.address], timeout: Self.timeout)
      }
    }
    #expect(named[fixture.address]?.name == CymruTXTFixture.name)
  }

  @Test(
    "A caller's outcome does not depend on which of its flights ends first",
    arguments: [false, true])
  func outcomeIndependentOfFlightOrder(joinedFlightFails: Bool) async throws {
    let (held, other) = (uniqueASNTestAddress(), uniqueASNTestAddress())
    let base = ScriptedASNResolver(failsAtOnce: [])
    defer { Task { await base.releaseAll() } }
    let caching = CachingASNResolver(base: base)

    // One owner's flight holds `held`, another's `other`; a third caller joins both.
    let owners = [held, other].map { address in
      Task {
        await resultOf { try await caching.resolve(ipv4Addrs: [address], timeout: Self.timeout) }
      }
    }
    let started = await eventually(within: Self.watchdog) {
      let (a, b) = (await base.calls(held), await base.calls(other))
      return a == 1 && b == 1
    }
    #expect(started)
    let clock = MovableClock()
    let joiner = Task {
      try await TestSeams.$monotonicClock.withValue(clock.now) {
        try await caching.resolve(ipv4Addrs: [held, other], timeout: Self.timeout)
      }
    }
    let joined = await eventually(within: Self.watchdog) { caching.joinCount == 2 }
    #expect(joined)

    // The first flight in the joiner's order fails and the second is held, or the reverse. The
    // failed flight's owner has its outcome before the joiner's deadline passes.
    let (failing, heldOwner) = joinedFlightFails ? (0, 1) : (1, 0)
    await base.fail([held, other][failing])
    let (failedOwner, _) = try await measure(within: Self.watchdog) { await owners[failing].value }
    #expect(throws: ScriptedASNResolver.Failure.self) { try failedOwner.get() }
    clock.jump(by: 2 * Self.timeout)

    let (outcome, _) = try await measure(within: Self.watchdog) {
      await resultOf { try await joiner.value }
    }
    #expect(throws: ScriptedASNResolver.Failure.self) { try outcome.get() }

    // The held flight ran on after the joiner left: its owner gets what it found.
    await base.succeed([held, other][heldOwner])
    let (ownerOutcome, _) = try await measure(within: Self.watchdog) {
      await owners[heldOwner].value
    }
    #expect((try? ownerOutcome.get())?[[held, other][heldOwner]] != nil)
  }

  // MARK: - Hybrid resolver

  @Test(
    "The hybrid's DNS fallback ends at the earlier of the caller's deadline and its own, with the origin",
    arguments: [(timeout, 10 * timeout), (10 * timeout, timeout)])
  func hybridFallbackEndsAtTheDeadline(caller: TimeInterval, fallback: TimeInterval) async throws {
    let fixture = try CymruTXTFixture(answersOrigin: true, name: .silent)
    defer { fixture.stop() }
    let hybrid = HybridASNResolver(
      local: Self.failingLocalResolver(),
      dns: CachingASNResolver(base: CymruDNSResolver(servers: ["127.0.0.1"])),
      fallbackTimeout: fallback)
    let clock = MovableClock()
    let lookup = Task {
      try await fixture.bind(clock) {
        try await hybrid.resolve(ipv4Addrs: [fixture.address], timeout: caller)
      }
    }
    let waiting = await eventually(within: Self.watchdog) { fixture.nameQueries.value > 0 }
    #expect(waiting)
    // Past the shorter of the two bounds, not the longer.
    clock.jump(by: 2 * min(caller, fallback))

    let (found, _) = try await measure(within: Self.watchdog) { try await lookup.value }
    #expect(found[fixture.address]?.asn == CymruTXTFixture.asn)
    #expect(found[fixture.address]?.name == "")
    // A flight that outlived the caller ends at its own budget, so it holds no socket after this.
    clock.jump(by: 2 * max(caller, fallback))
  }

  @Test("Concurrent hybrid fallbacks are keyed by fallbackTimeout, so they share one flight")
  func hybridFallbackKeyIsItsTimeout() async throws {
    let base = ScriptedASNResolver(failsAtOnce: [], answersAtOnce: true)
    let fallback: TimeInterval = 0.75
    let hybrid = HybridASNResolver(
      local: Self.failingLocalResolver(), dns: CachingASNResolver(base: base),
      fallbackTimeout: fallback)
    // Every clock read is a millisecond later, so time left is never the configured value.
    let ticks = Locked(0.0)
    let ticking: @Sendable () -> TimeInterval = {
      ticks.set(ticks.value + 0.001)
      return ticks.value
    }
    _ = try await TestSeams.$monotonicClock.withValue(ticking) {
      try await hybrid.resolve(ipv4Addrs: [uniqueASNTestAddress()], timeout: Self.timeout)
    }
    let timeouts = await base.timeouts
    // Exactly the configured value, never the time left, so every caller's key is the same.
    #expect(timeouts == [fallback])
  }

  // MARK: - Local database

  @Test(
    "A wait for the database load ends at the deadline or on cancellation; the load runs on",
    arguments: Leave.allCases)
  func localLoadWaitEnds(leave: Leave) async throws {
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let store = LocalASNDatabaseStore { _ in
      entered.increment()
      await gate.waitAsync(limit: 60)
      return try await LocalASNDatabaseStore.load(.embedded)
    }
    let resolver = LocalASNResolver(source: .embedded, store: store)
    let clock = MovableClock()
    let waiter = Task {
      try await TestSeams.$monotonicClock.withValue(clock.now) {
        try await resolver.resolve(ipv4Addrs: ["8.8.8.8"], timeout: Self.timeout)
      }
    }
    let loading = await eventually(within: Self.watchdog) { entered.value == 1 }
    #expect(loading)
    switch leave {
    case .deadline: clock.jump(by: 2 * Self.timeout)
    case .cancellation: waiter.cancel()
    }

    // Released while the load is still held at the gate.
    let (left, _) = try await measure(within: Self.watchdog) {
      await resultOf { try await waiter.value }
    }
    switch leave {
    case .deadline: #expect((try? left.get()) == [:])
    case .cancellation: #expect(throws: CancellationError.self) { try left.get() }
    }

    // The same load finishes for the next caller; the resolver is not latched as failed.
    gate.open()
    let (after, _) = try await measure(within: Self.watchdog) {
      try await resolver.resolve(ipv4Addrs: ["8.8.8.8"], timeout: Self.timeout)
    }
    #expect(after["8.8.8.8"]?.asn == 15169)
    let loads = await store.loadCount
    #expect(entered.value == 1)
    #expect(loads == 1)
  }

  @Test("A caller already cancelled starts no database load")
  func cancelledCallerStartsNoLoad() async throws {
    let store = LocalASNDatabaseStore()
    let resolver = LocalASNResolver(source: .embedded, store: store)
    let outcome = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await resultOf { try await resolver.resolve(ipv4Addrs: ["8.8.8.8"], timeout: 60) }
    }.value
    #expect(throws: CancellationError.self) { try outcome.get() }
    let loads = await store.loadCount
    #expect(loads == 0)
  }

  // MARK: - Shared work

  @Test("Waiters that leave shared work, at a deadline or cancelled, leave nothing registered")
  func waitersLeaveNothingRegistered() async throws {
    let gate = StallGate()
    defer { gate.open() }
    let work = SharedASNWork<Void> { _ in await gate.waitAsync(limit: 60) }
    let clock = MovableClock()
    let timed = (0..<20).map { _ in
      Task {
        await TestSeams.$monotonicClock.withValue(clock.now) {
          await work.wait(until: clock.now() + Self.timeout).outcome == nil
        }
      }
    }
    let cancelled = (0..<20).map { _ in Task { await work.wait(until: nil).outcome == nil } }
    let registered = await eventually(within: Self.watchdog) { work.waiterCount == 40 }
    #expect(registered)

    clock.jump(by: 2 * Self.timeout)
    for task in cancelled { task.cancel() }
    for task in timed + cancelled {
      let (unfinished, _) = try await measure(within: Self.watchdog) { await task.value }
      #expect(unfinished)
    }
    #expect(work.waiterCount == 0)

    // The work itself ran on.
    gate.open()
    let (ended, _) = try await measure(within: Self.watchdog) { await work.wait(until: nil) }
    #expect(ended.outcome != nil)
  }

  // MARK: - Shared work runs on its own budget

  @Test("A shared fallback runs on its own budget: the caller that started it cannot cut it short")
  func sharedFallbackOutlivesItsStarter() async throws {
    let nameGate = StallGate()
    defer { nameGate.open() }
    let fixture = try CymruTXTFixture(answersOrigin: true, name: .answerAfter(nameGate))
    defer { fixture.stop() }
    let caching = CachingASNResolver(base: CymruDNSResolver(servers: ["127.0.0.1"]))
    let hybrid = HybridASNResolver(
      local: Self.failingLocalResolver(), dns: caching, fallbackTimeout: 10 * Self.timeout)
    let (starterClock, joinerClock) = (MovableClock(), MovableClock())
    // The starter has 60 s; the fallback it starts has 600 s.
    let starter = Task {
      try await fixture.bind(starterClock) {
        try await hybrid.resolve(ipv4Addrs: [fixture.address], timeout: Self.timeout)
      }
    }
    let waiting = await eventually(within: Self.watchdog) { fixture.nameQueries.value > 0 }
    #expect(waiting)
    let joiner = Task {
      try await fixture.bind(joinerClock) {
        try await hybrid.resolve(ipv4Addrs: [fixture.address], timeout: 10 * Self.timeout)
      }
    }
    let joined = await eventually(within: Self.watchdog) { caching.joinCount == 1 }
    #expect(joined)

    // The starter's deadline passes; it leaves with the origin, and the flight goes on.
    starterClock.jump(by: 2 * Self.timeout)
    let (partial, _) = try await measure(within: Self.watchdog) { try await starter.value }
    #expect(partial[fixture.address]?.name == "")

    nameGate.open()
    let (named, _) = try await measure(within: Self.watchdog) { try await joiner.value }
    #expect(named[fixture.address]?.name == CymruTXTFixture.name)
    #expect(fixture.nameQueries.value == 1)
  }

  @Test(
    "A cache in front of a hybrid that joined a running fallback hears what it published",
    arguments: [true, false])
  func joinerForwardsWhatItsFlightPublished(originBeforeJoin: Bool) async throws {
    let (originGate, nameGate) = (StallGate(), StallGate())
    defer {
      originGate.open()
      nameGate.open()
    }
    if originBeforeJoin { originGate.open() }
    let fixture = try CymruTXTFixture(
      answersOrigin: true, originGate: originGate, name: .refuse(after: nameGate))
    defer { fixture.stop() }
    let dns = CachingASNResolver(base: CymruDNSResolver(servers: ["127.0.0.1"]))
    let hybrid = HybridASNResolver(
      local: Self.failingLocalResolver(), dns: dns, fallbackTimeout: 10 * Self.timeout)
    let outer = CachingASNResolver(base: hybrid)
    let (fallbackClock, outerClock, joinerClock) = (MovableClock(), MovableClock(), MovableClock())
    // A hybrid lookup starts the DNS fallback, which learns the origin and waits for the name.
    let fallbackOwner = Task {
      try await fixture.bind(fallbackClock) {
        try await hybrid.resolve(ipv4Addrs: [fixture.address], timeout: Self.timeout)
      }
    }
    // Either the origin is already known when the hybrid below the outer cache joins, or it
    // arrives while that hybrid waits.
    let waiting = await eventually(within: Self.watchdog) {
      originBeforeJoin ? fixture.nameQueries.value > 0 : fixture.originQueries.value > 0
    }
    #expect(waiting)
    // The outer cache's flight runs the hybrid, which joins that fallback rather than starting it.
    let outerOwner = Task {
      try await fixture.bind(outerClock) {
        try await outer.resolve(ipv4Addrs: [fixture.address], timeout: Self.timeout)
      }
    }
    let innerJoined = await eventually(within: Self.watchdog) { dns.joinCount == 1 }
    #expect(innerJoined)
    // A second outer caller joins the outer flight and leaves at its deadline, while every
    // flight below it is still waiting for the name.
    let joiner = Task {
      try await fixture.bind(joinerClock) {
        try await outer.resolve(ipv4Addrs: [fixture.address], timeout: Self.timeout)
      }
    }
    let outerJoined = await eventually(within: Self.watchdog) { outer.joinCount == 1 }
    #expect(outerJoined)
    if !originBeforeJoin {
      // The origin is learned, and published, before its AS-name query goes out.
      originGate.open()
      let named = await eventually(within: Self.watchdog) { fixture.nameQueries.value > 0 }
      #expect(named)
    }
    joinerClock.jump(by: 2 * Self.timeout)
    let (found, _) = try await measure(within: Self.watchdog) { try await joiner.value }
    #expect(found[fixture.address]?.asn == CymruTXTFixture.asn)
    #expect(fixture.originQueries.value == 1)

    nameGate.open()
    _ = try await measure(within: Self.watchdog) { try await fallbackOwner.value }
    _ = try await measure(within: Self.watchdog) { try await outerOwner.value }
  }

  // MARK: - A passed deadline returns what is known

  @Test("A passed deadline starts nothing, and returns what each source already holds")
  func passedDeadlineReturnsWhatIsKnown() async throws {
    // A cache hit.
    let (cachedAddress, fallbackAddress) = (uniqueASNTestAddress(), uniqueASNTestAddress())
    let base = ScriptedASNResolver(failsAtOnce: [], answersAtOnce: true)
    let caching = CachingASNResolver(base: base)
    _ = try await caching.resolve(ipv4Addrs: [cachedAddress], timeout: Self.timeout)
    let hit = try await caching.resolve(ipv4Addrs: [cachedAddress], timeout: 0)
    let baseCalls = await base.calls(cachedAddress)
    #expect(hit[cachedAddress] != nil)
    #expect(baseCalls == 1)

    // The hybrid's cached DNS answer.
    let dns = ScriptedASNResolver(failsAtOnce: [], answersAtOnce: true)
    let hybrid = HybridASNResolver(
      local: Self.failingLocalResolver(), dns: CachingASNResolver(base: dns), fallbackTimeout: 1)
    _ = try await hybrid.resolve(ipv4Addrs: [fallbackAddress], timeout: Self.timeout)
    let fromCache = try await hybrid.resolve(ipv4Addrs: [fallbackAddress], timeout: 0)
    let dnsCalls = await dns.calls(fallbackAddress)
    #expect(fromCache[fallbackAddress] != nil)
    #expect(dnsCalls == 1)

    // What a running shared flight has published: the origin, before its name.
    let nameGate = StallGate()
    defer { nameGate.open() }
    let fixture = try CymruTXTFixture(answersOrigin: true, name: .refuse(after: nameGate))
    defer { fixture.stop() }
    let running = HybridASNResolver(
      local: Self.failingLocalResolver(),
      dns: CachingASNResolver(base: CymruDNSResolver(servers: ["127.0.0.1"])),
      fallbackTimeout: Self.timeout)
    let clock = MovableClock()
    let owner = Task {
      try await fixture.bind(clock) {
        try await running.resolve(ipv4Addrs: [fixture.address], timeout: Self.timeout)
      }
    }
    let waiting = await eventually(within: Self.watchdog) { fixture.nameQueries.value > 0 }
    #expect(waiting)
    let published = try await fixture.bind(clock) {
      try await running.resolve(ipv4Addrs: [fixture.address], timeout: 0)
    }
    #expect(published[fixture.address]?.asn == CymruTXTFixture.asn)
    #expect(fixture.originQueries.value == 1)
    nameGate.open()
    _ = try await measure(within: Self.watchdog) { try await owner.value }

    // A database another resolver already holds.
    let store = LocalASNDatabaseStore()
    let holder = LocalASNResolver(source: .embedded, store: store)
    await holder.preload()
    let late = try await LocalASNResolver(source: .embedded, store: store)
      .resolve(ipv4Addrs: ["8.8.8.8"], timeout: 0)
    let loads = await store.loadCount
    #expect(late["8.8.8.8"]?.asn == 15169)
    #expect(loads == 1)
    withExtendedLifetime(holder) {}
  }

  @Test("A caching resolver that is gone leaves nothing of its own in the shared cache")
  func discardedResolverIsReleased() async throws {
    final class WeakScope: @unchecked Sendable { weak var scope: _ASNResolverScope? }
    let released = WeakScope()
    let address = uniqueASNTestAddress()
    do {
      let base = ScriptedASNResolver(failsAtOnce: [])
      let caching = CachingASNResolver(base: base)
      released.scope = caching.scope
      let first = Task {
        try await caching.resolve(ipv4Addrs: [address], timeout: Self.timeout)
      }
      let started = await eventually(within: Self.watchdog) { await base.calls(address) == 1 }
      #expect(started)
      let second = Task {
        try await caching.resolve(ipv4Addrs: [address], timeout: Self.timeout)
      }
      let joined = await eventually(within: Self.watchdog) { caching.joinCount == 1 }
      #expect(joined)
      await base.succeed(address)
      _ = try await measure(within: Self.watchdog) { try await first.value }
      _ = try await measure(within: Self.watchdog) { try await second.value }
    }
    let gone = await eventually(within: Self.watchdog) { released.scope == nil }
    #expect(gone)
  }

  // MARK: - Extremes

  @Test("Extreme timeouts do not crash; a passed deadline starts nothing, an endless one waits")
  func extremeTimeouts() async throws {
    let passed: [TimeInterval] = [0, -1, -.infinity, .nan]
    let endless: [TimeInterval] = [
      .infinity, .greatestFiniteMagnitude, 1e300, Double(Int.max).nextDown,
    ]
    for timeout in passed + endless {
      let expectAnswer = endless.contains(where: { $0.bitPattern == timeout.bitPattern })
      let (address, fallbackAddress) = (uniqueASNTestAddress(), uniqueASNTestAddress())

      let base = ScriptedASNResolver(failsAtOnce: [], answersAtOnce: true)
      let (cached, _) = try await measure(within: Self.watchdog) {
        try await CachingASNResolver(base: base).resolve(ipv4Addrs: [address], timeout: timeout)
      }
      let cachedCalls = await base.calls(address)
      #expect((cached[address] != nil) == expectAnswer, "cache, \(timeout)")
      #expect(cachedCalls == (expectAnswer ? 1 : 0), "cache, \(timeout)")

      let dns = ScriptedASNResolver(failsAtOnce: [], answersAtOnce: true)
      let hybrid = HybridASNResolver(
        local: Self.failingLocalResolver(), dns: CachingASNResolver(base: dns),
        fallbackTimeout: 1)
      let (fellBack, _) = try await measure(within: Self.watchdog) {
        try await hybrid.resolve(ipv4Addrs: [fallbackAddress], timeout: timeout)
      }
      let dnsCalls = await dns.calls(fallbackAddress)
      #expect((fellBack[fallbackAddress] != nil) == expectAnswer, "hybrid, \(timeout)")
      #expect(dnsCalls == (expectAnswer ? 1 : 0), "hybrid, \(timeout)")

      let store = LocalASNDatabaseStore()
      let local = LocalASNResolver(source: .embedded, store: store)
      let (loaded, _) = try await measure(within: Self.watchdog) {
        try await local.resolve(ipv4Addrs: ["8.8.8.8"], timeout: timeout)
      }
      let loads = await store.loadCount
      #expect((loaded["8.8.8.8"] != nil) == expectAnswer, "local, \(timeout)")
      #expect(loads == (expectAnswer ? 1 : 0), "local, \(timeout)")
    }
  }

  /// A local resolver whose database fails to load, so a hybrid asks DNS for everything.
  static func failingLocalResolver() -> LocalASNResolver {
    struct Missing: Error {}
    return LocalASNResolver(
      source: .embedded, store: LocalASNDatabaseStore { _ in throw Missing() })
  }
}

/// Team Cymru's two TXT answers for one address, from a loopback responder whose AS-name answer
/// can be withheld, or held and then refused.
final class CymruTXTFixture: @unchecked Sendable {
  static let asn = 64496
  static let name = "EXAMPLE-NET, ZZ"

  enum NameReply: Sendable {
    case silent
    /// The serve thread waits for the gate, then refuses the query.
    case refuse(after: StallGate)
    /// The serve thread waits for the gate, then answers.
    case answerAfter(StallGate)
    case answer
  }

  /// The address this fixture answers for, distinct per fixture, since the cache's answers are
  /// shared by address across resolvers and repetitions.
  let address = uniqueASNTestAddress()
  let name: Locked<NameReply>
  let originQueries = FaultCounter()
  let nameQueries = FaultCounter()
  private let responder: LoopbackUDPResponder

  /// - Parameter originGate: When given, the origin reply waits for it.
  init(answersOrigin: Bool, originGate: StallGate? = nil, name nameReply: NameReply) throws {
    let name = Locked(nameReply)
    self.name = name
    let (origins, names) = (originQueries, nameQueries)
    let originQuery =
      address.split(separator: ".").reversed().joined(separator: ".")
      + ".origin.asn.cymru.com"
    responder = try LoopbackUDPResponder(accepts: .dnsQuery()) { query in
      let text: String
      switch CymruFixture.queryName(query)?.lowercased() {
      case originQuery:
        origins.increment()
        guard answersOrigin else { return nil }
        originGate?.wait(limit: 60)
        text = "64496 | 203.0.114.0/24 | ZZ | arin | 2026-01-01"
      case "as64496.asn.cymru.com":
        names.increment()
        switch name.value {
        case .silent:
          return nil
        case .refuse(let gate):
          gate.wait(limit: 60)
          return (
            FaultInjectionWireTests.dnsResponse(to: query, rcode: 5, answerCount: 0, answers: []), 0
          )
        case .answerAfter(let gate):
          gate.wait(limit: 60)
          text = "64496 | ZZ | arin | 2026-01-01 | \(CymruTXTFixture.name)"
        case .answer:
          text = "64496 | ZZ | arin | 2026-01-01 | \(CymruTXTFixture.name)"
        }
      default:
        return nil
      }
      let bytes = Array(text.utf8)
      let rdata = [UInt8(bytes.count)] + bytes
      let record: [UInt8] =
        [0xC0, 0x0C, 0, 16, 0, 1, 0, 0, 0, 60, UInt8(rdata.count >> 8), UInt8(rdata.count & 0xFF)]
        + rdata
      return (FaultInjectionWireTests.dnsResponse(to: query, answers: record), 0)
    }
  }

  func stop() { responder.stop() }

  /// Runs `body` with DNS queries sent to this fixture and deadlines on `clock`.
  func bind<T: Sendable>(_ clock: MovableClock, _ body: () async throws -> T) async rethrows -> T {
    try await TestSeams.$dnsServerPort.withValue(responder.port) {
      try await TestSeams.$monotonicClock.withValue(clock.now) { try await body() }
    }
  }
}

/// A globally routable address no other test in this process uses. The cache keeps answers by
/// address across resolvers, so each lookup that must miss needs its own.
func uniqueASNTestAddress() -> String {
  let n = uniqueAddressCounter.mutate { count in
    defer { count += 1 }
    return count
  }
  return "45.\(1 + n / 250 % 250).\(1 + n % 250).7"
}
private let uniqueAddressCounter = Locked(0)

final class Locked<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { stored = value }
  var value: Value { lock.withLock { stored } }
  func set(_ value: Value) { lock.withLock { stored = value } }
  func mutate<T>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&stored) } }
}

/// An ASN resolver that answers or fails each address as the test says: at once, or when
/// released. It ignores its timeout, as a caller's own resolver may.
actor ScriptedASNResolver: ASNResolver {
  struct Failure: Error {}

  private let failsAtOnce: Set<String>
  private let answersAtOnce: Bool
  private var callsByAddress: [String: Int] = [:]
  private var pending: [String: CheckedContinuation<ASNInfo, Error>] = [:]
  private(set) var timeouts: [TimeInterval] = []

  init(failsAtOnce: Set<String>, answersAtOnce: Bool = false) {
    self.failsAtOnce = failsAtOnce
    self.answersAtOnce = answersAtOnce
  }

  func resolve(ipv4Addrs: [String], timeout: TimeInterval) async throws -> [String: ASNInfo] {
    timeouts.append(timeout)
    var out: [String: ASNInfo] = [:]
    for address in ipv4Addrs {
      callsByAddress[address, default: 0] += 1
      if failsAtOnce.contains(address) { throw Failure() }
      out[address] =
        answersAtOnce
        ? ASNInfo(asn: 64500, name: "SCRIPTED")
        : try await withCheckedThrowingContinuation { pending[address] = $0 }
    }
    return out
  }

  func calls(_ address: String) -> Int { callsByAddress[address] ?? 0 }

  func succeed(_ address: String) {
    pending.removeValue(forKey: address)?.resume(returning: ASNInfo(asn: 64500, name: "SCRIPTED"))
  }

  func fail(_ address: String) { pending.removeValue(forKey: address)?.resume(throwing: Failure()) }

  func releaseAll() {
    for address in Array(pending.keys) { succeed(address) }
  }
}
