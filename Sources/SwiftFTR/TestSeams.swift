import Foundation

/// Substitutes for the system calls SwiftFTR cannot otherwise be made to fail on demand.
///
/// Every value is `nil` in production, which selects the real system call. Tests bind one with
/// `TestSeams.$name.withValue(...)`. Task-local binding scopes the substitute to the binding task
/// and the tasks it creates, so a test never changes process-wide state and parallel tests cannot
/// see each other's substitutes. Blocking work and dispatch queues run outside any task, so each
/// seam is read on the async side, before work is submitted to them.
///
/// See `docs/ROBUSTNESS-TESTING.md` for the battery that uses them.
enum TestSeams {
  /// Forward resolution of a trace, ping or probe destination, in place of `getaddrinfo`.
  typealias ResolveHost =
    @Sendable (_ host: String, _ prefer: PreferredFamily) throws -> ResolvedHost

  /// Creates the datagram socket a trace or ping sends its echo requests on, in place of an ICMP
  /// socket for `family`.
  typealias MakeICMPSocket = @Sendable (_ family: Int32) throws -> Int32

  /// The library resolver's public-address discovery for `request`, in place of the STUN sweep.
  /// It runs under the discovery budget, which cancels it when it passes; `request.deadline` is
  /// that budget's end (about 30 years out for ``getPublicIPs(stunTimeout:interface:sourceIP:enableLogging:)``,
  /// which has none).
  typealias DiscoverPublicIP = @Sendable (_ request: PublicIPRequest) async throws -> STUNPublicIP

  /// The STUN servers a sweep asks, all at once, for one address family. Their order decides
  /// only which failure a sweep with no answer reports: the last one's.
  typealias STUNServers = @Sendable (_ family: Int32) -> [(host: String, port: UInt16)]

  /// Resolution of a STUN server's name for `family`, in place of `getaddrinfo`. Runs in an
  /// executor slot, as the lookup does.
  typealias ResolveSTUNServer =
    @Sendable (_ host: String, _ port: UInt16, _ family: Int32) -> (
      server: sockaddr_storage, serverLen: socklen_t
    )?

  /// `fcntl(2)` with an integer argument, in place of the system call a trace, ping, UDP
  /// exchange, TCP probe or UDP probe uses to make its socket non-blocking. Returns what `fcntl` would and sets `errno`
  /// the same way.
  typealias FileControl = @Sendable (_ fd: Int32, _ command: Int32, _ argument: Int32) -> Int32

  /// `send(2)` of one datagram, in place of the system call a ``UDPExchange`` sends its request
  /// with. Returns what `send` would and sets `errno` the same way.
  typealias SendDatagram = @Sendable (_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Int

  /// `recv(2)` of one datagram into `buffer`, in place of the system call a ``UDPExchange`` reads
  /// its reply with. Returns what `recv` would and sets `errno` the same way.
  typealias ReceiveDatagram =
    @Sendable (_ fd: Int32, _ buffer: UnsafeMutableRawBufferPointer) -> Int

  /// `connect(2)`, in place of the system call a DNS query connects its UDP socket to the server
  /// with. Returns what `connect` would and sets `errno` the same way.
  typealias ConnectSocket =
    @Sendable (_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32

  /// `sendto(2)` of one echo request to `destination`, in place of the system call a trace,
  /// stream or ping sends its probes with. Returns what `sendto` would and sets `errno` the same
  /// way. Captured when the operation is built, since a stream's retries and ping's sends run on
  /// dispatch queues.
  typealias SendProbe =
    @Sendable (
      _ fd: Int32, _ bytes: UnsafeRawBufferPointer, _ destination: UnsafePointer<sockaddr>,
      _ length: socklen_t
    ) -> Int

  /// Observes each read a trace, stream or ping makes from its probe socket: called with the
  /// descriptor and the read itself (`recvmsg` or `recvfrom`, unchanged), it must call `receive`
  /// exactly once and return its result with `errno` as `receive` left it. Captured when the
  /// operation is built, since the reads run on dispatch queues.
  typealias ObserveProbeReceive = @Sendable (_ fd: Int32, _ receive: () -> Int) -> Int

  /// `close(2)`, in place of the system call a ``UDPExchange`` closes its socket with. A substitute
  /// must close `fd` (or the test leaks it) and return what `close` would.
  typealias CloseDescriptor = @Sendable (_ fd: Int32) -> Int32

  /// Executor for every `runDetachedBlockingIO` call, in place of the process-wide one.
  @TaskLocal static var blockingIOExecutor: BlockingIOExecutor?

  @TaskLocal static var fileControl: FileControl?

  @TaskLocal static var sendDatagram: SendDatagram?

  @TaskLocal static var receiveDatagram: ReceiveDatagram?

  @TaskLocal static var closeDescriptor: CloseDescriptor?

  @TaskLocal static var connectSocket: ConnectSocket?

  /// `monotonicNow()` in place of the real clock, for a ``UDPExchange``'s decisions against its
  /// cutoff, so a test can move the clock past the cutoff (as a system sleep does) without sleeping.
  @TaskLocal static var monotonicClock: (@Sendable () -> TimeInterval)?

  /// UDP port every event-based DNS query sends to, in place of 53, so a query to a loopback
  /// literal reaches a test responder on an ephemeral port.
  @TaskLocal static var dnsServerPort: UInt16?

  @TaskLocal static var resolveHost: ResolveHost?

  /// The system DNS daemon calls a ``ReverseDNSLookup`` makes, in place of `dns_sd`.
  @TaskLocal static var dnsService: DNSServiceCalls?

  @TaskLocal static var makeICMPSocket: MakeICMPSocket?

  @TaskLocal static var sendProbe: SendProbe?

  @TaskLocal static var observeProbeReceive: ObserveProbeReceive?

  @TaskLocal static var discoverPublicIP: DiscoverPublicIP?

  /// The STUN servers a sweep of address family `family` tries, in place of the built-in list, so
  /// a test can point each family at loopback fixtures by numeric address.
  @TaskLocal static var stunServers: STUNServers?

  /// Resolves the names in a STUN sweep. A numeric server address is never passed to it.
  @TaskLocal static var resolveSTUNServer: ResolveSTUNServer?

  /// `send(2)` of a STUN sweep's binding request, in place of the system call, called with the
  /// request's own socket. Returns what `send` would and sets `errno` the same way. Captured by the
  /// sweep on the async side; ``sendDatagram`` does not apply to STUN.
  @TaskLocal static var sendSTUNRequest: SendDatagram?

  /// Arms the wake-up at a caller's public-IP resolver's deadline in place of a sleeping task, and
  /// returns the call that stops it. A test can leave the race unwoken, or wake it early.
  typealias ArmPublicIPDeadline =
    @Sendable (_ deadline: ContinuousClock.Instant, _ wake: @escaping @Sendable () -> Void) ->
    @Sendable () -> Void

  @TaskLocal static var armPublicIPDeadline: ArmPublicIPDeadline?
  /// Opens the socket a multipath run test-binds its source address on; -1 with `errno` set fails it.
  @TaskLocal static var validationSocket: (@Sendable () -> Int32)?

  /// Awaited by `discoverPaths` once it holds a topology, just before it checks for an
  /// invalidation and returns, so a test can order a network change before or after that step.
  @TaskLocal static var beforeMultipathCommit: (@Sendable () async -> Void)?

  /// Awaited by a `traceStream` producer once its trace has ended, just before it unregisters and
  /// finishes the stream, so a test can order `cancelActiveTraces()` before or after that step.
  @TaskLocal static var beforeStreamCommit: (@Sendable () async -> Void)?
}
