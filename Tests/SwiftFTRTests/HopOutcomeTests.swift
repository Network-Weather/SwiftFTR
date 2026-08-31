import Foundation
import Testing

@testable import SwiftFTR

/// The distinctions `HopOutcome` exists to make.
@Suite("Hop outcome model")
struct HopOutcomeTests {

  @Test("Time Exceeded and Destination Unreachable are distinguishable")
  func forwardedAndRefusedDiffer() {
    let forwarded = TraceHop(
      ttl: 4, ipAddress: "192.0.2.4", rtt: 0.012, reachedDestination: false, outcome: .replied)
    let refused = TraceHop(
      ttl: 4, ipAddress: "192.0.2.4", rtt: 0.012, reachedDestination: false,
      outcome: .unreachable(code: ICMPUnreachableReason.administrativelyProhibited.rawValue))

    // Every legacy field agrees; only the outcome separates them. That is the bug this fixes.
    #expect(forwarded.ipAddress == refused.ipAddress)
    #expect(forwarded.rtt == refused.rtt)
    #expect(forwarded.reachedDestination == refused.reachedDestination)
    #expect(forwarded.outcome != refused.outcome)

    #expect(refused.outcome.unreachableReason == .administrativelyProhibited)
    #expect(refused.outcome.unreachableReason?.isAdministrative == true)
    #expect(forwarded.outcome.unreachableReason == nil)
  }

  @Test("A probe never sent is distinguishable from one that drew no answer")
  func unsentAndTimedOutDiffer() {
    let unsent = TraceHop(
      ttl: 7, ipAddress: nil, rtt: nil, reachedDestination: false,
      outcome: .notSent(errno: EAGAIN))
    let silent = TraceHop(
      ttl: 7, ipAddress: nil, rtt: nil, reachedDestination: false, outcome: .timedOut)

    // Both render as `* * *`; without the outcome a caller cannot tell that we never sent.
    #expect(unsent.ipAddress == nil && silent.ipAddress == nil)
    #expect(unsent.rtt == nil && silent.rtt == nil)
    #expect(unsent.outcome != silent.outcome)

    #expect(unsent.outcome.didReceiveReply == false)
    #expect(silent.outcome.didReceiveReply == false)
    if case .notSent(let code) = unsent.outcome { #expect(code == EAGAIN) } else { Issue.record() }
  }

  @Test("The pre-existing initializer keeps working and infers a sensible outcome")
  func legacyInitializerInfersOutcome() {
    let answered = TraceHop(ttl: 1, ipAddress: "192.0.2.1", rtt: 0.004, reachedDestination: false)
    let silent = TraceHop(ttl: 2, ipAddress: nil, rtt: nil, reachedDestination: false)

    #expect(answered.outcome == .replied)
    #expect(silent.outcome == .timedOut)
  }

  @Test("Outcome survives a Codable round trip")
  func outcomeRoundTrips() throws {
    let outcomes: [HopOutcome] = [
      .notSent(errno: ENOBUFS), .timedOut, .unreachable(code: 13), .replied,
    ]
    for outcome in outcomes {
      let data = try JSONEncoder().encode(outcome)
      #expect(try JSONDecoder().decode(HopOutcome.self, from: data) == outcome)
    }
  }

  @Test("Unreachable reasons name themselves, and administrative ones are flagged")
  func unreachableReasonsAreNamed() {
    #expect(ICMPUnreachableReason(rawValue: 3) == .port)
    #expect(ICMPUnreachableReason.port.displayName == "port unreachable")
    #expect(ICMPUnreachableReason.port.isAdministrative == false)
    #expect(ICMPUnreachableReason.administrativelyProhibited.isAdministrative)
    #expect(ICMPUnreachableReason.hostProhibited.isAdministrative)
    // A code outside the IPv4 table stays unnamed rather than being coerced.
    #expect(ICMPUnreachableReason(rawValue: 200) == nil)
    #expect(HopOutcome.unreachable(code: 200).unreachableReason == nil)
  }
}

/// Degrading a probe that could not be sent, rather than failing the whole trace.
@Suite("Send burst degradation")
struct SendBurstDegradationTests {

  /// A socket that is closed, so every `sendto` fails immediately with a non-transient errno.
  private func closedSocket() -> Int32 {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    close(fd)
    return fd
  }

  @Test("A non-transient errno still aborts the whole burst")
  func nonTransientErrnoStillThrows() throws {
    var outstanding: [UInt16: TraceSendInfo] = [:]
    let resolved = try resolveHost(host: "127.0.0.1", prefer: .v4)

    // EBADF is not transient, so this must not be swallowed into a per-hop outcome.
    #expect(throws: (any Error).self) {
      _ = try sendTraceBurst(
        sockfd: closedSocket(), resolved: resolved, identifier: 1, maxHops: 5,
        payloadSize: 56, retryDeadline: monotonicNow() + 0.05, outstanding: &outstanding)
    }
    #expect(outstanding.isEmpty)
  }

  @Test("A burst where every probe fails throws rather than returning a hollow result")
  func allProbesFailingThrows() throws {
    var outstanding: [UInt16: TraceSendInfo] = [:]
    let resolved = try resolveHost(host: "127.0.0.1", prefer: .v4)

    #expect(throws: (any Error).self) {
      _ = try sendTraceBurst(
        sockfd: closedSocket(), resolved: resolved, identifier: 1, maxHops: 3,
        payloadSize: 56, retryDeadline: monotonicNow() + 0.05, outstanding: &outstanding)
    }
  }

  @Test("A healthy burst reports nothing unsent")
  func healthyBurstReportsNoUnsent() throws {
    var outstanding: [UInt16: TraceSendInfo] = [:]
    let resolved = try resolveHost(host: "127.0.0.1", prefer: .v4)
    let fd = try createTraceSocket(family: AF_INET, enableLogging: false)
    defer { close(fd) }

    let unsent = try sendTraceBurst(
      sockfd: fd, resolved: resolved, identifier: 0x4242, maxHops: 5,
      payloadSize: 56, retryDeadline: monotonicNow() + 0.25, outstanding: &outstanding)

    #expect(unsent.isEmpty)
    #expect(outstanding.count == 5)
  }
}
