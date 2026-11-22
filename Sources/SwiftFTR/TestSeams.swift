import Foundation

/// Substitutes for the system calls SwiftFTR cannot otherwise be made to fail on demand.
///
/// Every value is `nil` in production, which selects the real system call. Tests bind one with
/// `TestSeams.$name.withValue(...)`. Task-local binding scopes the substitute to the binding task
/// and the tasks it creates, so a test never changes process-wide state and parallel tests cannot
/// see each other's substitutes. Blocking work runs on executor threads outside any task, so each
/// seam is read on the async side, before the work is submitted.
///
/// See `docs/ROBUSTNESS-TESTING.md` for the battery that uses them.
enum TestSeams {
  /// Forward resolution of a trace, ping or probe destination, in place of `getaddrinfo`.
  typealias ResolveHost =
    @Sendable (_ host: String, _ prefer: PreferredFamily) throws -> ResolvedHost

  /// Creates the datagram socket a trace or ping sends its echo requests on, in place of an ICMP
  /// socket for `family`.
  typealias MakeICMPSocket = @Sendable (_ family: Int32) throws -> Int32

  /// IPv4 public-address discovery, in place of STUN with its DNS fallback.
  typealias DiscoverPublicIPv4 = @Sendable () throws -> STUNPublicIP

  /// Executor for every `runDetachedBlockingIO` call, in place of the process-wide one.
  @TaskLocal static var blockingIOExecutor: BlockingIOExecutor?

  @TaskLocal static var resolveHost: ResolveHost?

  @TaskLocal static var makeICMPSocket: MakeICMPSocket?

  @TaskLocal static var discoverPublicIPv4: DiscoverPublicIPv4?
}

/// The IPv4 public-address discovery to submit to the blocking-I/O executor: the test substitute
/// when one is bound, otherwise STUN with its DNS fallback.
///
/// Call from async context so the task-local is visible; the returned closure runs anywhere.
func publicIPv4Discovery(
  stunTimeout: TimeInterval,
  dnsTimeout: TimeInterval,
  interface: String?,
  sourceIP: String?,
  enableLogging: Bool
) -> @Sendable () throws -> STUNPublicIP {
  if let substitute = TestSeams.discoverPublicIPv4 { return substitute }
  return {
    try getPublicIPv4(
      stunTimeout: stunTimeout, dnsTimeout: dnsTimeout, interface: interface,
      sourceIP: sourceIP, enableLogging: enableLogging)
  }
}
