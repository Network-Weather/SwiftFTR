import Foundation
import SwiftFTR
import Testing

@testable import swift_ftr

/// The pretty output of `swift-ftr probe dns`, one row per ``DNSProbeOutcome``, compared line by
/// line, so an outcome printed as another one, or a missing timing, fails.
@Suite("CLI DNS probe output")
struct CLIDNSProbeOutputTests {
  struct Row: Sendable, CustomTestStringConvertible {
    let name: String
    let result: DNSProbeResult
    let lines: [String]
    var testDescription: String { name }
  }

  static func result(
    _ outcome: DNSProbeOutcome, reachable: Bool, rtt: TimeInterval? = nil,
    elapsed: TimeInterval? = nil, rcode: Int? = nil, error: String? = nil
  ) -> DNSProbeResult {
    DNSProbeResult(
      server: "192.0.2.53", query: "example.com", outcome: outcome, isReachable: reachable,
      rtt: rtt, elapsed: elapsed, responseCode: rcode, error: error)
  }

  static let head = ["DNS probe to 192.0.2.53", "  Query: example.com"]
  static let up = head + ["  Status: ✓ Reachable"]
  static let down = head + ["  Status: ✗ Unreachable"]

  static let rows: [Row] = [
    // An answer prints exactly as before the outcome was shown: no Outcome or Elapsed line.
    Row(
      name: "answered",
      result: result(.answered, reachable: true, rtt: 0.0123, elapsed: 0.0123, rcode: 0),
      lines: up + ["  Response Code: NOERROR (0)", "  RTT: 12.300 ms"]),
    Row(
      name: "answered NXDOMAIN",
      result: result(.answered, reachable: true, rtt: 0.002, elapsed: 0.002, rcode: 3),
      lines: up + ["  Response Code: NXDOMAIN (3)", "  RTT: 2.000 ms"]),
    Row(
      name: "malformedReply",
      result: result(
        .malformedReply, reachable: true, rtt: 0.004, elapsed: 0.004, error: "Malformed response"),
      lines: up + [
        "  Outcome: malformed reply: the server answered, but not with valid DNS",
        "  RTT: 4.000 ms", "  Error: Malformed response",
      ]),
    Row(
      name: "refused",
      result: result(.refused, reachable: false, elapsed: 0.0005, error: "Connection refused"),
      lines: down + [
        "  Outcome: refused: host is up, nothing listening on the port", "  Elapsed: 0.500 ms",
        "  Error: Connection refused",
      ]),
    Row(
      name: "unreachable, reported by the network",
      result: result(.unreachable, reachable: false, elapsed: 0.03, error: "Host unreachable"),
      lines: down + [
        "  Outcome: unreachable: host or network unreachable", "  Elapsed: 30.000 ms",
        "  Error: Host unreachable",
      ]),
    Row(
      name: "unreachable, from this machine",
      result: result(.unreachable, reachable: false, error: "Network unreachable"),
      lines: down + [
        "  Outcome: unreachable: host or network unreachable", "  Error: Network unreachable",
      ]),
    Row(
      name: "timedOut",
      result: result(.timedOut, reachable: false, error: "Timeout - no response"),
      lines: down + ["  Outcome: timed out: no reply", "  Error: Timeout - no response"]),
    Row(
      name: "failed",
      result: result(.failed, reachable: false, error: "Invalid server IP: x"),
      lines: down + [
        "  Outcome: failed: the probe could not complete", "  Error: Invalid server IP: x",
      ]
    ),
    // A probe whose query was sent and whose receive then failed reports `.failed` too, so the
    // wording must not say it never ran.
    Row(
      name: "failed, after the query was sent",
      result: result(.failed, reachable: false, error: "Receive failed (errno=54)"),
      lines: down + [
        "  Outcome: failed: the probe could not complete", "  Error: Receive failed (errno=54)",
      ]),
    // An outcome this build does not know prints its raw value.
    Row(
      name: "an outcome added later",
      result: result(DNSProbeOutcome(rawValue: "someLaterOutcome"), reachable: false),
      lines: down + ["  Outcome: someLaterOutcome"]),
  ]

  @Test("Each outcome prints in plain words, with its timing", arguments: rows)
  func prettyLines(row: Row) {
    #expect(dnsProbePrettyLines(row.result) == row.lines)
  }
}
