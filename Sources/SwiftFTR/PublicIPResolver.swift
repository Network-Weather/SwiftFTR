import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// An IP address family.
public enum IPAddressFamily: String, Sendable, Hashable, Codable, CaseIterable {
  case v4
  case v6

  /// The family of a numeric address, or `nil` if `address` is not one.
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
  /// The library's resolver, from its IPv4 fallback: a whoami TXT query answered through a public
  /// recursive resolver. The address it reports can belong to another host than this one.
  public static let dnsWhoami = PublicIPObservationSource(rawValue: "dnsWhoami")
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

/// Finds the public address a classified trace or a multipath run labels its hops with.
///
/// Set one with ``PublicIPResolverStrategy/custom(_:)`` when the host app knows more than the
/// library can find out: which interface is the hardline and which the VPN, what the gateway
/// reports, what it observed a minute ago.
///
/// The tracer asks once per call, for the family the trace probed, and only when no configured,
/// seeded or cached address of that family exists. It waits until ``PublicIPRequest/deadline``
/// and no longer, and stops waiting at once when its caller is cancelled, ``SwiftFTR/networkChanged()``
/// runs or ``SwiftFTR/cancelActiveTraces()`` runs; the resolver's task is cancelled then, and
/// whatever it returns afterwards is dropped. An answer is used only if it is a globally routable
/// address of the family asked for. Returning `nil` or throwing means no address for this call.
public protocol PublicIPResolver: Sendable {
  /// The public address of `request.family`, or `nil` if there is none to report.
  func publicIP(for request: PublicIPRequest) async throws -> PublicIPObservation?
}

/// How a tracer finds its public address when none of the family is configured, seeded or cached.
public enum PublicIPResolverStrategy: Sendable {
  /// The library's own resolver: STUN, with a DNS whoami fallback for IPv4. Bounded by
  /// ``SwiftFTRConfig/publicIPDiscoveryTimeout``.
  case library
  /// No discovery: nothing is sent, and a trace without a configured or seeded address of its
  /// family classifies without one.
  case disabled
  /// The caller's resolver, asked under ``SwiftFTRConfig/publicIPDiscoveryTimeout``.
  case custom(any PublicIPResolver)
}

/// `observation`, in canonical form, if it is a globally routable address of `family` that says
/// it is of that family; otherwise `nil`.
func validatedPublicIP(_ observation: PublicIPObservation, for family: IPAddressFamily)
  -> PublicIPObservation?
{
  guard observation.family == family,
    IPAddressFamily(address: observation.address) == family,
    isGloballyRoutablePublicIP(observation.address),
    let canonical = canonicalIPAddress(observation.address)
  else { return nil }
  return PublicIPObservation(address: canonical, family: family, source: observation.source)
}

/// Seconds from now until `instant` on the continuous clock, never less than zero.
func secondsUntil(_ instant: ContinuousClock.Instant) -> TimeInterval {
  let components = ContinuousClock.now.duration(to: instant).components
  let seconds = TimeInterval(components.seconds) + TimeInterval(components.attoseconds) * 1e-18
  return max(seconds, 0)
}

/// The library's resolver: the discovery of ``publicIPDiscovery(family:stunTimeout:dnsTimeout:interface:sourceIP:enableLogging:budget:)``,
/// bounded by the request's deadline, which it holds itself.
struct LibraryPublicIPResolver: PublicIPResolver {
  let enableLogging: Bool

  func publicIP(for request: PublicIPRequest) async throws -> PublicIPObservation? {
    try await publicIPDiscovery(
      family: request.family, stunTimeout: 2.0, dnsTimeout: 3.0, interface: request.interface,
      sourceIP: request.sourceIP, enableLogging: enableLogging,
      budget: secondsUntil(request.deadline))
  }
}

/// Asks a caller's `resolver`, and returns its answer, or `nil` once `request.deadline` passes
/// first.
///
/// One resume decides: the answer, the deadline, or the calling task's cancellation, whichever
/// comes first. The resolver runs in a task of its own that this does not wait for, so one that
/// never returns, or ignores cancellation, cannot hold the caller; it is cancelled when the race
/// is decided, and what it returns afterwards goes nowhere.
///
/// - Throws: `CancellationError` when the calling task is cancelled first, or the resolver's own
///   error when it throws first.
func askWithinDeadline(_ resolver: any PublicIPResolver, _ request: PublicIPRequest) async throws
  -> PublicIPObservation?
{
  let race = SingleResumeRace<PublicIPObservation?>()
  return try await withTaskCancellationHandler {
    try await withCheckedThrowingContinuation { continuation in
      race.attach(continuation)
      let ask = Task {
        do {
          race.finish(.success(try await resolver.publicIP(for: request)))
        } catch {
          race.finish(.failure(error))
        }
      }
      let timer = Task {
        try? await Task.sleep(until: request.deadline, clock: .continuous)
        race.finish(.success(nil))
      }
      race.onFinish {
        ask.cancel()
        timer.cancel()
      }
    }
  } onCancel: {
    race.finish(.failure(CancellationError()))
  }
}

/// Resumes one continuation with the first result offered, from any thread, however the offer and
/// the attachment are ordered, then runs the cleanup once.
final class SingleResumeRace<T: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?
  private var outcome: Result<T, Error>?
  private var cleanup: (@Sendable () -> Void)?

  func attach(_ newContinuation: CheckedContinuation<T, Error>) {
    lock.lock()
    guard let outcome else {
      continuation = newContinuation
      lock.unlock()
      return
    }
    lock.unlock()
    newContinuation.resume(with: outcome)
  }

  /// Offers `result`; only the first offer is delivered.
  func finish(_ result: Result<T, Error>) {
    lock.lock()
    guard outcome == nil else {
      lock.unlock()
      return
    }
    outcome = result
    let waiting = continuation
    continuation = nil
    let pending = cleanup
    cleanup = nil
    lock.unlock()
    waiting?.resume(with: result)
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
