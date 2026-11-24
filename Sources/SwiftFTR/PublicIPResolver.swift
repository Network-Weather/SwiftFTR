import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// An IP address family.
public enum IPAddressFamily: String, Sendable, Hashable, Codable, CaseIterable {
  case v4
  case v6

  /// The socket family of a numeric address, or `nil` if `address` is not one. An IPv4-mapped
  /// address is `.v6` here; ``publicAddress(_:)`` gives the family a public address belongs to.
  init?(address: String) {
    switch detectAddressFamily(address) {
    case AF_INET: self = .v4
    case AF_INET6: self = .v6
    default: return nil
    }
  }

  /// `AF_INET` or `AF_INET6`.
  var socketFamily: Int32 { self == .v6 ? AF_INET6 : AF_INET }
}

/// Where a public-address observation came from.
///
/// The library names its own sources with the static members below. A caller's
/// ``PublicIPResolver`` names its own, with these or with any value it creates, and the name is
/// reported unchanged on ``ClassifiedTrace/publicIPSource``.
public struct PublicIPObservationSource: RawRepresentable, Hashable, Sendable, Codable,
  CustomStringConvertible
{
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }

  /// ``SwiftFTRConfig/publicIP``.
  public static let configured = PublicIPObservationSource(rawValue: "configured")
  /// ``SwiftFTR/seedPublicIP(_:source:)`` with ``PublicIPSource/validatedCallerCache``.
  public static let validatedCallerCache = PublicIPObservationSource(
    rawValue: "validatedCallerCache")
  /// ``SwiftFTR/seedPublicIP(_:source:)`` with ``PublicIPSource/gatewayReported``.
  public static let gatewayReported = PublicIPObservationSource(rawValue: "gatewayReported")
  /// The library's resolver, from a STUN Binding response sent from this host.
  public static let stun = PublicIPObservationSource(rawValue: "stun")
}

extension PublicIPSource {
  /// The observation source a seed of this kind is reported as.
  var observationSource: PublicIPObservationSource {
    switch self {
    case .validatedCallerCache: .validatedCallerCache
    case .gatewayReported: .gatewayReported
    }
  }
}

/// A public address, its family, and where it came from.
public struct PublicIPObservation: Sendable, Hashable, Codable {
  /// The address, in canonical `inet_ntop` form once the tracer has accepted it.
  public let address: String
  /// The family the address was observed for.
  public let family: IPAddressFamily
  /// Where the address came from.
  public let source: PublicIPObservationSource

  public init(address: String, family: IPAddressFamily, source: PublicIPObservationSource) {
    self.address = address
    self.family = family
    self.source = source
  }
}

/// One question to a ``PublicIPResolver``: the public address of one family, as seen from the
/// interface and source address the tracer is bound to.
public struct PublicIPRequest: Sendable {
  /// The family asked for. An answer of another family is refused.
  public let family: IPAddressFamily
  /// The BSD interface the tracer is bound to, or `nil` for system routing.
  public let interface: String?
  /// The source address the tracer is bound to, or `nil`. Only an address of ``family`` is passed.
  public let sourceIP: String?
  /// When the tracer stops waiting. An answer that arrives later is dropped and never cached.
  public let deadline: ContinuousClock.Instant

  public init(
    family: IPAddressFamily, interface: String?, sourceIP: String?,
    deadline: ContinuousClock.Instant
  ) {
    self.family = family
    self.interface = interface
    self.sourceIP = sourceIP
    self.deadline = deadline
  }
}

/// Finds the public address a classified trace or a multipath run labels its hops with. Set one
/// with ``PublicIPResolverStrategy/custom(_:)`` when the host app knows more than the library can
/// find out: which interface is the hardline and which the VPN, what the gateway reports.
///
/// The tracer asks once per call, for the family the trace probed, and only when no configured,
/// seeded or cached address of that family exists. It waits until ``PublicIPRequest/deadline``,
/// or until its caller is cancelled or ``SwiftFTR/networkChanged()`` or
/// ``SwiftFTR/cancelActiveTraces()`` runs, then cancels the resolver's task and drops what it
/// returns. Only a globally routable address of the family asked for is used; `nil` or a throw
/// means no address for this call.
public protocol PublicIPResolver: Sendable {
  /// The public address of `request.family`, or `nil` if there is none to report.
  func publicIP(for request: PublicIPRequest) async throws -> PublicIPObservation?
}

/// How a tracer finds its public address when none of the family is configured, seeded or cached.
public enum PublicIPResolverStrategy: Sendable {
  /// The library's own resolver: STUN only, over the family asked for, from sockets bound to the
  /// tracer's interface and source address. Bounded by ``SwiftFTRConfig/publicIPDiscoveryTimeout``.
  /// Where STUN gets no answer there is no address.
  case library
  /// No discovery: nothing is sent, and a trace without a configured or seeded address of its
  /// family classifies without one.
  case disabled
  /// The caller's resolver, asked under ``SwiftFTRConfig/publicIPDiscoveryTimeout``.
  case custom(any PublicIPResolver)
}

/// The canonical form and family of `presentation` as a public address, or `nil` if it is not a
/// globally routable one (``isGloballyRoutablePublicIP(_:)``). An IPv4-mapped IPv6 address
/// (`::ffff:a.b.c.d`) has IPv4 routing semantics, so it is the IPv4 address, in dotted-quad
/// form; every other address is in `inet_ntop` form. The one rule for seeds, the configured
/// address and every resolver's answer.
func publicAddress(_ presentation: String) -> (address: String, family: IPAddressFamily)? {
  guard isGloballyRoutablePublicIP(presentation), let parsed = ParsedIPAddress(presentation)
  else { return nil }
  if let v4 = parsed.canonicalIPv4Presentation { return (v4, .v4) }
  guard let canonical = canonicalIPAddress(presentation) else { return nil }
  return (canonical, .v6)
}

/// `observation`, in canonical form, if it is a public address of `family` that says it is of
/// that family (see ``publicAddress(_:)``); otherwise `nil`.
func validatedPublicIP(_ observation: PublicIPObservation, for family: IPAddressFamily)
  -> PublicIPObservation?
{
  guard observation.family == family, let accepted = publicAddress(observation.address),
    accepted.family == family
  else { return nil }
  return PublicIPObservation(address: accepted.address, family: family, source: observation.source)
}

/// Seconds from now until `instant` on the continuous clock, never less than zero.
func secondsUntil(_ instant: ContinuousClock.Instant) -> TimeInterval {
  let components = ContinuousClock.now.duration(to: instant).components
  let seconds = TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
  return max(seconds, 0)
}

/// Asks a caller's `resolver`, and returns its answer, or `nil` if it does not answer before
/// `request.deadline`.
///
/// The deadline rule: the one place an outcome is committed reads the clock first, and an answer
/// or failure committed once it has reached `request.deadline` is `nil`, whatever arrived first, so
/// nothing late is accepted however late the wake-up runs. The wake-up only commits that `nil`, and
/// does nothing if it runs early. Cancellation of the calling task wins whenever it comes. The
/// resolver runs in a task this does not wait for, so one that never returns or ignores
/// cancellation cannot hold the caller; it is cancelled once the outcome is committed.
///
/// - Throws: `CancellationError` when the calling task is cancelled first, or the resolver's own
///   error when it throws in time.
func askWithinDeadline(_ resolver: any PublicIPResolver, _ request: PublicIPRequest) async throws
  -> PublicIPObservation?
{
  let deadline = request.deadline
  // Nothing is started for a caller already cancelled.
  try Task.checkCancellation()
  let race = DeadlineRace(deadline: deadline)
  let arm = TestSeams.armPublicIPDeadline ?? sleepUntilDeadline
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      race.attach(continuation)
      let ask = Task {
        do {
          race.commit(.answer(.success(try await resolver.publicIP(for: request))))
        } catch {
          race.commit(.answer(.failure(error)))
        }
      }
      let stopWake = arm(deadline) { race.commit(.wake) }
      race.onFinish {
        ask.cancel()
        stopWake()
      }
    }
  } onCancel: {
    race.commit(.cancellation)
  }
}

/// The default wake-up for ``askWithinDeadline(_:_:)``: a task sleeping until `deadline`.
@Sendable func sleepUntilDeadline(
  _ deadline: ContinuousClock.Instant, wake: @escaping @Sendable () -> Void
) -> @Sendable () -> Void {
  let timer = Task {
    while !Task.isCancelled {
      try? await Task.sleep(until: deadline, clock: .continuous)
      if ContinuousClock.now >= deadline { break }
    }
    if !Task.isCancelled { wake() }
  }
  return { timer.cancel() }
}

/// The race behind ``askWithinDeadline(_:_:)``: resumes one continuation with the first outcome
/// committed, from any thread and in any order, then runs the cleanup once.
final class DeadlineRace: @unchecked Sendable {
  enum Event {
    case answer(Result<PublicIPObservation?, Error>)
    case wake
    case cancellation
  }

  private let deadline: ContinuousClock.Instant
  private let lock = NSLock()
  private var continuation: CheckedContinuation<PublicIPObservation?, Error>?
  private var outcome: Result<PublicIPObservation?, Error>?
  private var cleanup: (@Sendable () -> Void)?

  init(deadline: ContinuousClock.Instant) {
    self.deadline = deadline
  }

  func attach(_ newContinuation: CheckedContinuation<PublicIPObservation?, Error>) {
    lock.lock()
    guard let outcome else {
      continuation = newContinuation
      lock.unlock()
      return
    }
    lock.unlock()
    newContinuation.resume(with: outcome)
  }

  /// The one place an outcome is committed: the first committed is delivered. The clock is read
  /// here, under the lock, for every event but cancellation (see ``askWithinDeadline(_:_:)``).
  func commit(_ event: Event) {
    lock.lock()
    guard outcome == nil else {
      lock.unlock()
      return
    }
    let passed = ContinuousClock.now >= deadline
    let decided: Result<PublicIPObservation?, Error>
    switch event {
    case .cancellation:
      decided = .failure(CancellationError())
    case .wake:
      guard passed else {
        lock.unlock()
        return
      }
      decided = .success(nil)
    case .answer(let answer):
      decided = passed ? .success(nil) : answer
    }
    outcome = decided
    let waiting = continuation
    continuation = nil
    let pending = cleanup
    cleanup = nil
    lock.unlock()
    waiting?.resume(with: decided)
    pending?()
  }

  /// Runs `body` once the race is decided, or at once if it already is.
  func onFinish(_ body: @escaping @Sendable () -> Void) {
    lock.lock()
    guard outcome == nil else {
      lock.unlock()
      body()
      return
    }
    cleanup = body
    lock.unlock()
  }
}
