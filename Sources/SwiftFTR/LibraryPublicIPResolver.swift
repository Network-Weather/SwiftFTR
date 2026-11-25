import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// The library's own public-IP resolver: STUN only, for the family asked, from sockets bound to
/// the request's interface and source address.
///
/// It never asks a recursive resolver for a whoami name, whose answer can be another host's
/// (#153). Every STUN socket is bound before its server name is resolved, and a failed bind sends
/// nothing, the lookup included (#151); the lookup itself uses the system resolver, unbound. A
/// source address not of the family asked, or whose zone names no interface, sends nothing. It
/// holds the request's deadline itself, so the tracer runs no second timer against it.
struct LibraryPublicIPResolver: PublicIPResolver {
  /// The per-server STUN timeout for a classified trace, a multipath run and
  /// ``SwiftFTR/discoverPublicIPWithHostname()``.
  static let tracerSTUNTimeout: TimeInterval = 2.0

  var stunTimeout: TimeInterval = Self.tracerSTUNTimeout
  let enableLogging: Bool

  func publicIP(for request: PublicIPRequest) async throws -> PublicIPObservation? {
    try await publicIPDiscovery(
      family: request.family, stunTimeout: stunTimeout, interface: request.interface,
      sourceIP: request.sourceIP, enableLogging: enableLogging,
      budget: secondsUntil(request.deadline))
  }
}

/// The library resolver's discovery of one family: the test substitute when one is bound,
/// otherwise the STUN sweep, ended once `budget` seconds pass. `nil`, with nothing sent, when
/// `sourceIP` is given and is not an address of `family`.
///
/// The budget bounds the whole discovery: one absolute deadline, `budget` seconds from entry, is
/// passed down to the sweep's admission, every name lookup and every STUN attempt, and no step
/// outlives it. The deadline is on `monotonicNow()`'s clock, which counts system sleep, and every
/// decision against it (admission, each lookup, each send, each reply) reads that clock. The
/// sweep ends by the deadline on its own; no second timer is raced against it, so a reply taken
/// in time is not lost to one. A
/// lookup stalled in `getaddrinfo` keeps only its executor slot. A test substitute, which can do
/// anything, is cancelled and awaited when the deadline passes. A `budget` that is infinite or
/// beyond 10^9 seconds is no bound; one that is not positive, or not a number, ends discovery
/// before it starts.
///
/// The answer's source is ``PublicIPObservationSource/stun``, a test substitute's included.
///
/// - Throws: ``PublicIPDiscoveryTimeout`` when the budget passes with no address,
///   `CancellationError` when the calling task is cancelled, or the sweep's own error.
func publicIPDiscovery(
  family: IPAddressFamily,
  stunTimeout: TimeInterval,
  interface: String?,
  sourceIP: String?,
  enableLogging: Bool,
  budget: TimeInterval
) async throws -> PublicIPObservation? {
  try Task.checkCancellation()
  // A zone that names no interface (`::1%`, `fe80::1%nope`) would bind with no scope at all.
  if let sourceIP,
    IPAddressFamily(address: sourceIP) != family
      || (sourceIP.contains("%") && parseIPv6Scoped(sourceIP).scopeID == 0)
  {
    if enableLogging {
      print("[PublicIP] Source address '\(sourceIP)' cannot be bound for \(family); not asking")
    }
    return nil
  }
  // `!(budget > 0)` also refuses NaN.
  guard budget > 0 else { throw PublicIPDiscoveryTimeout() }
  let bounded = budget.isFinite && budget < 1e9
  let clock = discoveryClock()
  let deadline = bounded ? clock() + budget : nil

  guard let substitute = TestSeams.discoverPublicIP else {
    let outcome: Result<STUNPublicIP, Error>
    do {
      outcome = .success(
        try await stunGetPublicIPWithFallback(
          family: family.socketFamily, timeout: stunTimeout, interface: interface,
          sourceIP: sourceIP, enableLogging: enableLogging, deadline: deadline))
    } catch {
      outcome = .failure(error)
    }
    let found = try publicIPDiscoveryOutcome(
      outcome, now: clock(), deadline: deadline ?? .infinity, cancelled: Task.isCancelled)
    return PublicIPObservation(address: found.ip, family: family, source: .stun)
  }

  let request = PublicIPRequest(
    family: family, interface: interface, sourceIP: sourceIP,
    deadline: bounded ? .now + .seconds(budget) : .now + .seconds(1e9))
  let discover: @Sendable () async throws -> PublicIPObservation = {
    let found = try await substitute(request)
    return PublicIPObservation(address: found.ip, family: family, source: .stun)
  }
  guard let deadline else { return try await discover() }
  return try await withThrowingTaskGroup(of: PublicIPObservation.self) { group in
    group.addTask { try await discover() }
    group.addTask {
      let left = secondsLeft(until: deadline) ?? 0
      try await Task.sleep(nanoseconds: UInt64(left * 1_000_000_000))
      throw PublicIPDiscoveryTimeout()
    }
    // The first child to finish is the outcome; the other is cancelled and awaited.
    defer { group.cancelAll() }
    let first: Result<PublicIPObservation, Error>
    do {
      guard let value = try await group.next() else { throw PublicIPDiscoveryTimeout() }
      first = .success(value)
    } catch {
      first = .failure(error)
    }
    return try publicIPDiscoveryOutcome(
      first, now: clock(), deadline: deadline, cancelled: Task.isCancelled)
  }
}
