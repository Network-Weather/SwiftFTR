import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Wall-clock budget shared by every probe in one traceroute send burst.
///
/// A trace sets its socket non-blocking and pushes `maxHops` probes (40 by
/// default) back to back, then waits `maxWaitMs` (1000 by default) for replies.
/// One budget covers the whole burst rather than each probe: a per-probe budget
/// of the same size would let 40 probes consume ten seconds and blow the
/// receive deadline. At 250 ms the worst case spends a quarter of the default
/// receive window recovering from buffer pressure and still leaves 750 ms for
/// replies.
internal let traceBurstSendRetryBudget: TimeInterval = 0.25

/// Wall-clock budget for a single ping send.
///
/// Ping sends one packet at a time, on the same serial queue that runs its read
/// source, so a send that waits also postpones reply processing and inflates the
/// measured RTT of packets already in flight. 50 ms bounds that distortion while
/// still covering the millisecond-scale buffer pressure the field reports.
internal let pingSendRetryBudget: TimeInterval = 0.05

/// Longest nap taken between attempts when `sendto` reports `ENOBUFS`.
private let enobufsBackoff: TimeInterval = 0.001

/// Reports whether a `sendto` errno means "no room right now" rather than a
/// delivery failure.
///
/// Only these three are retried. Every other errno propagates immediately:
/// callers map `EHOSTUNREACH`, `ENETDOWN` and `ENETUNREACH` to offline states
/// and `EACCES` to a permissions diagnostic, and delaying those reports would
/// delay the diagnosis.
@inline(__always)
internal func isTransientSendErrno(_ code: Int32) -> Bool {
  code == EAGAIN || code == EWOULDBLOCK || code == ENOBUFS
}

/// Runs `attempt` — one `sendto` call, returning its raw result — until it
/// succeeds, until it fails with a non-transient errno, or until `deadline`
/// passes.
///
/// Between attempts the wait depends on the errno. `EAGAIN`/`EWOULDBLOCK` mean
/// the socket send buffer is full, which `poll(POLLOUT)` reports draining.
/// `ENOBUFS` reports the interface output queue instead, and `poll` returns the
/// socket writable immediately in that state, so that errno backs off on a short
/// sleep rather than spinning.
///
/// - Parameters:
///   - sockfd: the descriptor `attempt` sends on, used for the writability wait.
///   - deadline: monotonic timestamp, as returned by `monotonicNow()`, past
///     which no further attempt is made.
///   - attempt: performs one `sendto` and returns its result.
/// - Returns: the byte count reported by the successful `sendto`.
/// - Throws: `TracerouteError.sendFailed(errno:)` carrying the errno of the
///   final attempt.
internal func sendRetryingTransientPressure(
  sockfd: Int32, deadline: TimeInterval, attempt: () -> ssize_t
) throws -> ssize_t {
  while true {
    let sent = attempt()
    if sent >= 0 { return sent }

    let code = errno
    guard isTransientSendErrno(code) else {
      throw TracerouteError.sendFailed(errno: code)
    }
    let remaining = deadline - monotonicNow()
    guard remaining > 0 else {
      throw TracerouteError.sendFailed(errno: code)
    }
    waitForSendCapacity(sockfd: sockfd, code: code, remaining: remaining)
  }
}

/// Waits for the send path to make room, for at most `remaining` seconds.
private func waitForSendCapacity(sockfd: Int32, code: Int32, remaining: TimeInterval) {
  if code == ENOBUFS {
    let nap = min(enobufsBackoff, remaining)
    usleep(useconds_t(max(1, Int(nap * 1_000_000))))
    return
  }
  var descriptor = pollfd(fd: sockfd, events: Int16(POLLOUT), revents: 0)
  let timeoutMs = Int32(clamping: Int((remaining * 1000).rounded(.up)))
  _ = poll(&descriptor, 1, max(1, timeoutMs))
}
