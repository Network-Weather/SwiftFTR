import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// One hop result in a traceroute.
public struct TraceHop: Sendable {
  /// Time-To-Live probed for this hop (1-based).
  public let ttl: Int
  /// Responder IPv4 or IPv6 address as a string. `nil` if timed out.
  public let ipAddress: String?
  /// Round-trip time in seconds for this hop, or `nil` if no reply.
  public let rtt: TimeInterval?
  /// Whether this reply came from the destination host.
  public let reachedDestination: Bool
  /// Hostname from reverse DNS lookup. `nil` if lookup disabled, failed, or timed out.
  public let hostname: String?
  /// What actually happened at this hop.
  ///
  /// Authoritative where the other fields are derived. In particular it separates a router that
  /// forwarded the probe onward from one that refused to route it — both of which report an
  /// address and a round-trip time — and separates a probe that was never sent from one that drew
  /// no answer, which otherwise look identical.
  public let outcome: HopOutcome

  /// Creates a hop, inferring ``outcome`` from the other fields.
  ///
  /// Retains the callable shape published before ``HopOutcome`` existed. A hop built this way
  /// reports ``HopOutcome/replied`` when it has an address and ``HopOutcome/timedOut`` when it does
  /// not; it never reports ``HopOutcome/unreachable(code:)`` or ``HopOutcome/notSent(errno:)``, which cannot be
  /// recovered from these fields. Prefer the initializer that takes an explicit outcome.
  public init(
    ttl: Int,
    ipAddress: String?,
    rtt: TimeInterval?,
    reachedDestination: Bool,
    hostname: String? = nil
  ) {
    self.init(
      ttl: ttl,
      ipAddress: ipAddress,
      rtt: rtt,
      reachedDestination: reachedDestination,
      hostname: hostname,
      outcome: ipAddress == nil ? .timedOut : .replied)
  }

  public init(
    ttl: Int,
    ipAddress: String?,
    rtt: TimeInterval?,
    reachedDestination: Bool,
    hostname: String? = nil,
    outcome: HopOutcome
  ) {
    self.ttl = ttl
    self.ipAddress = ipAddress
    self.rtt = rtt
    self.reachedDestination = reachedDestination
    self.hostname = hostname
    self.outcome = outcome
  }

}

/// Complete result of a traceroute run.
public struct TraceResult: Sendable {
  /// Destination hostname or IP string as provided by the caller.
  public let destination: String
  /// Numeric destination address used for this trace.
  ///
  /// This is the exact resolver result used to send the probes. It is `nil`
  /// only for results manually constructed without supplying an address.
  public let resolvedIP: String?
  /// Maximum TTL probed in this run.
  public let maxHops: Int
  /// Whether the destination responded.
  public let reached: Bool
  /// Per-hop results in order from TTL=1.
  public let hops: [TraceHop]
  /// Total wall-clock duration (seconds) measured for the trace.
  public let duration: TimeInterval

  /// Creates a trace result without a separately supplied resolved address.
  ///
  /// This initializer preserves the callable initializer shape published in SwiftFTR 0.13.
  /// Manually constructed results use `nil` for ``resolvedIP``.
  public init(
    destination: String,
    maxHops: Int,
    reached: Bool,
    hops: [TraceHop],
    duration: TimeInterval = 0
  ) {
    self.init(
      destination: destination,
      maxHops: maxHops,
      reached: reached,
      hops: hops,
      duration: duration,
      resolvedIP: nil
    )
  }

  /// Creates a trace result with the numeric address used for probing.
  public init(
    destination: String,
    maxHops: Int,
    reached: Bool,
    hops: [TraceHop],
    duration: TimeInterval = 0,
    resolvedIP: String?
  ) {
    self.destination = destination
    self.resolvedIP = resolvedIP
    self.maxHops = maxHops
    self.reached = reached
    self.hops = hops
    self.duration = duration
  }
}

/// Per-operation options for traceroute executions.
public struct TraceOptions: Sendable, Equatable {
  /// Maximum TTL/hops to probe for this trace.
  ///
  /// When `nil`, defaults to the configuration's `maxHops`.
  /// If specified, must be in the range `1...255`.
  public var maxHops: Int?

  public init(maxHops: Int? = nil) {
    self.maxHops = maxHops
  }
}

/// Origin of a dynamically seeded public IP address.
///
/// ``SwiftFTR/seedPublicIP(_:source:)`` requires the caller to state where a seeded address came
/// from, but does not retain the value: a seeded address is cached the same way whatever its
/// source, and the library exposes no way to read the source back. Whether to persist it and act
/// on the difference is an open question recorded in the lifecycle design document.
public enum PublicIPSource: Sendable, Equatable {
  /// Seeded from a validated caller-side cache or observation.
  case validatedCallerCache
  /// Reported by an upstream gateway (e.g. router WAN interface or NAT-PMP/PCP).
  case gatewayReported
}

/// Errors that can occur while performing a traceroute.
public enum TracerouteError: Error, CustomStringConvertible {
  /// DNS resolution failed for the destination host.
  case resolutionFailed(host: String, details: String?)
  /// Creating the socket failed; the associated errno is provided.
  case socketCreateFailed(errno: Int32, details: String)
  /// Setting a socket option failed (e.g., IP_TTL); associated option and errno are provided.
  case setsockoptFailed(option: String, errno: Int32)
  /// Binding to interface failed; interface name and errno are provided.
  case interfaceBindFailed(interface: String, errno: Int32, details: String?)
  /// Binding to source IP failed; IP address and errno are provided.
  case sourceIPBindFailed(sourceIP: String, errno: Int32, details: String?)
  /// Sending a probe failed; the associated errno is provided.
  case sendFailed(errno: Int32)
  /// Invalid configuration provided
  case invalidConfiguration(reason: String)
  /// Platform not supported
  case platformNotSupported(details: String)
  /// Trace was cancelled
  case cancelled

  public var description: String {
    switch self {
    case .resolutionFailed(let host, let details):
      return "Failed to resolve host '\(host)'" + (details.map { ": \($0)" } ?? "")
    case .socketCreateFailed(let errno, let details):
      return "socket() failed (errno=\(errno)): \(String(cString: strerror(errno))). \(details)"
    case .setsockoptFailed(let opt, let errno):
      return "setsockopt(\(opt)) failed (errno=\(errno)): \(String(cString: strerror(errno)))"
    case .interfaceBindFailed(let interface, let errno, let details):
      let errStr = String(cString: strerror(errno))
      let baseMsg = "Failed to bind to interface '\(interface)' (errno=\(errno)): \(errStr)"
      return details.map { "\(baseMsg). \($0)" } ?? baseMsg
    case .sourceIPBindFailed(let sourceIP, let errno, let details):
      let errStr = String(cString: strerror(errno))
      let baseMsg = "Failed to bind to source IP '\(sourceIP)' (errno=\(errno)): \(errStr)"
      return details.map { "\(baseMsg). \($0)" } ?? baseMsg
    case .sendFailed(let errno):
      return "sendto failed (errno=\(errno)): \(String(cString: strerror(errno)))"
    case .invalidConfiguration(let reason):
      return "Invalid configuration: \(reason)"
    case .platformNotSupported(let details):
      return "Platform not supported: \(details)"
    case .cancelled:
      return "Trace was cancelled"
    }
  }
}

/// Configuration options for SwiftFTR operations.
///
/// Values are retained by the initializer and validated when a throwing operation starts.
/// Invalid values fail with ``TracerouteError/invalidConfiguration(reason:)``.
///
/// ## What each tracer instance owns
///
/// `interface`, `sourceIP`, `publicIP` and `maxHops` are fixed per instance, so a host that
/// needs several binding contexts holds several `SwiftFTR` instances. Each instance owns its
/// reverse-DNS cache, its cached public address and its set of active traces. The ASN state is
/// shared across instances in the process: the local ASN database is loaded once per source and
/// the DNS lookup cache is process-wide, so extra instances cost neither another database load
/// nor another copy in memory.
public struct SwiftFTRConfig: Sendable {
  /// Default budget for public-IP discovery (STUN, with DNS fallback), in seconds.
  ///
  /// The per-socket timeouts inside discovery do not cover resolving each STUN hostname, and the
  /// server list is walked serially, so the enclosing call needs a bound of its own. Sized to admit
  /// a slow-but-working discovery while staying well below any plausible caller watchdog.
  public static let defaultPublicIPDiscoveryTimeout: TimeInterval = 6.0

  /// Default budget for a single reverse-DNS lookup, in seconds.
  ///
  /// Lookups run concurrently, so this bounds the reverse-DNS phase as a whole rather than being
  /// paid once per hop — which is why it can afford to be generous toward slow-but-working
  /// resolvers.
  public static let defaultRDNSLookupTimeout: TimeInterval = 5.0

  /// Maximum TTL/hops to probe (default: 40)
  public let maxHops: Int
  /// Maximum wait time per probe in milliseconds (default: 1000ms)
  public let maxWaitMs: Int
  /// Size in bytes of the Echo payload (default: 56)
  public let payloadSize: Int
  /// Authoritative public-address override for classified trace and multipath enrichment.
  ///
  /// When set, this is an immutable configuration override that permanently bypasses
  /// public-IP discovery for the lifetime of the actor. It is not a cache-seeding mechanism.
  /// To provide a known-valid public IP dynamically across network transitions without
  /// disabling discovery permanently, use ``SwiftFTR/seedPublicIP(_:source:)`` instead.
  ///
  /// The standalone ``getPublicIPs(stunTimeout:interface:sourceIP:enableLogging:)`` function
  /// and ``SwiftFTR/discoverPublicIPWithHostname()`` do not use this value.
  public let publicIP: String?
  /// Enable verbose logging for debugging
  public let enableLogging: Bool
  /// Disable reverse DNS lookups (default: false)
  public let noReverseDNS: Bool
  /// TTL for rDNS cache entries in seconds (default: 86400 = 1 day)
  public let rdnsCacheTTL: TimeInterval?
  /// Maximum rDNS cache size (default: 1000 entries)
  public let rdnsCacheSize: Int?
  /// How long a single reverse-DNS lookup may take before the trace gives up on it.
  ///
  /// Reverse DNS runs through `getnameinfo`, which consults the system resolver and has no timeout
  /// parameter of its own; an unanswered query holds it for 30 seconds. Hops whose lookup exceeds
  /// this budget report numerically instead. Lookups run concurrently, so this bounds the whole
  /// reverse-DNS phase rather than costing this much per hop.
  ///
  /// Raise it on links whose legitimate resolver latency is high. `nil` uses the default of 5s.
  public let rdnsLookupTimeout: TimeInterval?
  /// How long public-IP discovery (STUN, with DNS fallback) may take before the trace gives up.
  ///
  /// This bounds the whole discovery, including resolving each STUN hostname — which the
  /// per-socket timeouts inside discovery do not cover. Classification proceeds without a public
  /// address when it elapses. `nil` uses the default of 6s.
  public let publicIPDiscoveryTimeout: TimeInterval?
  /// Default BSD interface name for operations that support binding.
  /// If nil, those operations use system routing.
  public let interface: String?

  /// Default source IP address for operations that support binding.
  ///
  /// When specified, outgoing packets will use this IP as the source address.
  /// The IP must be assigned to the network interface (either globally configured
  /// via ``interface`` or per-operation).
  ///
  /// - Note: This is an advanced option. Most users should only set ``interface``.
  ///
  /// Example:
  /// ```swift
  /// func makeConfiguration(interfaceName: String, sourceIP: String) async -> SwiftFTRConfig? {
  ///   let snapshot = await NetworkInterfaceDiscovery().discover()
  ///   guard let selectedInterface = snapshot.interface(named: interfaceName),
  ///     selectedInterface.isUp,
  ///     selectedInterface.ipv4Addresses.contains(sourceIP)
  ///       || selectedInterface.ipv6Addresses.contains(sourceIP)
  ///   else { return nil }
  ///
  ///   let preferredFamily: PreferredFamily =
  ///     selectedInterface.ipv4Addresses.contains(sourceIP) ? .v4 : .v6
  ///   let config = SwiftFTRConfig(
  ///     interface: selectedInterface.name,
  ///     sourceIP: sourceIP,
  ///     preferredFamily: preferredFamily
  ///   )
  ///   return config
  /// }
  /// ```
  public let sourceIP: String?

  /// ASN resolver strategy for trace classification.
  ///
  /// Controls how IP-to-ASN lookups are performed during `traceClassified()`.
  ///
  /// Options:
  /// - `.hybrid(source, fallbackTimeout:)`: **Default.** Local database first, DNS only for
  ///   addresses it does not cover. Removes the network from the common path, which matters
  ///   because a caller that discards caches on a network change re-pays the cold path every
  ///   time — and a cold DNS lookup against an unresponsive resolver stalls for 30 seconds.
  ///   Loads the embedded database; see `.embedded` for what that costs.
  /// - `.dns`: DNS-based lookups via Team Cymru. No memory cost, but every uncached address is a
  ///   network round trip, and enrichment is only as reliable as the resolver.
  /// - `.embedded`: Local database only (~10μs lookups). No network at any point; an address the
  ///   database does not cover simply has no ASN. The database is loaded once per process and
  ///   shared, so it costs about 15 MB however many tracers exist.
  /// - `.remote(bundledPath:url:)`: Remote database with optional offline fallback
  ///
  /// Example:
  /// ```swift
  /// // Use local database for offline operation
  /// let config = SwiftFTRConfig(asnResolverStrategy: .embedded)
  ///
  /// // Bundle database with auto-updates (recommended for apps)
  /// let config = SwiftFTRConfig(asnResolverStrategy: .remote(
  ///     bundledPath: Bundle.main.path(forResource: "ip2asn", ofType: "ultra")
  /// ))
  /// ```
  public let asnResolverStrategy: ASNResolverStrategy

  /// IP family preference for resolution & traceroute. Defaults to `.auto`
  /// (let the resolved address decide). Mirrors `PingConfig.preferredFamily`
  /// added in Stage 1. See [docs/IPV6.md](../../docs/IPV6.md).
  public let preferredFamily: PreferredFamily

  /// Creates a new SwiftFTR configuration.
  ///
  /// - Parameters:
  ///   - maxHops: Maximum TTL/hops to probe (default: 40)
  ///   - maxWaitMs: Maximum wait time per probe in milliseconds (default: 1000ms)
  ///   - payloadSize: Size in bytes of the Echo payload (default: 56)
  ///   - publicIP: Public-address override for classified trace and multipath enrichment. It does
  ///     not affect the standalone public-IP discovery APIs.
  ///   - enableLogging: Enable verbose logging for debugging
  ///   - noReverseDNS: Disable reverse DNS lookups (default: false)
  ///   - rdnsCacheTTL: TTL for rDNS cache entries in seconds (default: 86400 = 1 day)
  ///   - rdnsCacheSize: Maximum rDNS cache size (default: 1000 entries)
  ///   - rdnsLookupTimeout: Per-lookup reverse-DNS budget in seconds (default: 5). Bounds the
  ///     reverse-DNS phase as a whole, since lookups run concurrently.
  ///   - publicIPDiscoveryTimeout: Budget for public-IP discovery in seconds (default: 6)
  ///   - interface: BSD interface name returned by ``NetworkInterfaceDiscovery``. If nil, uses system routing.
  ///   - sourceIP: Source address reported on the selected interface. It must match the
  ///     destination family. If nil, the system chooses an address.
  ///   - asnResolverStrategy: Strategy for ASN lookups during classification
  ///     (default: `.hybrid(.embedded)`)
  ///   - preferredFamily: IP family preference for resolution (default: .auto)
  public init(
    maxHops: Int = 40,
    maxWaitMs: Int = 1000,
    payloadSize: Int = 56,
    publicIP: String? = nil,
    enableLogging: Bool = false,
    noReverseDNS: Bool = false,
    rdnsCacheTTL: TimeInterval? = nil,
    rdnsCacheSize: Int? = nil,
    rdnsLookupTimeout: TimeInterval? = nil,
    publicIPDiscoveryTimeout: TimeInterval? = nil,
    interface: String? = nil,
    sourceIP: String? = nil,
    asnResolverStrategy: ASNResolverStrategy = .hybrid(.embedded),
    preferredFamily: PreferredFamily = .auto
  ) {
    self.maxHops = maxHops
    self.maxWaitMs = maxWaitMs
    self.payloadSize = payloadSize
    self.publicIP = publicIP
    self.enableLogging = enableLogging
    self.noReverseDNS = noReverseDNS
    self.rdnsCacheTTL = rdnsCacheTTL
    self.rdnsCacheSize = rdnsCacheSize
    self.rdnsLookupTimeout = rdnsLookupTimeout
    self.publicIPDiscoveryTimeout = publicIPDiscoveryTimeout
    self.interface = interface
    self.sourceIP = sourceIP
    self.asnResolverStrategy = asnResolverStrategy
    self.preferredFamily = preferredFamily
  }
}

/// Top-level entry point for performing fast, parallel traceroutes.
///
/// SwiftFTR is an actor providing thread-safe traceroute operations with
/// built-in caching for rDNS lookups and public-address enrichment of classified traces.
@available(macOS 13.0, *)
public actor SwiftFTR {
  internal nonisolated let config: SwiftFTRConfig

  // Cache storage
  internal var cachedPublicIP: String?
  private var cacheGeneration: UInt64 = 0
  internal let rdnsCache: RDNSCache
  internal let asnResolver: ASNResolver

  // Active trace tracking
  internal var activeTraces: Set<TraceHandle> = []

  /// DNS query interface
  ///
  /// Provides access to DNS queries for various record types (A, AAAA, PTR, TXT, etc.)
  /// with high-precision timing and detailed metadata.
  ///
  /// Example:
  /// ```swift
  /// let tracer = SwiftFTR()
  /// let result = try await tracer.dns.a(hostname: "example.com")
  /// print("IP: \(result.records.first?.data)")
  /// print("RTT: \(result.rttMs)ms")
  /// ```
  public nonisolated var dns: DNSQueries {
    DNSQueries(tracer: self)
  }

  /// Creates a tracer instance with optional configuration.
  /// - Parameter config: Configuration for traceroute behavior
  public init(config: SwiftFTRConfig = SwiftFTRConfig()) {
    self.config = config
    self.rdnsCache = RDNSCache(
      ttl: config.cacheTTLForConstruction,
      maxSize: config.cacheSizeForConstruction,
      lookupDeadline: config.rdnsLookupTimeoutForConstruction
    )
    self.asnResolver = Self.createResolver(for: config.asnResolverStrategy)
  }

  /// Creates an ASN resolver based on the configured strategy.
  private static func createResolver(for strategy: ASNResolverStrategy) -> ASNResolver {
    switch strategy {
    case .dns:
      return CachingASNResolver(base: CymruDNSResolver())
    case .embedded:
      return LocalASNResolver(source: .embedded)
    case .remote(let bundledPath, let url):
      return LocalASNResolver(source: .remote(bundledPath: bundledPath, url: url))
    case .hybrid(let source, let fallbackTimeout):
      return HybridASNResolver(source: source, fallbackTimeout: fallbackTimeout)
    }
  }

  /// Preload the ASN database for faster first classification.
  ///
  /// Only relevant when using `.embedded`, `.remote`, or `.hybrid` strategies.
  /// Call this early in your app lifecycle to move the database load, tens of milliseconds
  /// for the embedded database, off the first `traceClassified()` call.
  ///
  /// The database is shared: every tracer in the process built for the same source reads one
  /// copy, so preloading through one instance also serves the others while it stays alive. The
  /// copy is released when the last tracer using it goes away.
  ///
  /// Example:
  /// ```swift
  /// let tracer = SwiftFTR(config: SwiftFTRConfig(asnResolverStrategy: .embedded))
  /// await tracer.preloadASNDatabase()  // Load database now
  /// // ... later, classification is instant
  /// let trace = try await tracer.traceClassified(to: "example.com")
  /// ```
  public func preloadASNDatabase() async {
    if let local = asnResolver as? LocalASNResolver {
      await local.preload()
    } else if let hybrid = asnResolver as? HybridASNResolver {
      await hybrid.preload()
    }
  }

  /// Internal initializer used to spin up lightweight worker instances that share caches.
  internal init(
    config: SwiftFTRConfig,
    rdnsCache: RDNSCache,
    asnResolver: ASNResolver,
    cachedPublicIP: String?
  ) {
    self.config = config
    self.rdnsCache = rdnsCache
    self.asnResolver = asnResolver
    self.cachedPublicIP = cachedPublicIP
  }

  /// Perform a fast traceroute by sending one ICMP Echo per TTL and waiting once.
  ///
  /// This method supports cancellation via network changes and includes optional
  /// reverse DNS lookups based on configuration.
  /// - Parameters:
  ///   - host: Destination hostname or IPv4/IPv6 address.
  /// - Returns: A `TraceResult` with ordered hops and whether the destination responded.
  /// - Throws: `CancellationError` when the calling task is cancelled,
  ///   `TracerouteError.cancelled` when ``networkChanged()`` or ``cancelActiveTraces()`` ends it
  ///   (also when the caller cancelled too), or another `TracerouteError` if resolution or socket
  ///   operations fail.
  public func trace(
    to host: String
  ) async throws -> TraceResult {
    try await trace(to: host, options: .init())
  }

  /// Perform a fast traceroute with per-operation options.
  ///
  /// - Parameters:
  ///   - host: Destination hostname or IPv4/IPv6 address.
  ///   - options: Per-operation trace options such as `maxHops` override.
  /// - Returns: A `TraceResult` with ordered hops and whether the destination responded.
  /// - Throws: `CancellationError` when the calling task is cancelled,
  ///   `TracerouteError.cancelled` when ``networkChanged()`` or ``cancelActiveTraces()`` ends it
  ///   (also when the caller cancelled too), or another `TracerouteError` if resolution or socket
  ///   operations fail.
  public func trace(
    to host: String,
    options: TraceOptions
  ) async throws -> TraceResult {
    try options.validateForOperation()
    let handle = TraceHandle()

    // Register active trace
    activeTraces.insert(handle)
    defer { activeTraces.remove(handle) }

    do {
      return try await withTaskCancellationHandler {
        try await performTrace(to: host, handle: handle, maxHopsOverride: options.maxHops)
      } onCancel: {
        handle.cancel(for: .callerTask)
      }
    } catch {
      // Reported here, on the actor that `cancelActiveTraces()` runs on, so a tracer cancellation
      // that arrived after the caller's but before this point is the one reported.
      throw handle.reportedError(for: error)
    }
  }

  // MARK: - Streaming Traceroute

  /// Perform a streaming traceroute, emitting hops as ICMP responses arrive.
  ///
  /// Returns an `AsyncThrowingStream` that yields `StreamingHop` values as responses
  /// are received. Hops are emitted in arrival order (not TTL order) for minimum latency.
  /// The caller is responsible for sorting by TTL if needed and for enriching with rDNS/ASN.
  ///
  /// The streaming trace uses a retry strategy for unresponsive hops:
  /// - Sends initial probes to all TTLs immediately
  /// - After `retryAfter` seconds (default 4s), re-probes any TTLs before the destination
  ///   that haven't responded (helps with rate-limited routers or packet loss)
  /// - Completes after `probeTimeout` (default 10s) or when destination + all earlier hops resolve
  ///
  /// Example:
  /// ```swift
  /// let tracer = SwiftFTR()
  /// for try await hop in tracer.traceStream(to: "1.1.1.1") {
  ///     print("TTL \(hop.ttl): \(hop.ipAddress ?? "*")")
  /// }
  /// ```
  ///
  /// ``networkChanged()`` and ``cancelActiveTraces()`` end a stream that has not finished with
  /// `TracerouteError.cancelled`. A consumer that cancels its own task sees iteration end
  /// normally, as with any `AsyncSequence`: `next()` returns `nil` rather than throwing.
  ///
  /// The trace stops probing and closes its socket when the stream terminates: when the task
  /// iterating it is cancelled, or when the stream and its iterator are released. Breaking out of
  /// a `for try await` loop written inline over `traceStream(...)` releases the stream and so stops
  /// the trace. Breaking out of a loop over a stream held in a variable does not: the trace keeps
  /// its socket open and keeps re-probing until it finishes or the stream is released.
  ///
  /// - Parameters:
  ///   - host: Destination hostname or IPv4/IPv6 address.
  ///   - streamConfig: Configuration for streaming behavior (timeouts, retry, etc.)
  /// - Returns: An `AsyncThrowingStream<StreamingHop, Error>` yielding hops as they arrive.
  public nonisolated func traceStream(
    to host: String,
    config streamConfig: StreamingTraceConfig = .default
  ) -> AsyncThrowingStream<StreamingHop, Error> {
    AsyncThrowingStream { continuation in
      let handle = TraceHandle()

      let producerTask = Task { [self] in
        guard !Task.isCancelled else { return }

        // Register active trace
        await self.registerActiveTrace(handle)

        var failure: Error?
        do {
          try await self.performStreamingTrace(
            to: host,
            handle: handle,
            streamConfig: streamConfig,
            yield: { hop in
              switch continuation.yield(hop) {
              case .enqueued, .dropped:
                return true
              case .terminated:
                return false
              @unknown default:
                return false
              }
            }
          )
        } catch {
          failure = error
        }
        if let beforeCommit = TestSeams.beforeStreamCommit { await beforeCommit() }
        await self.commitStream(handle: handle, failure: failure, to: continuation)
      }

      continuation.onTermination = { @Sendable termination in
        if case .cancelled = termination {
          // Recorded before the producer can fail, so it finishes the stream normally.
          handle.cancel(for: .callerTask)
        }
        producerTask.cancel()
      }
    }
  }

  /// Register an active trace handle for cancellation tracking.
  private func registerActiveTrace(_ handle: TraceHandle) {
    activeTraces.insert(handle)
  }

  /// Ends a stream: decides its outcome, unregisters it and finishes it in one step on this actor,
  /// with no suspension. `cancelActiveTraces()` withdraws a handle in the same kind of step before
  /// it cancels it, so a handle that is no longer registered means the tracer ended this stream
  /// before it finished: the tracer's cancellation is reported, whatever the producer's outcome.
  /// A stream whose consumer cancelled has already ended for that consumer and finishes normally.
  private func commitStream(
    handle: TraceHandle,
    failure: Error?,
    to continuation: AsyncThrowingStream<StreamingHop, Error>.Continuation
  ) {
    let withdrawn = activeTraces.remove(handle) == nil
    if handle.cancelState.reason == .callerTask {
      continuation.finish()
    } else if withdrawn {
      continuation.finish(throwing: TracerouteError.cancelled)
    } else if let failure {
      continuation.finish(throwing: handle.reportedError(for: failure))
    } else {
      continuation.finish()
    }
  }

  /// Internal implementation of streaming trace with two-phase timeout.
  internal func performStreamingTrace(
    to host: String,
    handle: TraceHandle,
    streamConfig: StreamingTraceConfig,
    yield: @Sendable @escaping (StreamingHop) -> Bool
  ) async throws {
    try handle.checkCancellation()
    try config.validateForOperation()
    try streamConfig.validateForOperation()

    let maxHops = streamConfig.maxHops
    let payloadSize = config.payloadSize

    // Validate interface early if specified
    var interfaceIndex: UInt32? = nil
    if let interfaceName = config.interface {
      if config.enableLogging {
        print("[SwiftFTR] Validating interface '\(interfaceName)' for streaming trace...")
      }
      interfaceIndex = try validateInterface(interfaceName)
    }

    // Resolve destination (dual-stack, honors config.preferredFamily).
    let resolved = try resolveHost(host: host, prefer: config.preferredFamily)

    try handle.checkCancellation()

    if let sourceIP = config.sourceIP {
      try validateSourceIPFamily(sourceIP, destinationFamily: resolved.family)
    }

    let fd = try createTraceSocket(family: resolved.family, enableLogging: config.enableLogging)
    // Closed here until the receive operation exists; from then on it closes the descriptor from
    // its read source's cancel handler.
    var receiveOwnsSocket = false
    defer { if !receiveOwnsSocket { close(fd) } }

    if let ifIndex = interfaceIndex {
      try bindTraceInterface(
        sockfd: fd, family: resolved.family,
        interfaceName: config.interface ?? "<unknown>", ifIndex: ifIndex,
        enableLogging: config.enableLogging)
    }

    if let sourceIP = config.sourceIP {
      try bindTraceSourceIP(
        sockfd: fd, family: resolved.family, sourceIP: sourceIP,
        enableLogging: config.enableLogging)
    }

    try setProbeSocketNonBlocking(fd)

    if resolved.family == AF_INET {
      var on: Int32 = 1
      _ = setsockopt(fd, IPPROTO_IP, IP_RECVTTL, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    let identifier = UInt16.random(in: 0...UInt16.max)
    var outstanding: [UInt16: TraceSendInfo] = [:]

    if config.enableLogging {
      print("[SwiftFTR] Streaming trace: sending \(maxHops) probes...")
    }
    let sendRetryDeadline = monotonicNow() + traceBurstSendRetryBudget
    let sendProbe = TestSeams.sendProbe
    let unsentTTLs = try sendTraceBurst(
      sockfd: fd, resolved: resolved, identifier: identifier, maxHops: maxHops,
      payloadSize: payloadSize, retryDeadline: sendRetryDeadline, sendProbe: sendProbe,
      outstanding: &outstanding)

    // Collect responses via DispatchSourceRead with retry support.
    if config.enableLogging {
      print(
        "[SwiftFTR] Streaming trace: timeout \(streamConfig.probeTimeout)s, retry after \(streamConfig.retryAfter.map { "\($0)s" } ?? "disabled")"
      )
    }

    // Probes that never left the host are known now, not at the deadline, so report them
    // immediately. A consumer that sees only the hops that answered cannot tell a router that
    // ignored us from a probe we never sent.
    for ttl in unsentTTLs.keys.sorted() {
      guard let code = unsentTTLs[ttl] else { continue }
      if !yield(
        StreamingHop(
          ttl: ttl, ipAddress: nil, rtt: nil, reachedDestination: false,
          outcome: .notSent(errno: code)))
      {
        return
      }
    }

    let streamOperation = StreamingTraceReceiveOperation(
      sockfd: fd,
      family: resolved.family,
      identifier: identifier,
      outstanding: outstanding,
      maxHops: maxHops,
      payloadSize: payloadSize,
      resolved: resolved,
      streamConfig: streamConfig,
      enableLogging: config.enableLogging,
      sendProbe: sendProbe,
      yield: yield
    )
    receiveOwnsSocket = true

    let registrationID = await handle.installCancellationHandler { streamOperation.cancel() }
    do {
      try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation {
          (continuation: CheckedContinuation<Void, Error>) in
          streamOperation.start(continuation: continuation)
        }
      } onCancel: {
        streamOperation.cancel()
      }
      await handle.clearCancellationHandler(id: registrationID)
    } catch {
      await handle.clearCancellationHandler(id: registrationID)
      throw handle.reportedError(for: error)
    }

    if let cancellation = handle.cancellationError() {
      streamOperation.cancel()
      throw cancellation
    }
  }

  // Validate network interface exists and is available
  internal func validateInterface(_ interfaceName: String) throws -> UInt32 {
    #if os(macOS)
      let ifIndex = if_nametoindex(interfaceName)
      if ifIndex == 0 {
        let error = errno
        let details =
          "Interface '\(interfaceName)' not found. Common causes: (1) Interface doesn't exist, (2) Interface is down, (3) Typo in interface name. Use 'ifconfig' to list available interfaces."
        throw TracerouteError.interfaceBindFailed(
          interface: interfaceName, errno: error, details: details)
      }
      return ifIndex
    #else
      let error = ENOTSUP
      let details =
        "Interface binding is currently only supported on macOS. Linux support requires SO_BINDTODEVICE with CAP_NET_RAW capability."
      throw TracerouteError.interfaceBindFailed(
        interface: interfaceName, errno: error, details: details)
    #endif
  }

  // Internal implementation of trace with cancellation support
  internal func performTrace(
    to host: String,
    handle: TraceHandle,
    flowIdentifier: UInt16? = nil,
    maxHopsOverride: Int? = nil
  ) async throws -> TraceResult {
    try config.validateForOperation()

    let maxHops = maxHopsOverride ?? config.maxHops
    let timeout = TimeInterval(config.maxWaitMs) / 1000.0
    let payloadSize = config.payloadSize

    // Validate interface early if specified
    var interfaceIndex: UInt32? = nil
    if let interfaceName = config.interface {
      if config.enableLogging {
        print("[SwiftFTR] Validating interface '\(interfaceName)'...")
      }
      interfaceIndex = try validateInterface(interfaceName)
      if config.enableLogging {
        print(
          "[SwiftFTR] Interface '\(interfaceName)' validated successfully (index: \(interfaceIndex!))"
        )
      }
    }

    if config.enableLogging {
      print(
        "[SwiftFTR] Starting trace to \(host) with maxHops=\(maxHops), timeout=\(timeout)s, payloadSize=\(payloadSize)"
      )
    }
    // Resolve host (dual-stack, honors config.preferredFamily).
    let resolved = try resolveHost(host: host, prefer: config.preferredFamily)
    if config.enableLogging {
      let famName = resolved.family == AF_INET6 ? "v6" : "v4"
      print("[SwiftFTR] Resolved \(host) → \(resolved.canonical) (\(famName))")
    }

    if let sourceIP = config.sourceIP {
      try validateSourceIPFamily(sourceIP, destinationFamily: resolved.family)
    }

    let fd = try createTraceSocket(family: resolved.family, enableLogging: config.enableLogging)
    // Closed here until the receive operation exists; from then on it closes the descriptor from
    // its read source's cancel handler.
    var receiveOwnsSocket = false
    defer { if !receiveOwnsSocket { close(fd) } }

    if let interfaceName = config.interface, let ifIndex = interfaceIndex {
      try bindTraceInterface(
        sockfd: fd, family: resolved.family, interfaceName: interfaceName,
        ifIndex: ifIndex, enableLogging: config.enableLogging)
    }

    if let sourceIP = config.sourceIP {
      try bindTraceSourceIP(
        sockfd: fd, family: resolved.family, sourceIP: sourceIP,
        enableLogging: config.enableLogging)
    }

    try setProbeSocketNonBlocking(fd)

    // Best-effort IP_RECVTTL for v4 (v6 already enabled IPV6_RECVHOPLIMIT in createTraceSocket).
    if resolved.family == AF_INET {
      var on: Int32 = 1
      _ = setsockopt(fd, IPPROTO_IP, IP_RECVTTL, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    let identifier = flowIdentifier ?? UInt16.random(in: 0...UInt16.max)
    var outstanding: [UInt16: TraceSendInfo] = [:]  // key = sequence (== ttl)

    if config.enableLogging {
      print("[SwiftFTR] Sending \(maxHops) probes...")
    }
    let sendRetryDeadline = monotonicNow() + traceBurstSendRetryBudget
    let unsentTTLs = try sendTraceBurst(
      sockfd: fd, resolved: resolved, identifier: identifier, maxHops: maxHops,
      payloadSize: payloadSize, retryDeadline: sendRetryDeadline,
      sendProbe: TestSeams.sendProbe, outstanding: &outstanding)

    // Collect responses via DispatchSourceRead (kqueue-backed on macOS).
    // All probes are already in-flight; we wait for responses until the deadline
    // or until all hops up to the destination are filled.
    let startWall = Date()

    if config.enableLogging {
      print("[SwiftFTR] Entering receive loop, deadline in \(timeout)s...")
    }

    let operation = TraceReceiveOperation(
      sockfd: fd,
      family: resolved.family,
      identifier: identifier,
      outstanding: outstanding,
      maxHops: maxHops,
      timeout: timeout,
      destinationIP: resolved.canonical,
      enableLogging: config.enableLogging
    )
    receiveOwnsSocket = true

    let registrationID = await handle.installCancellationHandler { operation.cancel() }
    let receiveResult: TraceReceiveResult
    do {
      receiveResult = try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
          operation.start(continuation: continuation)
        }
      } onCancel: {
        operation.cancel()
      }
      await handle.clearCancellationHandler(id: registrationID)
    } catch {
      await handle.clearCancellationHandler(id: registrationID)
      throw handle.reportedError(for: error)
    }

    if let cancellation = handle.cancellationError() {
      operation.cancel()
      throw cancellation
    }

    var hops = receiveResult.hops
    let reachedTTL = receiveResult.reachedTTL

    // Finalize hops up to reachedTTL (or max). A TTL whose probe never left the host is reported
    // as such rather than as a timeout: both render without an address, but only one of them means
    // the network stayed silent.
    let cutoff = reachedTTL ?? maxHops
    for ttl in 1...cutoff {
      let idx = ttl - 1
      if hops[idx] == nil {
        hops[idx] = TraceHop(
          ttl: ttl, ipAddress: nil, rtt: nil, reachedDestination: false,
          outcome: unsentTTLs[ttl].map { .notSent(errno: $0) } ?? .timedOut)
      }
    }

    var finalHops = Array(hops[0..<(reachedTTL ?? maxHops)]).compactMap { $0 }

    // Perform rDNS lookups if enabled
    if !config.noReverseDNS {
      let ips = finalHops.compactMap { $0.ipAddress }
      // Raced against the handle like every other enrichment phase, so a network change ends the
      // trace now rather than after the slowest lookup's deadline.
      let hostnames = try await withTraceCancellation(handle: handle) {
        await self.rdnsCache.batchLookup(ips)
      }

      try handle.checkCancellation()

      finalHops = finalHops.map { hop in
        TraceHop(
          ttl: hop.ttl,
          ipAddress: hop.ipAddress,
          rtt: hop.rtt,
          reachedDestination: hop.reachedDestination,
          hostname: hop.ipAddress.flatMap { hostnames[$0] },
          outcome: hop.outcome
        )
      }
    }

    let result = TraceResult(
      destination: host,
      maxHops: maxHops,
      reached: reachedTTL != nil,
      hops: finalHops,
      duration: Date().timeIntervalSince(startWall),
      resolvedIP: resolved.canonical
    )
    return result
  }

  /// Perform a traceroute and enrich results with ASN-based categorization.
  ///
  /// This variant obtains the client's public address from configuration, the actor cache, or fresh
  /// IPv4 discovery (STUN followed by DNS fallback). It resolves origin ASNs for relevant IP
  /// addresses using the provided resolver and labels
  /// each hop as LOCAL, ISP, TRANSIT, or DESTINATION. Missing stretches between
  /// identical segments are interpolated for readability.
  ///
  /// When tracing through a VPN interface (utun*, ipsec*, etc.), the classification will
  /// automatically detect the VPN context and properly classify VPN hops:
  /// - CGNAT addresses (100.64.0.0/10) → VPN (not ISP)
  /// - Private addresses after VPN hop → VPN (exit node's network)
  ///
  /// You can also provide an explicit `VPNContext` for more control.
  ///
  /// - Parameters:
  ///   - host: Destination hostname or IPv4/IPv6 address.
  ///   - vpnContext: Context for VPN-aware classification (optional, auto-detected from interface).
  ///   - resolver: ASN resolver implementation (default: uses internal cached resolver).
  /// - Returns: A ClassifiedTrace containing segment labels and (when available) ASN info.
  /// - Throws: `CancellationError` when the calling task is cancelled,
  ///   `TracerouteError.cancelled` when ``networkChanged()`` or ``cancelActiveTraces()`` ends it
  ///   (also when the caller cancelled too), or another `TracerouteError` if resolution or socket
  ///   operations fail.
  public func traceClassified(
    to host: String,
    vpnContext: VPNContext? = nil,
    resolver: ASNResolver? = nil
  ) async throws -> ClassifiedTrace {
    try await traceClassified(
      to: host, vpnContext: vpnContext, resolver: resolver, options: .init())
  }

  /// Perform a classified traceroute with per-operation options.
  ///
  /// - Parameters:
  ///   - host: Destination hostname or IPv4/IPv6 address.
  ///   - vpnContext: Context for VPN-aware classification (optional, auto-detected from interface).
  ///   - resolver: ASN resolver implementation (default: uses internal cached resolver).
  ///   - options: Per-operation trace options such as `maxHops` override.
  /// - Returns: A ClassifiedTrace containing segment labels and (when available) ASN info.
  /// - Throws: `CancellationError` when the calling task is cancelled,
  ///   `TracerouteError.cancelled` when ``networkChanged()`` or ``cancelActiveTraces()`` ends it
  ///   (also when the caller cancelled too), or another `TracerouteError` if resolution or socket
  ///   operations fail.
  public func traceClassified(
    to host: String,
    vpnContext: VPNContext? = nil,
    resolver: ASNResolver? = nil,
    options: TraceOptions
  ) async throws -> ClassifiedTrace {
    try config.validateForOperation()
    try options.validateForOperation()

    let handle = TraceHandle()
    activeTraces.insert(handle)
    defer { activeTraces.remove(handle) }

    do {
      return try await classifiedTrace(
        to: host, vpnContext: vpnContext, resolver: resolver, options: options, handle: handle)
    } catch {
      // Reported here, on the actor that `cancelActiveTraces()` runs on, so a tracer cancellation
      // that arrived after the caller's but before this point is the one reported.
      throw handle.reportedError(for: error)
    }
  }

  private func classifiedTrace(
    to host: String,
    vpnContext: VPNContext?,
    resolver: ASNResolver?,
    options: TraceOptions,
    handle: TraceHandle
  ) async throws -> ClassifiedTrace {
    try await withTaskCancellationHandler {
      // Validate interface early if specified (before any network operations)
      if let interfaceName = config.interface {
        if config.enableLogging {
          print("[SwiftFTR] Validating interface '\(interfaceName)' for classified trace...")
        }
        _ = try validateInterface(interfaceName)
        if config.enableLogging {
          print("[SwiftFTR] Interface '\(interfaceName)' validated successfully")
        }
      }

      try handle.checkCancellation()

      let effectivePublicIP = await effectivePublicIPForClassification {
        if handle.cancellationError() != nil { return nil }
        return try? await self.discoverPublicIP(handle: handle)
      }

      try handle.checkCancellation()

      // Perform base trace using the classified trace's handle
      let tr = try await performTrace(to: host, handle: handle, maxHopsOverride: options.maxHops)

      guard let destIP = tr.resolvedIP else {
        throw TracerouteError.resolutionFailed(
          host: host, details: "Trace completed without a resolved destination address")
      }

      // Collect IPs for batch operations
      var allIPs = Set(tr.hops.compactMap { $0.ipAddress })
      allIPs.insert(destIP)
      if let pip = effectivePublicIP { allIPs.insert(pip) }

      try handle.checkCancellation()

      // Get hostnames (either from trace or via rDNS)
      var hostnameMap: [String: String] = [:]
      if !config.noReverseDNS {
        // Get any missing hostnames (destination and public IP)
        let ipsNeedingRDNS = allIPs.filter { ip in
          !tr.hops.contains { $0.ipAddress == ip && $0.hostname != nil }
        }
        if !ipsNeedingRDNS.isEmpty {
          try handle.checkCancellation()
          let additionalHostnames = try await withTraceCancellation(handle: handle) {
            await self.rdnsCache.batchLookup(Array(ipsNeedingRDNS))
          }
          try handle.checkCancellation()
          hostnameMap = additionalHostnames
        }

        // Add hostnames from trace
        for hop in tr.hops {
          if let ip = hop.ipAddress, let hostname = hop.hostname {
            hostnameMap[ip] = hostname
          }
        }
      }

      try handle.checkCancellation()

      // Use provided resolver or internal one
      let effectiveResolver = resolver ?? asnResolver

      // Determine VPN context - use provided or auto-detect from interface
      let effectiveVPNContext = vpnContext ?? VPNContext.forInterface(config.interface)

      // Classify with enhanced data
      let classifier = TraceClassifier()
      let baseClassified = try await withTraceCancellation(handle: handle) {
        try await classifier.classify(
          trace: tr,
          destinationIP: destIP,
          resolver: effectiveResolver,
          timeout: 1.5,
          publicIP: effectivePublicIP,
          interface: self.config.interface,
          sourceIP: self.config.sourceIP,
          vpnContext: effectiveVPNContext,
          enableLogging: self.config.enableLogging,
          publicIPDiscoveryTimeout: self.config.publicIPDiscoveryTimeoutForOperation
        )
      }

      try handle.checkCancellation()

      // Enhance classified result with hostnames
      let enhancedHops = baseClassified.hops.map { hop in
        ClassifiedHop(
          ttl: hop.ttl,
          ip: hop.ip,
          rtt: hop.rtt,
          asn: hop.asn,
          asName: hop.asName,
          category: hop.category,
          hostname: hop.ip.flatMap {
            hostnameMap[$0] ?? tr.hops.first { $0.ipAddress == hop.ip }?.hostname
          },
          outcome: hop.outcome
        )
      }

      return ClassifiedTrace(
        destinationHost: baseClassified.destinationHost,
        destinationIP: baseClassified.destinationIP,
        destinationHostname: hostnameMap[destIP],
        publicIP: baseClassified.publicIP,
        publicHostname: effectivePublicIP.flatMap { hostnameMap[$0] },
        clientASN: baseClassified.clientASN,
        clientASName: baseClassified.clientASName,
        destinationASN: baseClassified.destinationASN,
        destinationASName: baseClassified.destinationASName,
        hops: enhancedHops
      )
    } onCancel: {
      handle.cancel(for: .callerTask)
    }
  }

  /// Ping a target host with specified configuration.
  ///
  /// Sends ICMP Echo Request packets and measures round-trip time, packet loss, and jitter.
  /// This method is more efficient than traceroute for monitoring known hops, as it sends
  /// direct echo requests rather than probing every TTL.
  ///
  /// **Nonisolated for parallelism**: Multiple concurrent calls run in parallel, not serially.
  /// Each ping operation uses its own socket and executor, enabling true concurrent execution.
  ///
  /// - Parameters:
  ///   - target: Hostname or IP address to ping
  ///   - config: Ping configuration (count, interval, timeout, payload size)
  /// - Returns: Ping result with response data and computed statistics
  /// - Throws: `CancellationError` when the calling task is cancelled, or `TracerouteError` on
  ///   failure (resolution, socket creation, permission issues). A ping is not ended by
  ///   ``networkChanged()`` or ``cancelActiveTraces()``.
  ///
  /// ## Example
  /// ```swift
  /// let tracer = SwiftFTR(config: SwiftFTRConfig())
  ///
  /// // Concurrent pings run in parallel
  /// async let ping1 = tracer.ping(to: "1.1.1.1")
  /// async let ping2 = tracer.ping(to: "8.8.8.8")
  /// let (result1, result2) = try await (ping1, ping2)
  /// ```
  #if compiler(>=6.2)
    @concurrent
  #endif
  public nonisolated func ping(
    to target: String,
    config: PingConfig = PingConfig()
  ) async throws -> PingResult {
    let executor = PingExecutor(config: self.config)
    return try await executor.ping(to: target, config: config)
  }

  /// Test for bufferbloat / network responsiveness under load
  ///
  /// This test measures latency-under-load to detect bufferbloat, which causes
  /// video calls to freeze when the network is busy. The test:
  /// 1. Measures baseline latency (idle network)
  /// 2. Generates saturating load (multiple parallel TCP streams)
  /// 3. Measures latency under load
  /// 4. Calculates bufferbloat grade (A-F) and RPM score
  ///
  /// Set `config.loadDuration` to zero for a baseline-only latency measurement. That mode exposes
  /// usable baseline statistics and samples, but loaded statistics, latency increase, RPM, grade,
  /// and video-call impact are not meaningful.
  ///
  /// Video conferencing is highly sensitive to latency spikes. Zoom/Teams require
  /// <150ms latency and <50ms jitter for good quality.
  ///
  /// **Test Duration:** ~15 seconds (5s baseline + 10s load by default)
  ///
  /// - Parameter config: Bufferbloat test configuration
  /// - Returns: Bufferbloat test results. Grading and video-call impact are meaningful only when
  ///   the loaded phase produces samples.
  /// - Throws: ``TracerouteError`` if ping operations fail, or if a loaded test has an effective
  ///   per-operation or global interface/source-IP binding. URLSession cannot bind load traffic
  ///   to that same route.
  ///
  /// # Example
  /// ```swift
  /// let ftr = SwiftFTR()
  /// let result = try await ftr.testBufferbloat()
  ///
  /// print("Grade: \(result.grade.rawValue)")
  /// print("Latency increase: \(result.latencyIncrease.absoluteMs) ms")
  /// if let rpm = result.rpm {
  ///     print("Working RPM: \(rpm.workingRPM) (\(rpm.grade.rawValue))")
  /// }
  /// print("Video Call Impact: \(result.videoCallImpact.severity.rawValue)")
  /// ```
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func testBufferbloat(config: BufferbloatConfig = BufferbloatConfig()) async throws
    -> BufferbloatResult
  {
    try self.config.validateForOperation()
    try config.validateForOperation()

    let runner = BufferbloatRunner(testConfig: config, swiftConfig: self.config)
    return try await runner.run()
  }

  /// Discover public IP via STUN (with DNS fallback)
  internal func discoverPublicIP(handle: TraceHandle? = nil) async throws -> String {
    let interface = config.interface
    let sourceIP = config.sourceIP
    let enableLogging = config.enableLogging

    let budget = config.publicIPDiscoveryTimeoutForOperation

    return try await withTraceCancellation(handle: handle) {
      try await publicIPv4Discovery(
        stunTimeout: 2.0,
        dnsTimeout: 3.0,
        interface: interface,
        sourceIP: sourceIP,
        enableLogging: enableLogging,
        budget: budget
      ).ip
    }
  }

  /// Returns a configured/cached public IP or discovers one for the current
  /// cache generation. A network change while discovery is suspended makes the
  /// result stale, so it is neither returned nor cached.
  internal func effectivePublicIPForClassification(
    discover: @Sendable () async -> String?
  ) async -> String? {
    if let configured = config.publicIP { return configured }
    if let cachedPublicIP { return cachedPublicIP }

    let discoveryGeneration = cacheGeneration
    guard let discovered = await discover() else { return cachedPublicIP }
    // If cache was seeded or invalidated while discovery was in flight, do not overwrite the newer value.
    guard discoveryGeneration == cacheGeneration, cachedPublicIP == nil else {
      return cachedPublicIP
    }

    cachedPublicIP = discovered
    return discovered
  }

  // MARK: - Network Interface Discovery

  /// Discover all network interfaces on the system.
  ///
  /// Returns a snapshot of all interfaces including physical adapters (WiFi, Ethernet)
  /// and VPN tunnels (utun, ipsec, ppp). Use this to understand available network paths
  /// and to bind traces to specific interfaces.
  ///
  /// ## Example
  /// ```swift
  /// let tracer = SwiftFTR()
  /// let snapshot = await tracer.discoverInterfaces()
  ///
  /// // List VPN interfaces
  /// for iface in snapshot.vpnInterfaces {
  ///     print("\(iface.name): \(iface.ipv4Addresses)")
  /// }
  ///
  /// // Trace through each physical interface
  /// for iface in snapshot.physicalInterfaces {
  ///     let config = SwiftFTRConfig(interface: iface.name)
  ///     let tracer = SwiftFTR(config: config)
  ///     let trace = try await tracer.traceClassified(to: "example.com")
  /// }
  /// ```
  public nonisolated func discoverInterfaces() async -> NetworkInterfaceSnapshot {
    await NetworkInterfaceDiscovery().discover()
  }

  /// Discover public IPv4 via STUN through the configured (or default) interface.
  ///
  /// The interface and source address apply to the STUN attempt. If STUN fails, the DNS-whoami
  /// fallback uses system routing. The optional reverse-DNS lookup also uses system routing.
  /// Returns both the discovered address and its reverse-DNS hostname when available.
  ///
  /// The result does not identify whether STUN or the unbound fallback succeeded, so it is not by
  /// itself proof of a selected interface's exit. For route-specific dual-stack STUN results, use
  /// ``getPublicIPs(stunTimeout:interface:sourceIP:enableLogging:)`` instead.
  ///
  /// ## Example
  /// ```swift
  /// // Discover public IP through default interface
  /// let tracer = SwiftFTR()
  /// let (ip, hostname) = try await tracer.discoverPublicIPWithHostname()
  /// print("Exit: \(ip) (\(hostname ?? "no rDNS"))")
  ///
  /// func discoverVPNExit(vpnBSDName: String) async throws {
  ///   let snapshot = await NetworkInterfaceDiscovery().discover()
  ///   guard let vpnInterface = snapshot.interface(named: vpnBSDName),
  ///     vpnInterface.isUp, vpnInterface.type.isVPN
  ///   else { return }
  ///
  ///   let vpnTracer = SwiftFTR(config: SwiftFTRConfig(interface: vpnInterface.name))
  ///   let (vpnIP, vpnHost) = try await vpnTracer.discoverPublicIPWithHostname()
  ///   print("VPN exit: \(vpnIP) (\(vpnHost ?? "no rDNS"))")
  /// }
  /// ```
  public func discoverPublicIPWithHostname() async throws -> (ip: String, hostname: String?) {
    let ip = try await discoverPublicIP()
    let hostname: String?
    if !config.noReverseDNS {
      hostname = await rdnsCache.lookup(ip)
    } else {
      hostname = nil
    }
    return (ip: ip, hostname: hostname)
  }

  // MARK: - Cache Management

  /// Cancel all active traceroute operations without clearing caches.
  ///
  /// Signals every operation registered when the call is made: `trace`, `traceClassified`,
  /// `traceStream` and `discoverPaths`. One that has not finished stops and throws
  /// `TracerouteError.cancelled`, even if its caller cancelled it too. One that has already
  /// finished keeps its outcome. A `traceStream` finishes when its producer ends the stream, which
  /// it does in one step on this tracer after the trace is over; delivering its last hop is not
  /// finishing, so until that step the consumer's next call can still throw.
  /// `discoverPaths` alone guarantees more: a topology not yet returned is discarded.
  /// Operations registered after this call remain tracked for subsequent cancellation.
  /// This method does not invalidate rDNS, public IP, or ASN caches.
  public func cancelActiveTraces() async {
    cancelRegisteredTraces()
  }

  /// Withdraws and cancels every registered operation in one step on this actor, without
  /// suspending, so none of them can report its outcome part-way through.
  internal func cancelRegisteredTraces() {
    let tracesToCancel = activeTraces
    activeTraces.removeAll()
    for trace in tracesToCancel {
      trace.cancel(for: .library)
    }
  }

  /// Handle network changes by cancelling active traces and clearing caches.
  ///
  /// Call this method when the network configuration changes (e.g., WiFi to cellular,
  /// VPN connect/disconnect) to ensure fresh data for subsequent traces. Operations in flight
  /// (`trace`, `traceClassified`, `traceStream` and `discoverPaths`) are cancelled as by
  /// ``cancelActiveTraces()``. `ping` and the TCP, UDP, DNS and HTTP probes are not tied to the
  /// tracer and keep running.
  public func networkChanged() async {
    // Snapshot and remove the current generation before awaiting another actor.
    // Traces registered while cancellation is in progress remain tracked for a
    // subsequent network change instead of being silently removed.
    cacheGeneration &+= 1
    cachedPublicIP = nil
    await cancelActiveTraces()
    await rdnsCache.clear()

    // Note: ASN cache could optionally be cleared too
  }

  /// Get the effective public IP (configured or cached).
  ///
  /// This returns the configured public IP if set, otherwise the cached discovered IP.
  public var publicIP: String? {
    config.publicIP ?? cachedPublicIP
  }

  /// Clear all caches (convenience method).
  ///
  /// This clears both the public IP cache and the rDNS cache.
  public func clearCaches() async {
    cacheGeneration &+= 1
    cachedPublicIP = nil
    await rdnsCache.clear()
  }

  /// Invalidate just the public IP cache.
  ///
  /// Forces fresh discovery during the next classified trace or multipath enrichment that needs it.
  public func invalidatePublicIP() {
    cacheGeneration &+= 1
    cachedPublicIP = nil
  }

  /// Invalidate network-scoped reverse DNS cache entries.
  ///
  /// Evicts cached reverse DNS entries whose address is not globally routable
  /// (e.g. RFC 1918 private addresses, CGNAT, link-local, loopback, IPv6 ULA).
  /// Globally routable Internet hostnames and their TTLs are preserved.
  /// Also resets the reverse-DNS stall breaker so subsequent lookups are attempted.
  public func invalidateNetworkScopedRDNS() async {
    await rdnsCache.invalidateNetworkScoped()
  }

  /// Dynamically seeds a validated public IP address for the current cache generation.
  ///
  /// This provides a known-valid public IP so the next classified trace or multipath
  /// enrichment can skip discovery, without permanently overriding discovery like
  /// ``SwiftFTRConfig/publicIP`` does.
  ///
  /// The address must be a syntactically valid, globally routable IPv4 or IPv6 address.
  /// Private (RFC 1918), carrier-grade NAT (100.64.0.0/10), link-local, loopback,
  /// multicast, the other ranges the IANA special-purpose registries mark as not globally
  /// reachable (such as documentation and benchmarking), IPv6 outside the `2000::/3` unicast
  /// space other than `64:ff9b::/96` (such as deprecated site-local `fec0::/10`), a `64:ff9b::/96`
  /// address whose embedded IPv4 address is one of those (RFC 6052 section 3.1), and malformed
  /// strings (including placeholder sentinels like `"unknown"` and any string containing a NUL)
  /// are rejected.
  ///
  /// A successful seed applies only to the cache generation active at the call. Any
  /// subsequent invalidation (such as ``invalidatePublicIP()``, ``clearCaches()``, or
  /// ``networkChanged()``) discards the seeded value.
  ///
  /// - Parameters:
  ///   - address: The public IP address string to seed.
  ///   - source: The origin of this observation. Stating it is required; the library does not
  ///     retain it and treats every accepted address identically. See ``PublicIPSource``.
  /// - Returns: `true` if the address was accepted and cached; `false` if rejected.
  @discardableResult
  public func seedPublicIP(
    _ address: String,
    source: PublicIPSource
  ) -> Bool {
    guard isGloballyRoutablePublicIP(address) else {
      return false
    }
    guard let canonical = canonicalIPAddress(address) else {
      return false
    }
    // Increment generation so any older in-flight discovery is superseded and cannot overwrite this seed
    cacheGeneration &+= 1
    cachedPublicIP = canonical
    return true
  }
}

// MARK: - Dual-stack trace helpers (Stage 2 IPv6)

// Stage 1 added these for the ping path in Ping.swift; the v6 socket constants
// aren't bridged into Swift's Darwin overlay. Re-declared here at file scope so
// Traceroute's helpers don't have to reach into Ping.swift internals.
// swift-format-ignore: AlwaysUseLowerCamelCase
private let IPV6_RECVHOPLIMIT_OPT: Int32 = 37

/// Family-aware ICMP socket creation. v4 → `IPPROTO_ICMP`, v6 → `IPPROTO_ICMPV6`,
/// both `SOCK_DGRAM` (unprivileged on Darwin).
internal func createTraceSocket(family: Int32, enableLogging: Bool) throws -> Int32 {
  let fd: Int32
  if let substitute = TestSeams.makeICMPSocket {
    fd = try substitute(family)
  } else {
    switch family {
    case AF_INET:
      fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    case AF_INET6:
      fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
    default:
      throw TracerouteError.socketCreateFailed(
        errno: 0, details: "Unsupported family for trace socket: \(family)")
    }
  }
  if fd < 0 {
    let error = errno
    let details =
      "This typically indicates: (1) Platform doesn't support ICMP datagram sockets, (2) Network permissions denied, (3) Running in sandbox without network entitlement. On macOS, this should work without root privileges."
    throw TracerouteError.socketCreateFailed(errno: error, details: details)
  }
  if enableLogging {
    let famName = family == AF_INET6 ? "ICMPv6" : "ICMP"
    print("[SwiftFTR] \(famName) socket created (fd=\(fd))")
  }
  // For v6: ask the kernel to deliver hop limit as cmsg on recvmsg (mirror of
  // v4's IP_RECVTTL, but unrecoverable from the buffer because the kernel
  // strips the IPv6 header — verified empirically by traceroute6probe spike).
  if family == AF_INET6 {
    var on: Int32 = 1
    _ = setsockopt(
      fd, IPPROTO_IPV6, IPV6_RECVHOPLIMIT_OPT, &on, socklen_t(MemoryLayout<Int32>.size))
  }
  return fd
}

/// Makes a trace or ping socket non-blocking, or throws.
///
/// The receive loops read until the socket reports no more data. On a blocking socket that last
/// read would wait for the next datagram on the queue that also delivers the operation's deadline
/// and cancellation, so no operation may run on one.
internal func setProbeSocketNonBlocking(_ fd: Int32) throws {
  let control = TestSeams.fileControl ?? { fcntl($0, $1, $2) }
  let flags = control(fd, F_GETFL, 0)
  guard flags >= 0 else {
    throw TracerouteError.socketCreateFailed(errno: errno, details: "fcntl F_GETFL failed")
  }
  guard control(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
    throw TracerouteError.socketCreateFailed(errno: errno, details: "fcntl F_SETFL failed")
  }
}

/// Family-aware hop-limit setter: v4 → `IP_TTL`, v6 → `IPV6_UNICAST_HOPS`.
internal func setTraceHopLimit(sockfd: Int32, family: Int32, ttl: Int) throws {
  var v = Int32(ttl)
  let level = family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP
  let opt = family == AF_INET6 ? IPV6_UNICAST_HOPS : IP_TTL
  if setsockopt(sockfd, level, opt, &v, socklen_t(MemoryLayout<Int32>.size)) != 0 {
    let name = family == AF_INET6 ? "IPV6_UNICAST_HOPS" : "IP_TTL"
    throw TracerouteError.setsockoptFailed(option: name, errno: errno)
  }
}

/// Family-aware interface binding: v4 → `IP_BOUND_IF`, v6 → `IPV6_BOUND_IF`.
/// Trace-layer wrapper around the shared `bindInterface`. Translates the
/// string error to a typed `TracerouteError.interfaceBindFailed` and logs.
internal func bindTraceInterface(
  sockfd: Int32, family: Int32, interfaceName: String, ifIndex: UInt32, enableLogging: Bool
) throws {
  if let errMsg = bindInterface(sockfd: sockfd, family: family, ifIndex: ifIndex) {
    let error = errno
    let details =
      "Failed to bind socket to interface '\(interfaceName)' (index: \(ifIndex)): \(errMsg). This may indicate: (1) Insufficient permissions, (2) Interface is not available for ICMP binding, (3) Interface doesn't support the operation."
    if enableLogging {
      print("[SwiftFTR] ERROR: bind-to-interface failed - \(errMsg)")
    }
    throw TracerouteError.interfaceBindFailed(
      interface: interfaceName, errno: error, details: details)
  }
  if enableLogging {
    print("[SwiftFTR] Bound trace socket to interface '\(interfaceName)' (index: \(ifIndex))")
  }
}

/// Trace-layer wrapper around the shared `bindSourceIP`. Translates the string
/// error to a typed `TracerouteError.sourceIPBindFailed` and logs.
internal func bindTraceSourceIP(
  sockfd: Int32, family: Int32, sourceIP: String, enableLogging: Bool
) throws {
  if let errMsg = bindSourceIP(sockfd: sockfd, family: family, sourceIP: sourceIP) {
    throw TracerouteError.sourceIPBindFailed(
      sourceIP: sourceIP, errno: errno, details: errMsg)
  }
  if enableLogging {
    print("[SwiftFTR] Bound trace socket to source IP '\(sourceIP)'")
  }
}

/// Sends one probe per TTL, tolerating probes that transient send pressure kept off the wire.
///
/// A probe whose send fails with a transient errno past the shared retry budget is recorded rather
/// than aborting the burst: the caller renders that TTL as ``HopOutcome/notSent(errno:)``, which a
/// consumer can tell apart from a router that simply did not answer. Losing one hop of a topology
/// beats losing the topology.
///
/// Any other errno still throws immediately — callers map `EHOSTUNREACH`, `ENETDOWN`,
/// `ENETUNREACH` and `EACCES` to states they act on, and delaying those delays the diagnosis.
/// A burst where *no* probe reached the wire also throws: a result full of holes would claim we
/// measured something when we measured nothing.
///
/// - Returns: TTLs that never left the host, mapped to the errno that stopped them.
internal func sendTraceBurst(
  sockfd: Int32, resolved: ResolvedHost, identifier: UInt16, maxHops: Int, payloadSize: Int,
  retryDeadline: TimeInterval, sendProbe: TestSeams.SendProbe?,
  outstanding: inout [UInt16: TraceSendInfo]
) throws -> [Int: Int32] {
  var unsent: [Int: Int32] = [:]
  var lastTransientError: Error?

  for ttl in 1...maxHops {
    try setTraceHopLimit(sockfd: sockfd, family: resolved.family, ttl: ttl)
    let seq: UInt16 = UInt16(truncatingIfNeeded: ttl)
    let sentAt = monotonicNow()
    do {
      try sendTraceProbe(
        sockfd: sockfd, resolved: resolved, identifier: identifier,
        sequence: seq, payloadSize: payloadSize, retryDeadline: retryDeadline,
        sendProbe: sendProbe)
      outstanding[seq] = TraceSendInfo(ttl: ttl, sentAt: sentAt)
    } catch let error as TracerouteError {
      guard case .sendFailed(let code) = error, isTransientSendErrno(code) else { throw error }
      unsent[ttl] = code
      lastTransientError = error
    }
  }

  if outstanding.isEmpty, let lastTransientError {
    throw lastTransientError
  }
  return unsent
}

/// Family-aware ICMP send: v4 uses `makeICMPEchoRequest`, v6 uses
/// `makeICMPv6EchoRequest`. Caller resolves destination via `resolveHost`.
///
/// The trace socket is non-blocking, so `sendto` reports transient buffer
/// pressure rather than waiting. `retryDeadline` is the monotonic timestamp past
/// which such a send gives up; callers compute one deadline per burst and pass
/// the same value to every probe in it, so the whole burst shares a single
/// bounded budget. Non-transient errnos propagate on the first attempt.
internal func sendTraceProbe(
  sockfd: Int32, resolved: ResolvedHost, identifier: UInt16, sequence: UInt16,
  payloadSize: Int, retryDeadline: TimeInterval, sendProbe: TestSeams.SendProbe?
) throws {
  let packet: [UInt8]
  if resolved.family == AF_INET6 {
    packet = makeICMPv6EchoRequest(
      identifier: identifier, sequence: sequence, payloadSize: payloadSize)
  } else {
    packet = makeICMPEchoRequest(
      identifier: identifier, sequence: sequence, payloadSize: payloadSize)
  }
  var addr = resolved.address
  _ = try sendRetryingTransientPressure(sockfd: sockfd, deadline: retryDeadline) {
    packet.withUnsafeBytes { raw in
      withUnsafePointer(to: &addr) { ap -> ssize_t in
        ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          if let sendProbe { return sendProbe(sockfd, raw, sa, resolved.addressLen) }
          return sendto(sockfd, raw.baseAddress, raw.count, 0, sa, resolved.addressLen)
        }
      }
    }
  }
}

/// Family-aware receive that yields a parsed ICMP/ICMPv6 message and the
/// reply's source `sockaddr_storage`. For v6, uses `recvmsg` so the hop
/// limit cmsg is available (`ParsedICMP` doesn't carry hop limit but Stage 3
/// may; in Stage 2 we just confirm the cmsg arrives and discard it). Returns
/// `nil` on EAGAIN/EWOULDBLOCK so callers can drain in a loop.
internal func recvTraceMessage(
  sockfd: Int32, family: Int32,
  recvBuffer: inout [UInt8], cmsgBuffer: inout [UInt8]
) -> (parsed: ParsedICMP, n: Int)? {
  var storage = sockaddr_storage()
  if family == AF_INET6 {
    var iov = iovec()
    var msg = msghdr()
    let received = recvBuffer.withUnsafeMutableBufferPointer { rb -> ssize_t in
      cmsgBuffer.withUnsafeMutableBufferPointer { cb -> ssize_t in
        withUnsafeMutablePointer(to: &storage) { sp -> ssize_t in
          iov.iov_base = UnsafeMutableRawPointer(rb.baseAddress)
          iov.iov_len = rb.count
          return withUnsafeMutablePointer(to: &iov) { iovPtr -> ssize_t in
            msg.msg_name = UnsafeMutableRawPointer(sp)
            msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_storage>.size)
            msg.msg_iov = iovPtr
            msg.msg_iovlen = 1
            msg.msg_control = UnsafeMutableRawPointer(cb.baseAddress)
            msg.msg_controllen = socklen_t(cb.count)
            msg.msg_flags = 0
            return recvmsg(sockfd, &msg, 0)
          }
        }
      }
    }
    if received < 0 { return nil }
    let hopLimit = (msg.msg_flags & MSG_CTRUNC) == 0 ? extractIPv6HopLimit(msg: msg) : nil
    let parsed = recvBuffer.withUnsafeBytes { raw -> ParsedICMP? in
      let slice = UnsafeRawBufferPointer(start: raw.baseAddress, count: Int(received))
      return parseICMPv6Message(buffer: slice, hopLimit: hopLimit, from: storage)
    }
    if let p = parsed { return (p, Int(received)) }
    return nil
  }
  // v4 path — recvfrom + parseICMPv4Message
  var addrlen = socklen_t(MemoryLayout<sockaddr_storage>.size)
  let n = recvBuffer.withUnsafeMutableBytes { rb -> ssize_t in
    withUnsafeMutablePointer(to: &storage) { sp in
      sp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        recvfrom(sockfd, rb.baseAddress, rb.count, 0, sa, &addrlen)
      }
    }
  }
  if n < 0 { return nil }
  let parsed = recvBuffer.withUnsafeBytes { raw -> ParsedICMP? in
    let slice = UnsafeRawBufferPointer(start: raw.baseAddress, count: Int(n))
    return parseICMPv4Message(buffer: slice, from: storage)
  }
  if let p = parsed { return (p, Int(n)) }
  return nil
}

private enum Constants {
  /// Receive buffer size for incoming ICMP datagrams.
  static let receiveBufferSize = 2048
}

/// The most datagrams one read callback handles before it returns to its queue.
///
/// Each receive operation reads on the serial queue that also delivers its deadline, its
/// cancellation and, for a stream, its retry. A socket that stays readable, such as one flooded
/// with replies for other identifiers, would otherwise keep a single callback running past all
/// of them. A dispatch read source fires again while data remains, so a longer backlog is read
/// over several callbacks and none of it is lost.
let receiveBatchLimit = 64

/// The descriptor a trace's receive operation reads, confined to the operation's serial queue.
///
/// Dispatch may use a descriptor until its read source's cancel handler runs, so the descriptor is
/// closed there, never while a source still holds it. Completions passed to ``close(then:)`` run
/// after the descriptor is closed: an operation that resumes its caller from one no longer owns
/// the descriptor, and its number cannot be reused under a callback.
private final class ReceiveSocket: @unchecked Sendable {
  private enum State {
    case open
    case closing
    case closed
  }

  let fd: Int32
  private let queue: DispatchQueue
  private var source: DispatchSourceRead?
  private var state = State.open
  private var afterClose: [() -> Void] = []

  init(fd: Int32, queue: DispatchQueue) {
    self.fd = fd
    self.queue = queue
  }

  /// Starts delivering read events to `handler` on the queue. Call on the queue.
  func startReading(_ handler: @escaping () -> Void) {
    guard state == .open, source == nil else { return }
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler(handler: handler)
    source.setCancelHandler { self.closeDescriptor() }
    source.activate()
    self.source = source
  }

  /// Stops reading, closes the descriptor once dispatch has let go of it, then runs `completion`.
  /// Call on the queue; later calls only add their completion.
  func close(then completion: @escaping () -> Void) {
    switch state {
    case .closed:
      completion()
    case .closing:
      afterClose.append(completion)
    case .open:
      afterClose.append(completion)
      state = .closing
      if let source {
        self.source = nil
        source.cancel()
      } else {
        closeDescriptor()
      }
    }
  }

  private func closeDescriptor() {
    guard state != .closed else { return }
    Darwin.close(fd)
    state = .closed
    let pending = afterClose
    afterClose = []
    for completion in pending { completion() }
  }
}

// MARK: - Trace Receive Result

/// Result returned by TraceReceiveOperation.
private struct TraceReceiveResult {
  var hops: [TraceHop?]
  var reachedTTL: Int?
}

/// Shared send info for probe tracking.
internal struct TraceSendInfo {
  let ttl: Int
  let sentAt: TimeInterval
}

// MARK: - TraceReceiveOperation

/// Manages the DispatchSource-based receive loop for performTrace().
///
/// After all probes are sent, this operation listens for ICMP responses
/// using a kqueue-backed DispatchSourceRead, matching responses to probes
/// by identifier/sequence. Completes when all hops are filled or the
/// deadline expires.
private final class TraceReceiveOperation: @unchecked Sendable {
  private let socket: ReceiveSocket
  private let family: Int32
  private let identifier: UInt16
  private let maxHops: Int
  private let destinationIP: String
  private let enableLogging: Bool

  private var outstanding: [UInt16: TraceSendInfo]
  private var hops: [TraceHop?]
  private var reachedTTL: Int?

  private var continuation: CheckedContinuation<TraceReceiveResult, Error>?
  private var timerSource: DispatchSourceTimer?
  /// When the receive window closes, set when the sources start. The timer is scheduled on this
  /// same value, so the timer and the read loop's check cannot disagree, even across a sleep.
  private var deadline = DispatchTime.distantFuture
  private var recvBuffer = [UInt8](repeating: 0, count: Constants.receiveBufferSize)
  private var cmsgBuffer = [UInt8](repeating: 0, count: 64)

  private let queue: DispatchQueue
  private let lock = NSLock()
  private var isFinished = false
  private let timeout: TimeInterval

  init(
    sockfd: Int32,
    family: Int32,
    identifier: UInt16,
    outstanding: [UInt16: TraceSendInfo],
    maxHops: Int,
    timeout: TimeInterval,
    destinationIP: String,
    enableLogging: Bool
  ) {
    self.family = family
    self.identifier = identifier
    self.outstanding = outstanding
    self.maxHops = maxHops
    self.timeout = timeout
    self.destinationIP = destinationIP
    self.enableLogging = enableLogging
    self.hops = Array(repeating: nil, count: maxHops)
    self.queue = DispatchQueue(
      label: "com.swiftftr.trace.\(UInt64.random(in: 0...UInt64.max))", qos: .userInitiated)
    self.socket = ReceiveSocket(fd: sockfd, queue: queue)
  }

  /// Takes ownership of the descriptor: it is closed before `continuation` is resumed, however
  /// the operation ends.
  func start(continuation: CheckedContinuation<TraceReceiveResult, Error>) {
    lock.lock()
    if isFinished {
      lock.unlock()
      queue.async {
        self.tearDown { continuation.resume(throwing: TracerouteError.cancelled) }
      }
      return
    }
    self.continuation = continuation
    lock.unlock()

    queue.async { self.setupSources() }
  }

  func cancel() {
    // Set cancelled flag synchronously so start() and the read loop can detect it
    lock.lock()
    if isFinished {
      lock.unlock()
      return
    }
    isFinished = true
    let currentContinuation = self.continuation
    self.continuation = nil
    lock.unlock()

    // Dispatch cleanup to serial queue to avoid racing with handleRead/setupSources
    queue.async {
      self.tearDown { currentContinuation?.resume(throwing: TracerouteError.cancelled) }
    }
  }

  private func setupSources() {
    // Guard against setup after cancel() already completed
    if checkFinishedSync() { return }

    deadline = .now() + timeout
    socket.startReading { self.handleRead() }

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: deadline)
    timer.setEventHandler { self.finish() }
    timer.activate()
    self.timerSource = timer
  }

  private func handleRead() {
    for _ in 0..<receiveBatchLimit {
      if checkFinishedSync() { return }
      if DispatchTime.now() >= deadline {
        finish()
        return
      }
      guard
        let received = recvTraceMessage(
          sockfd: socket.fd, family: family,
          recvBuffer: &recvBuffer, cmsgBuffer: &cmsgBuffer)
      else { return }  // EAGAIN/EWOULDBLOCK or parse-fail
      let parsed = received.parsed

      switch parsed.kind {
      case .echoReply(let id, let seq):
        guard id == identifier, ipAddressesAreEqual(parsed.sourceAddress, destinationIP) else {
          continue
        }
        if let info = outstanding.removeValue(forKey: seq) {
          let rtt = monotonicNow() - info.sentAt
          let hopIndex = min(max(info.ttl - 1, 0), maxHops - 1)
          if hops[hopIndex] == nil {
            hops[hopIndex] = TraceHop(
              ttl: info.ttl, ipAddress: parsed.sourceAddress, rtt: rtt, reachedDestination: true)
          }
          if reachedTTL == nil || info.ttl < reachedTTL! { reachedTTL = info.ttl }
        }

      case .timeExceeded(let originalID, let originalSeq):
        guard originalID == nil || originalID == identifier else { continue }
        if let seq = originalSeq, let info = outstanding[seq] {
          let hopIndex = min(max(info.ttl - 1, 0), maxHops - 1)
          if hops[hopIndex] == nil {
            let rtt = monotonicNow() - info.sentAt
            hops[hopIndex] = TraceHop(
              ttl: info.ttl, ipAddress: parsed.sourceAddress, rtt: rtt, reachedDestination: false)
          }
        }

      case .destinationUnreachable(let originalID, let originalSeq, let code):
        guard originalID == nil || originalID == identifier else { continue }
        if let seq = originalSeq, let info = outstanding.removeValue(forKey: seq) {
          let hopIndex = min(max(info.ttl - 1, 0), maxHops - 1)
          let rtt = monotonicNow() - info.sentAt
          if hops[hopIndex] == nil {
            hops[hopIndex] = TraceHop(
              ttl: info.ttl, ipAddress: parsed.sourceAddress, rtt: rtt, reachedDestination: false,
              outcome: .unreachable(code: code))
          }
        }

      case .other:
        continue
      }

      // Early completion: destination reached and all earlier hops filled
      if let rttl = reachedTTL {
        var done = true
        for i in 0..<rttl {
          if hops[i] == nil {
            done = false
            break
          }
        }
        if done {
          finish()
          return
        }
      }
      _ = received.n  // n is captured by recvTraceMessage callers; unused here
    }
  }

  /// Only called from serial queue (timer handler or handleRead).
  /// The lock only protects `isFinished` and `continuation` (accessed from both
  /// the serial queue and `cancel()`). `hops` and `reachedTTL` are safe to read
  /// without lock here because they are only mutated on this same serial queue.
  private func finish() {
    lock.lock()
    if isFinished {
      lock.unlock()
      return
    }
    isFinished = true
    let currentContinuation = self.continuation
    self.continuation = nil
    lock.unlock()

    let result = TraceReceiveResult(hops: hops, reachedTTL: reachedTTL)
    tearDown { currentContinuation?.resume(returning: result) }
  }

  /// Stops the timer and closes the socket, then runs `completion`. Only called on the queue.
  private func tearDown(then completion: @escaping () -> Void) {
    timerSource?.cancel()
    timerSource = nil
    socket.close(then: completion)
  }

  private func checkFinishedSync() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return isFinished
  }
}

// MARK: - StreamingTraceReceiveOperation

/// Manages the DispatchSource-based receive loop for performStreamingTrace().
///
/// Yields StreamingHop values as ICMP responses arrive. Supports retry
/// of unresponsive TTLs via a secondary DispatchSourceTimer.
private final class StreamingTraceReceiveOperation: @unchecked Sendable {
  private let socket: ReceiveSocket
  private let family: Int32
  private let identifier: UInt16
  private let maxHops: Int
  private let payloadSize: Int
  private let resolved: ResolvedHost
  private let streamConfig: StreamingTraceConfig
  private let enableLogging: Bool
  private let sendProbe: TestSeams.SendProbe?
  private let yieldHop: @Sendable (StreamingHop) -> Bool

  private var outstanding: [UInt16: TraceSendInfo]
  private var receivedTTLs: Set<Int> = []
  private var reachedTTL: Int?
  private var didRetry = false

  private var continuation: CheckedContinuation<Void, Error>?
  private var deadlineTimer: DispatchSourceTimer?
  private var retryTimer: DispatchSourceTimer?
  /// When the probe timeout expires, set when the sources start. The deadline timer is scheduled
  /// on this same value, so the timer and the read loop's check cannot disagree, even across a
  /// sleep.
  private var deadline = DispatchTime.distantFuture
  private var recvBuffer = [UInt8](repeating: 0, count: Constants.receiveBufferSize)
  private var cmsgBuffer = [UInt8](repeating: 0, count: 64)

  private let queue: DispatchQueue
  private let lock = NSLock()
  private var isFinished = false

  init(
    sockfd: Int32,
    family: Int32,
    identifier: UInt16,
    outstanding: [UInt16: TraceSendInfo],
    maxHops: Int,
    payloadSize: Int,
    resolved: ResolvedHost,
    streamConfig: StreamingTraceConfig,
    enableLogging: Bool,
    sendProbe: TestSeams.SendProbe?,
    yield: @Sendable @escaping (StreamingHop) -> Bool
  ) {
    self.sendProbe = sendProbe
    self.family = family
    self.identifier = identifier
    self.outstanding = outstanding
    self.maxHops = maxHops
    self.payloadSize = payloadSize
    self.resolved = resolved
    self.streamConfig = streamConfig
    self.enableLogging = enableLogging
    self.yieldHop = yield
    self.queue = DispatchQueue(
      label: "com.swiftftr.stream.\(UInt64.random(in: 0...UInt64.max))", qos: .userInitiated)
    self.socket = ReceiveSocket(fd: sockfd, queue: queue)
  }

  /// Takes ownership of the descriptor: it is closed before `continuation` is resumed, however
  /// the operation ends.
  func start(continuation: CheckedContinuation<Void, Error>) {
    lock.lock()
    if isFinished {
      lock.unlock()
      queue.async {
        self.tearDown { continuation.resume(throwing: TracerouteError.cancelled) }
      }
      return
    }
    self.continuation = continuation
    lock.unlock()

    queue.async { self.setupSources() }
  }

  func cancel() {
    // Set cancelled flag synchronously so start() can detect it
    lock.lock()
    if isFinished {
      lock.unlock()
      return
    }
    isFinished = true
    let currentContinuation = self.continuation
    self.continuation = nil
    lock.unlock()

    // Dispatch cleanup to serial queue to avoid racing with handleRead/setupSources
    queue.async {
      self.tearDown { currentContinuation?.resume(throwing: TracerouteError.cancelled) }
    }
  }

  private func setupSources() {
    // Guard against setup after cancel() already completed
    if checkFinishedSync() { return }

    // Read events for incoming ICMP responses
    deadline = .now() + streamConfig.probeTimeout
    socket.startReading { self.handleRead() }

    // Overall deadline timer
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: deadline)
    timer.setEventHandler { self.finish() }
    timer.activate()
    self.deadlineTimer = timer

    // Retry timer (if configured)
    if let retryAfter = streamConfig.retryAfter {
      let retry = DispatchSource.makeTimerSource(queue: queue)
      retry.schedule(deadline: .now() + retryAfter)
      retry.setEventHandler { self.handleRetry() }
      retry.activate()
      self.retryTimer = retry
    }
  }

  private func handleRead() {
    for _ in 0..<receiveBatchLimit {
      if checkFinishedSync() { return }
      if DispatchTime.now() >= deadline {
        finish()
        return
      }
      guard
        let received = recvTraceMessage(
          sockfd: socket.fd, family: family,
          recvBuffer: &recvBuffer, cmsgBuffer: &cmsgBuffer)
      else { return }
      let parsed = received.parsed

      switch parsed.kind {
      case .echoReply(let id, let seq):
        guard id == identifier, ipAddressesAreEqual(parsed.sourceAddress, resolved.canonical) else {
          continue
        }
        if let info = outstanding.removeValue(forKey: seq) {
          if let destTTL = reachedTTL, info.ttl > destTTL { continue }
          let rtt = monotonicNow() - info.sentAt
          if !receivedTTLs.contains(info.ttl) {
            receivedTTLs.insert(info.ttl)
            guard
              yieldHop(
                StreamingHop(
                  ttl: info.ttl, ipAddress: parsed.sourceAddress, rtt: rtt,
                  reachedDestination: true))
            else {
              cancel()
              return
            }
            if reachedTTL == nil || info.ttl < reachedTTL! {
              reachedTTL = info.ttl
            }
          }
        }

      case .timeExceeded(let originalID, let originalSeq):
        guard originalID == nil || originalID == identifier else { continue }
        if let seq = originalSeq {
          if !emitIntermediateHop(seq: seq, parsed: parsed) { return }
        }

      case .destinationUnreachable(let originalID, let originalSeq, let code):
        guard originalID == nil || originalID == identifier else { continue }
        if let seq = originalSeq {
          if !emitIntermediateHop(seq: seq, parsed: parsed, outcome: .unreachable(code: code)) {
            return
          }
        }

      case .other:
        continue
      }

      if let rttl = reachedTTL {
        var done = true
        for i in 1..<rttl {
          if !receivedTTLs.contains(i) {
            done = false
            break
          }
        }
        if done {
          finish()
          return
        }
      }
      _ = received.n  // currently unused; recvTraceMessage already validated parse
    }
  }

  private func emitIntermediateHop(
    seq: UInt16, parsed: ParsedICMP, outcome: HopOutcome = .replied
  ) -> Bool {
    guard let info = outstanding[seq] else { return true }
    if let destTTL = reachedTTL, info.ttl > destTTL { return true }
    if receivedTTLs.contains(info.ttl) { return true }

    let rtt = monotonicNow() - info.sentAt
    receivedTTLs.insert(info.ttl)
    guard
      yieldHop(
        StreamingHop(
          ttl: info.ttl, ipAddress: parsed.sourceAddress, rtt: rtt, reachedDestination: false,
          outcome: outcome))
    else {
      cancel()
      return false
    }
    return true
  }

  private func handleRetry() {
    if checkFinishedSync() { return }
    if didRetry { return }
    didRetry = true

    let ttlCutoff = reachedTTL ?? maxHops
    var missingTTLs: [Int] = []
    for ttl in 1..<ttlCutoff {
      if !receivedTTLs.contains(ttl) {
        missingTTLs.append(ttl)
      }
    }

    guard !missingTTLs.isEmpty else { return }

    if enableLogging {
      print(
        "[SwiftFTR] Streaming trace: retrying \(missingTTLs.count) unresponsive TTLs: \(missingTTLs)"
      )
    }

    let sendRetryDeadline = monotonicNow() + traceBurstSendRetryBudget
    for ttl in missingTTLs {
      do {
        try setTraceHopLimit(sockfd: socket.fd, family: family, ttl: ttl)
      } catch {
        continue
      }
      let seq: UInt16 = UInt16(truncatingIfNeeded: ttl + maxHops)
      let sentAt = monotonicNow()
      do {
        try sendTraceProbe(
          sockfd: socket.fd, resolved: resolved, identifier: identifier,
          sequence: seq, payloadSize: payloadSize, retryDeadline: sendRetryDeadline,
          sendProbe: sendProbe)
        outstanding[seq] = TraceSendInfo(ttl: ttl, sentAt: sentAt)
      } catch {
        // Best-effort retry — silently skip if send fails (will time out instead).
        continue
      }
    }
  }

  /// Only called from serial queue (deadline timer, handleRead, or handleRetry path).
  /// The lock only protects `isFinished` and `continuation` (accessed from both
  /// the serial queue and `cancel()`). `receivedTTLs` and `reachedTTL` are safe
  /// to read without lock here because they are only mutated on this same serial queue.
  private func finish() {
    lock.lock()
    if isFinished {
      lock.unlock()
      return
    }
    isFinished = true
    let currentContinuation = self.continuation
    self.continuation = nil
    lock.unlock()

    deadlineTimer?.cancel()
    retryTimer?.cancel()
    deadlineTimer = nil
    retryTimer = nil

    // Emit timeout placeholders for missing TTLs
    if streamConfig.emitTimeouts {
      let cutoff = reachedTTL ?? maxHops
      for ttl in 1...cutoff {
        if !receivedTTLs.contains(ttl) {
          guard
            yieldHop(
              StreamingHop(ttl: ttl, ipAddress: nil, rtt: nil, reachedDestination: false))
          else { break }
        }
      }
    }

    if enableLogging {
      print(
        "[SwiftFTR] Streaming trace complete: \(receivedTTLs.count) hops received, reachedTTL=\(reachedTTL.map(String.init) ?? "nil")"
      )
    }

    socket.close { currentContinuation?.resume() }
  }

  /// Stops both timers and closes the socket, then runs `completion`. Only called on the queue.
  private func tearDown(then completion: @escaping () -> Void) {
    deadlineTimer?.cancel()
    retryTimer?.cancel()
    deadlineTimer = nil
    retryTimer = nil
    socket.close(then: completion)
  }

  private func checkFinishedSync() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return isFinished
  }
}
