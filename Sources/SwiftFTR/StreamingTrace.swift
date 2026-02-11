// StreamingTrace.swift
// SwiftFTR
//
// Types for streaming traceroute API

import Foundation

/// A hop emitted during streaming traceroute.
///
/// This is a minimal structure containing only the raw hop data (IP + RTT).
/// It does not include hostname or ASN information - the caller is responsible
/// for enriching hops with rDNS/ASN data if needed.
///
/// ## Emission Behavior
/// - Hops are emitted in **arrival order** (as ICMP responses are received), not TTL order.
/// - Each TTL is emitted **at most once** - if retry probes are sent and both respond,
///   only the first response is emitted.
/// - Callers should sort by `ttl` if sequential ordering is needed.
///
/// ## RTT Timing
/// The `rtt` value is measured using monotonic clock timestamps:
/// - Captured immediately after `sendto()` returns (probe transmission)
/// - Calculated as `receive_time - send_time` when the response arrives
///
/// If a TTL requires a retry probe (due to the first probe timing out), the RTT
/// reflects whichever probe's response arrives first:
/// - If original probe responds late: RTT measured from original send time
/// - If retry probe responds first: RTT measured from retry send time
///
/// This means the reported RTT always reflects the actual round-trip time of the
/// probe that elicited the response, not the total wait time.
public struct StreamingHop: Sendable, Equatable {
  /// Time-To-Live that elicited this response (1-based).
  public let ttl: Int

  /// Responder IPv4 address. `nil` for timeout placeholders.
  public let ipAddress: String?

  /// Round-trip time in seconds for this hop. `nil` for timeout placeholders.
  public let rtt: TimeInterval?

  /// Whether this reply came from the destination host.
  /// `true` for Echo Reply (destination reached), `false` for Time Exceeded.
  public let reachedDestination: Bool

  public init(
    ttl: Int,
    ipAddress: String?,
    rtt: TimeInterval?,
    reachedDestination: Bool
  ) {
    self.ttl = ttl
    self.ipAddress = ipAddress
    self.rtt = rtt
    self.reachedDestination = reachedDestination
  }
}

/// Configuration for streaming traceroute behavior.
///
/// The streaming trace uses a two-phase strategy:
/// 1. **Initial phase** (0 to `probeTimeout`): Wait for responses from all probes
/// 2. **Retry phase**: After `retryAfter` seconds, re-probe any TTLs before the destination
///    that haven't responded yet. This helps with rate-limited routers or packet loss.
///
/// This allows immediate notification of fast hops while retrying unresponsive middle-hops
/// that may have been dropped or rate-limited.
public struct StreamingTraceConfig: Sendable {
  /// Total timeout for the trace (default: 10 seconds).
  /// The trace will complete after this time, emitting timeout placeholders for any
  /// TTLs that never responded.
  public let probeTimeout: TimeInterval

  /// Time to wait before re-probing unresponsive TTLs (default: 4 seconds).
  /// After this duration, any TTL before the destination that hasn't responded
  /// will receive a second probe. Set to `nil` to disable retry.
  public let retryAfter: TimeInterval?

  /// Whether to emit timeout placeholders for missing TTLs at end of stream.
  /// When `true`, after the deadline expires, `StreamingHop` values with
  /// `ipAddress: nil` and `rtt: nil` are emitted for any TTLs that didn't respond.
  /// Default: `true`.
  public let emitTimeouts: Bool

  /// Maximum number of hops (TTLs) to probe. Default: 40.
  public let maxHops: Int

  public init(
    probeTimeout: TimeInterval = 10.0,
    retryAfter: TimeInterval? = 4.0,
    emitTimeouts: Bool = true,
    maxHops: Int = 40
  ) {
    precondition(maxHops >= 1 && maxHops <= 255, "maxHops must be 1...255")
    precondition(probeTimeout > 0, "probeTimeout must be positive")
    self.probeTimeout = probeTimeout
    self.retryAfter = retryAfter
    self.emitTimeouts = emitTimeouts
    self.maxHops = maxHops
  }

  /// Default configuration with 10s timeout, 4s retry threshold.
  public static let `default` = StreamingTraceConfig()
}
