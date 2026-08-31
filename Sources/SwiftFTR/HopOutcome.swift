import Foundation

/// Why a hop looks the way it does.
///
/// A hop's address and round-trip time say *what* came back; this says *what happened*, including
/// the cases where nothing came back and the two are indistinguishable from the fields alone.
/// In particular a router that forwarded the probe onward (ICMP Time Exceeded) and a router that
/// refused to route it (ICMP Destination Unreachable) both produce an address and a round-trip
/// time, and only the outcome tells them apart.
///
/// ``TraceHop/outcome`` is authoritative. ``TraceHop/ipAddress``, ``TraceHop/rtt`` and
/// ``TraceHop/reachedDestination`` remain available and are consistent with it.
public enum HopOutcome: Sendable, Equatable, Codable {
  /// The probe for this TTL never left the host.
  ///
  /// Carries the `errno` from the failing `sendto`. The hop reports no address and no timing —
  /// not because the network stayed silent, but because nothing was asked of it. Distinguishing
  /// this from ``timedOut`` is the reason this type exists: both otherwise render as `* * *`.
  case notSent(errno: Int32)

  /// The probe was sent and nothing came back before the deadline.
  ///
  /// Routine in traceroute. Many routers decline to answer, and a hole in the middle of an
  /// otherwise complete path is normal rather than a fault.
  case timedOut

  /// A router or host reported the probe undeliverable (ICMP Destination Unreachable).
  ///
  /// Carries the ICMP code explaining the refusal — see ``ICMPUnreachableReason`` — along with the
  /// responder's address and timing on the hop itself.
  case unreachable(code: UInt8)

  /// The probe drew a normal reply: Time Exceeded from an intermediate hop, or Echo Reply from
  /// the destination. ``TraceHop/reachedDestination`` distinguishes those two.
  case replied

  /// Whether this outcome came from a packet the host actually received.
  ///
  /// `false` for ``notSent`` and ``timedOut``, which have no responder and no timing.
  public var didReceiveReply: Bool {
    switch self {
    case .unreachable, .replied: return true
    case .notSent, .timedOut: return false
    }
  }
}

/// The documented meanings of the ICMP Destination Unreachable codes SwiftFTR is likely to see.
///
/// Provided so callers can render a reason without embedding the IPv4 code table. Codes are
/// family-specific: these are the IPv4 (RFC 792) values, which is what a v4 trace reports.
public enum ICMPUnreachableReason: UInt8, Sendable, CaseIterable {
  case network = 0
  case host = 1
  case protocolUnreachable = 2
  case port = 3
  case fragmentationNeeded = 4
  case sourceRouteFailed = 5
  case networkUnknown = 6
  case hostUnknown = 7
  case sourceHostIsolated = 8
  case networkProhibited = 9
  case hostProhibited = 10
  case networkUnreachableForTOS = 11
  case hostUnreachableForTOS = 12
  case administrativelyProhibited = 13

  /// A short human-readable description suitable for display next to a hop.
  public var displayName: String {
    switch self {
    case .network: return "network unreachable"
    case .host: return "host unreachable"
    case .protocolUnreachable: return "protocol unreachable"
    case .port: return "port unreachable"
    case .fragmentationNeeded: return "fragmentation needed"
    case .sourceRouteFailed: return "source route failed"
    case .networkUnknown: return "network unknown"
    case .hostUnknown: return "host unknown"
    case .sourceHostIsolated: return "source host isolated"
    case .networkProhibited: return "network administratively prohibited"
    case .hostProhibited: return "host administratively prohibited"
    case .networkUnreachableForTOS: return "network unreachable for TOS"
    case .hostUnreachableForTOS: return "host unreachable for TOS"
    case .administrativelyProhibited: return "administratively prohibited"
    }
  }

  /// Whether the refusal looks like a deliberate policy decision rather than a delivery failure.
  ///
  /// Useful for telling "a firewall dropped this on purpose" from "the network could not reach it",
  /// which lead to different conclusions when diagnosing a path.
  public var isAdministrative: Bool {
    switch self {
    case .networkProhibited, .hostProhibited, .administrativelyProhibited: return true
    default: return false
    }
  }
}

extension HopOutcome {
  /// The parsed reason for an ``unreachable`` outcome, when the code is one this library names.
  ///
  /// `nil` for every other outcome, and for codes outside the IPv4 table.
  public var unreachableReason: ICMPUnreachableReason? {
    guard case .unreachable(let code) = self else { return nil }
    return ICMPUnreachableReason(rawValue: code)
  }
}
