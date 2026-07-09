import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// One hop result in a traceroute.
public struct TraceHop: Sendable {
  /// Time-To-Live probed for this hop (1-based).
  public let ttl: Int
  /// Responder IPv4 address as a string. `nil` if timed out.
  public let ipAddress: String?
  /// Round-trip time in seconds for this hop, or `nil` if no reply.
  public let rtt: TimeInterval?
  /// Whether this reply came from the destination host.
  public let reachedDestination: Bool
  /// Hostname from reverse DNS lookup. `nil` if lookup disabled, failed, or timed out.
  public let hostname: String?

  public init(
    ttl: Int,
    ipAddress: String?,
    rtt: TimeInterval?,
    reachedDestination: Bool,
    hostname: String? = nil
  ) {
    self.ttl = ttl
    self.ipAddress = ipAddress
    self.rtt = rtt
    self.reachedDestination = reachedDestination
    self.hostname = hostname
  }

}

/// Complete result of a traceroute run.
public struct TraceResult: Sendable {
  /// Destination hostname or IP string as provided by the caller.
  public let destination: String
  /// Maximum TTL probed in this run.
  public let maxHops: Int
  /// Whether the destination responded.
  public let reached: Bool
  /// Per-hop results in order from TTL=1.
  public let hops: [TraceHop]
  /// Total wall-clock duration (seconds) measured for the trace.
  public let duration: TimeInterval
  public init(
    destination: String, maxHops: Int, reached: Bool, hops: [TraceHop], duration: TimeInterval = 0
  ) {
    self.destination = destination
    self.maxHops = maxHops
    self.reached = reached
    self.hops = hops
    self.duration = duration
  }
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
public struct SwiftFTRConfig: Sendable {
  /// Maximum TTL/hops to probe (default: 40)
  public let maxHops: Int
  /// Maximum wait time per probe in milliseconds (default: 1000ms)
  public let maxWaitMs: Int
  /// Size in bytes of the Echo payload (default: 56)
  public let payloadSize: Int
  /// Override the public IP address (bypasses STUN discovery if set)
  public let publicIP: String?
  /// Enable verbose logging for debugging
  public let enableLogging: Bool
  /// Disable reverse DNS lookups (default: false)
  public let noReverseDNS: Bool
  /// TTL for rDNS cache entries in seconds (default: 86400 = 1 day)
  public let rdnsCacheTTL: TimeInterval?
  /// Maximum rDNS cache size (default: 1000 entries)
  public let rdnsCacheSize: Int?
  /// Network interface to use for sending probes (e.g. "en0"). If nil, uses system default.
  public let interface: String?

  /// Source IP address to bind to for all operations.
  ///
  /// When specified, outgoing packets will use this IP as the source address.
  /// The IP must be assigned to the network interface (either globally configured
  /// via ``interface`` or per-operation).
  ///
  /// - Note: This is an advanced option. Most users should only set ``interface``.
  ///
  /// Example:
  /// ```swift
  /// let config = SwiftFTRConfig(
  ///   interface: "en0",
  ///   sourceIP: "192.168.1.100"  // Must be assigned to en0
  /// )
  /// ```
  public let sourceIP: String?

  /// ASN resolver strategy for trace classification.
  ///
  /// Controls how IP-to-ASN lookups are performed during `traceClassified()`.
  /// Defaults to `.dns` (Team Cymru DNS) for backward compatibility.
  ///
  /// Options:
  /// - `.dns`: DNS-based lookups (default, always current, requires network)
  /// - `.embedded`: Local database from SwiftIP2ASN (~10μs lookups, +6MB memory)
  /// - `.remote(bundledPath:url:)`: Remote database with optional offline fallback
  /// - `.hybrid(source, fallbackTimeout:)`: Local first, DNS fallback for missing
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
  ///   - publicIP: Override the public IP address (bypasses STUN discovery if set)
  ///   - enableLogging: Enable verbose logging for debugging
  ///   - noReverseDNS: Disable reverse DNS lookups (default: false)
  ///   - rdnsCacheTTL: TTL for rDNS cache entries in seconds (default: 86400 = 1 day)
  ///   - rdnsCacheSize: Maximum rDNS cache size (default: 1000 entries)
  ///   - interface: Network interface to use for sending probes (e.g. "en0"). If nil, uses system default.
  ///   - sourceIP: Source IP address to bind to (e.g. "192.168.1.100"). Must be assigned to the interface. If nil, uses system default.
  ///   - asnResolverStrategy: Strategy for ASN lookups during classification (default: .dns)
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
    interface: String? = nil,
    sourceIP: String? = nil,
    asnResolverStrategy: ASNResolverStrategy = .dns,
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
    self.interface = interface
    self.sourceIP = sourceIP
    self.asnResolverStrategy = asnResolverStrategy
    self.preferredFamily = preferredFamily
  }
}

/// Top-level entry point for performing fast, parallel traceroutes.
///
/// SwiftFTR is an actor providing thread-safe traceroute operations with
/// built-in caching for rDNS lookups and STUN public IP discovery.
@available(macOS 13.0, *)
public actor SwiftFTR {
  internal nonisolated let config: SwiftFTRConfig

  // Cache storage
  internal var cachedPublicIP: String?
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
      maxSize: config.cacheSizeForConstruction
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
  /// Call this early in your app lifecycle to avoid the 35-40ms database load
  /// latency on the first `traceClassified()` call.
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
  ///   - host: Destination hostname or IPv4 address.
  /// - Returns: A `TraceResult` with ordered hops and whether the destination responded.
  /// - Throws: `TracerouteError` if resolution, socket operations fail, or trace is cancelled
  public func trace(
    to host: String
  ) async throws -> TraceResult {
    let handle = TraceHandle()

    // Register active trace
    activeTraces.insert(handle)
    defer { activeTraces.remove(handle) }

    // Run trace in a task so we can check cancellation
    return try await withTaskCancellationHandler {
      try await performTrace(to: host, handle: handle)
    } onCancel: {
      Task { await handle.cancel() }
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
  /// - Parameters:
  ///   - host: Destination hostname or IPv4 address.
  ///   - streamConfig: Configuration for streaming behavior (timeouts, retry, etc.)
  /// - Returns: An `AsyncThrowingStream<StreamingHop, Error>` yielding hops as they arrive.
  public nonisolated func traceStream(
    to host: String,
    config streamConfig: StreamingTraceConfig = .default
  ) -> AsyncThrowingStream<StreamingHop, Error> {
    AsyncThrowingStream { continuation in
      let handle = TraceHandle()

      Task { [self] in
        // Register active trace
        await self.registerActiveTrace(handle)
        defer { Task { await self.unregisterActiveTrace(handle) } }

        do {
          try await self.performStreamingTrace(
            to: host,
            handle: handle,
            streamConfig: streamConfig,
            yield: { hop in
              continuation.yield(hop)
            }
          )
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }

      continuation.onTermination = { @Sendable _ in
        Task { await handle.cancel() }
      }
    }
  }

  /// Register an active trace handle for cancellation tracking.
  private func registerActiveTrace(_ handle: TraceHandle) {
    activeTraces.insert(handle)
  }

  /// Unregister an active trace handle.
  private func unregisterActiveTrace(_ handle: TraceHandle) {
    activeTraces.remove(handle)
  }

  /// Internal implementation of streaming trace with two-phase timeout.
  internal func performStreamingTrace(
    to host: String,
    handle: TraceHandle,
    streamConfig: StreamingTraceConfig,
    yield: @escaping (StreamingHop) -> Void
  ) async throws {
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

    if await handle.isCancelled {
      throw TracerouteError.cancelled
    }

    let fd = try createTraceSocket(family: resolved.family, enableLogging: config.enableLogging)
    defer { close(fd) }

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

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    if resolved.family == AF_INET {
      var on: Int32 = 1
      _ = setsockopt(fd, IPPROTO_IP, IP_RECVTTL, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    let identifier = UInt16.random(in: 0...UInt16.max)
    var outstanding: [UInt16: TraceSendInfo] = [:]

    if config.enableLogging {
      print("[SwiftFTR] Streaming trace: sending \(maxHops) probes...")
    }
    for ttl in 1...maxHops {
      try setTraceHopLimit(sockfd: fd, family: resolved.family, ttl: ttl)
      let seq: UInt16 = UInt16(truncatingIfNeeded: ttl)
      let sentAt = monotonicNow()
      try sendTraceProbe(
        sockfd: fd, resolved: resolved, identifier: identifier,
        sequence: seq, payloadSize: payloadSize)
      outstanding[seq] = TraceSendInfo(ttl: ttl, sentAt: sentAt)
    }

    // Collect responses via DispatchSourceRead with retry support.
    if config.enableLogging {
      print(
        "[SwiftFTR] Streaming trace: timeout \(streamConfig.probeTimeout)s, retry after \(streamConfig.retryAfter.map { "\($0)s" } ?? "disabled")"
      )
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
      yield: yield
    )

    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, Error>) in
        streamOperation.start(continuation: continuation)
      }
    } onCancel: {
      streamOperation.cancel()
    }

    // Check TraceHandle cancellation
    if await handle.isCancelled {
      streamOperation.cancel()
      throw TracerouteError.cancelled
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
    flowIdentifier: UInt16? = nil
  ) async throws -> TraceResult {
    try config.validateForOperation()

    let maxHops = config.maxHops
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

    // Validate source IP early if specified
    if let sourceIP = config.sourceIP {
      if config.enableLogging {
        print("[SwiftFTR] Validating source IP '\(sourceIP)'...")
      }

      var testAddr = sockaddr_in()
      if inet_pton(AF_INET, sourceIP, &testAddr.sin_addr) != 1 {
        let details =
          "Invalid source IP address '\(sourceIP)'. Must be a valid IPv4 address in dotted decimal notation (e.g., 192.168.1.100)."
        throw TracerouteError.sourceIPBindFailed(
          sourceIP: sourceIP, errno: EINVAL, details: details)
      }

      if config.enableLogging {
        print("[SwiftFTR] Source IP '\(sourceIP)' format validated")
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

    let fd = try createTraceSocket(family: resolved.family, enableLogging: config.enableLogging)
    defer { close(fd) }

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

    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

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
    for ttl in 1...maxHops {
      try setTraceHopLimit(sockfd: fd, family: resolved.family, ttl: ttl)
      let seq: UInt16 = UInt16(truncatingIfNeeded: ttl)
      let sentAt = monotonicNow()
      try sendTraceProbe(
        sockfd: fd, resolved: resolved, identifier: identifier,
        sequence: seq, payloadSize: payloadSize)
      outstanding[seq] = TraceSendInfo(ttl: ttl, sentAt: sentAt)
    }

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
      enableLogging: config.enableLogging
    )

    let receiveResult: TraceReceiveResult = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        operation.start(continuation: continuation)
      }
    } onCancel: {
      operation.cancel()
    }

    // Also check TraceHandle cancellation
    if await handle.isCancelled {
      operation.cancel()
      throw TracerouteError.cancelled
    }

    var hops = receiveResult.hops
    let reachedTTL = receiveResult.reachedTTL

    // Finalize hops: mark unresolved up to reachedTTL (or max) as timeouts
    let cutoff = reachedTTL ?? maxHops
    for ttl in 1...cutoff {
      let idx = ttl - 1
      if hops[idx] == nil {
        hops[idx] = TraceHop(ttl: ttl, ipAddress: nil, rtt: nil, reachedDestination: false)
      }
    }

    var finalHops = Array(hops[0..<(reachedTTL ?? maxHops)]).compactMap { $0 }

    // Perform rDNS lookups if enabled
    if !config.noReverseDNS {
      let ips = finalHops.compactMap { $0.ipAddress }
      let hostnames = await rdnsCache.batchLookup(ips)

      finalHops = finalHops.map { hop in
        TraceHop(
          ttl: hop.ttl,
          ipAddress: hop.ipAddress,
          rtt: hop.rtt,
          reachedDestination: hop.reachedDestination,
          hostname: hop.ipAddress.flatMap { hostnames[$0] }
        )
      }
    }

    let result = TraceResult(
      destination: host,
      maxHops: maxHops,
      reached: reachedTTL != nil,
      hops: finalHops,
      duration: Date().timeIntervalSince(startWall)
    )
    return result
  }

  /// Perform a traceroute and enrich results with ASN-based categorization.
  ///
  /// This variant computes the client's public IP (via STUN by default unless overridden in config),
  /// resolves origin ASNs for relevant IP addresses using the provided resolver, and labels
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
  ///   - host: Destination hostname or IPv4 address.
  ///   - vpnContext: Context for VPN-aware classification (optional, auto-detected from interface).
  ///   - resolver: ASN resolver implementation (default: uses internal cached resolver).
  /// - Returns: A ClassifiedTrace containing segment labels and (when available) ASN info.
  /// - Throws: `TracerouteError` if resolution or socket operations fail
  public func traceClassified(
    to host: String,
    vpnContext: VPNContext? = nil,
    resolver: ASNResolver? = nil
  ) async throws -> ClassifiedTrace {
    try config.validateForOperation()

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

    // Get or discover public IP with caching
    let effectivePublicIP: String?
    if let configIP = config.publicIP {
      effectivePublicIP = configIP
    } else if let cached = cachedPublicIP {
      effectivePublicIP = cached
    } else if let discovered = try? await discoverPublicIP() {
      cachedPublicIP = discovered
      effectivePublicIP = discovered
    } else {
      effectivePublicIP = nil
    }

    // Perform base trace (includes rDNS if enabled)
    let tr = try await trace(to: host)

    // Resolve destination IP (dual-stack; honors config.preferredFamily).
    let destIP = try resolveHost(host: host, prefer: config.preferredFamily).canonical

    // Collect IPs for batch operations
    var allIPs = Set(tr.hops.compactMap { $0.ipAddress })
    allIPs.insert(destIP)
    if let pip = effectivePublicIP { allIPs.insert(pip) }

    // Get hostnames (either from trace or via rDNS)
    var hostnameMap: [String: String] = [:]
    if !config.noReverseDNS {
      // Get any missing hostnames (destination and public IP)
      let ipsNeedingRDNS = allIPs.filter { ip in
        !tr.hops.contains { $0.ipAddress == ip && $0.hostname != nil }
      }
      if !ipsNeedingRDNS.isEmpty {
        let additionalHostnames = await rdnsCache.batchLookup(Array(ipsNeedingRDNS))
        hostnameMap = additionalHostnames
      }

      // Add hostnames from trace
      for hop in tr.hops {
        if let ip = hop.ipAddress, let hostname = hop.hostname {
          hostnameMap[ip] = hostname
        }
      }
    }

    // Use provided resolver or internal one
    let effectiveResolver = resolver ?? asnResolver

    // Determine VPN context - use provided or auto-detect from interface
    let effectiveVPNContext = vpnContext ?? VPNContext.forInterface(config.interface)

    // Classify with enhanced data
    let classifier = TraceClassifier()
    let baseClassified = try await classifier.classify(
      trace: tr,
      destinationIP: destIP,
      resolver: effectiveResolver,
      timeout: 1.5,
      publicIP: effectivePublicIP,
      interface: config.interface,
      sourceIP: config.sourceIP,
      vpnContext: effectiveVPNContext,
      enableLogging: config.enableLogging
    )

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
        }
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
  /// - Throws: `TracerouteError` on failure (resolution, socket creation, permission issues)
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
  /// Video conferencing is highly sensitive to latency spikes. Zoom/Teams require
  /// <150ms latency and <50ms jitter for good quality.
  ///
  /// **Test Duration:** ~15 seconds (5s baseline + 10s load by default)
  ///
  /// - Parameter config: Bufferbloat test configuration
  /// - Returns: Bufferbloat test results with grading and video call impact assessment
  /// - Throws: `TracerouteError` if ping operations fail
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

    // Run the orchestrator on a detached executor so synchronous phases never block SwiftFTR.
    let runner = BufferbloatRunner(testConfig: config, swiftConfig: self.config)
    return try await runner.runDetached()
  }

  /// Discover public IP via STUN (with DNS fallback)
  internal func discoverPublicIP() async throws -> String {
    let interface = config.interface
    let sourceIP = config.sourceIP
    let enableLogging = config.enableLogging
    return try await runDetachedBlockingIO {
      try getPublicIPv4(
        stunTimeout: 2.0,
        dnsTimeout: 3.0,
        interface: interface,
        sourceIP: sourceIP,
        enableLogging: enableLogging
      ).ip
    }
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

  /// Discover public IP via STUN through the configured (or default) interface.
  ///
  /// Returns both the public IP and its reverse DNS hostname if available.
  /// Use this to understand which exit point your traffic uses for a given interface.
  ///
  /// For multi-path scenarios, create separate `SwiftFTR` instances with different
  /// interface configurations to discover the public IP for each path.
  ///
  /// ## Example
  /// ```swift
  /// // Discover public IP through default interface
  /// let tracer = SwiftFTR()
  /// let (ip, hostname) = try await tracer.discoverPublicIPWithHostname()
  /// print("Exit: \(ip) (\(hostname ?? "no rDNS"))")
  ///
  /// // Discover public IP through VPN
  /// let vpnTracer = SwiftFTR(config: SwiftFTRConfig(interface: "utun3"))
  /// let (vpnIP, vpnHost) = try await vpnTracer.discoverPublicIPWithHostname()
  /// print("VPN exit: \(vpnIP) (\(vpnHost ?? "no rDNS"))")
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

  /// Handle network changes by cancelling active traces and clearing caches.
  ///
  /// Call this method when the network configuration changes (e.g., WiFi to cellular,
  /// VPN connect/disconnect) to ensure fresh data for subsequent traces.
  public func networkChanged() async {
    // Cancel all active traces
    for trace in activeTraces {
      await trace.cancel()
    }
    activeTraces.removeAll()

    // Clear cached public IP
    cachedPublicIP = nil

    // Clear rDNS cache
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
    cachedPublicIP = nil
    await rdnsCache.clear()
  }

  /// Invalidate just the public IP cache.
  ///
  /// Forces re-discovery via STUN on the next trace.
  public func invalidatePublicIP() {
    cachedPublicIP = nil
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
  switch family {
  case AF_INET:
    fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
  case AF_INET6:
    fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
  default:
    throw TracerouteError.socketCreateFailed(
      errno: 0, details: "Unsupported family for trace socket: \(family)")
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

/// Family-aware ICMP send: v4 uses `makeICMPEchoRequest`, v6 uses
/// `makeICMPv6EchoRequest`. Caller resolves destination via `resolveHost`.
internal func sendTraceProbe(
  sockfd: Int32, resolved: ResolvedHost, identifier: UInt16, sequence: UInt16,
  payloadSize: Int
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
  let sent = packet.withUnsafeBytes { raw in
    withUnsafePointer(to: &addr) { ap -> ssize_t in
      ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        sendto(sockfd, raw.baseAddress, raw.count, 0, sa, resolved.addressLen)
      }
    }
  }
  if sent < 0 { throw TracerouteError.sendFailed(errno: errno) }
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

// MARK: - Trace Receive Result

/// Result returned by TraceReceiveOperation.
private struct TraceReceiveResult {
  var hops: [TraceHop?]
  var reachedTTL: Int?
}

/// Shared send info for probe tracking.
private struct TraceSendInfo {
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
  private let sockfd: Int32
  private let family: Int32
  private let identifier: UInt16
  private let maxHops: Int
  private let enableLogging: Bool

  private var outstanding: [UInt16: TraceSendInfo]
  private var hops: [TraceHop?]
  private var reachedTTL: Int?

  private var continuation: CheckedContinuation<TraceReceiveResult, Error>?
  private var readSource: DispatchSourceRead?
  private var timerSource: DispatchSourceTimer?
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
    enableLogging: Bool
  ) {
    self.sockfd = sockfd
    self.family = family
    self.identifier = identifier
    self.outstanding = outstanding
    self.maxHops = maxHops
    self.timeout = timeout
    self.enableLogging = enableLogging
    self.hops = Array(repeating: nil, count: maxHops)
    self.queue = DispatchQueue(
      label: "com.swiftftr.trace.\(UInt64.random(in: 0...UInt64.max))", qos: .userInitiated)
  }

  func start(continuation: CheckedContinuation<TraceReceiveResult, Error>) {
    lock.lock()
    if isFinished {
      lock.unlock()
      continuation.resume(throwing: TracerouteError.cancelled)
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
      self.readSource?.cancel()
      self.timerSource?.cancel()
      self.readSource = nil
      self.timerSource = nil
      currentContinuation?.resume(throwing: TracerouteError.cancelled)
    }
  }

  private func setupSources() {
    // Guard against setup after cancel() already completed
    if checkFinishedSync() { return }

    let source = DispatchSource.makeReadSource(fileDescriptor: sockfd, queue: queue)
    source.setEventHandler { self.handleRead() }
    source.setCancelHandler {}
    source.activate()
    self.readSource = source

    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { self.finish() }
    timer.activate()
    self.timerSource = timer
  }

  private func handleRead() {
    if checkFinishedSync() { return }

    while true {
      guard
        let received = recvTraceMessage(
          sockfd: sockfd, family: family,
          recvBuffer: &recvBuffer, cmsgBuffer: &cmsgBuffer)
      else { break }  // EAGAIN/EWOULDBLOCK or parse-fail
      let parsed = received.parsed

      switch parsed.kind {
      case .echoReply(let id, let seq):
        guard id == identifier else { continue }
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

      case .destinationUnreachable(let originalID, let originalSeq):
        guard originalID == nil || originalID == identifier else { continue }
        if let seq = originalSeq, let info = outstanding.removeValue(forKey: seq) {
          let hopIndex = min(max(info.ttl - 1, 0), maxHops - 1)
          let rtt = monotonicNow() - info.sentAt
          if hops[hopIndex] == nil {
            hops[hopIndex] = TraceHop(
              ttl: info.ttl, ipAddress: parsed.sourceAddress, rtt: rtt, reachedDestination: false)
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

    readSource?.cancel()
    timerSource?.cancel()
    readSource = nil
    timerSource = nil

    guard let continuation = currentContinuation else { return }
    continuation.resume(
      returning: TraceReceiveResult(hops: hops, reachedTTL: reachedTTL))
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
  private let sockfd: Int32
  private let family: Int32
  private let identifier: UInt16
  private let maxHops: Int
  private let payloadSize: Int
  private let resolved: ResolvedHost
  private let streamConfig: StreamingTraceConfig
  private let enableLogging: Bool
  private let yieldHop: (StreamingHop) -> Void

  private var outstanding: [UInt16: TraceSendInfo]
  private var receivedTTLs: Set<Int> = []
  private var reachedTTL: Int?
  private var didRetry = false

  private var continuation: CheckedContinuation<Void, Error>?
  private var readSource: DispatchSourceRead?
  private var deadlineTimer: DispatchSourceTimer?
  private var retryTimer: DispatchSourceTimer?
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
    yield: @escaping (StreamingHop) -> Void
  ) {
    self.sockfd = sockfd
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
  }

  func start(continuation: CheckedContinuation<Void, Error>) {
    lock.lock()
    if isFinished {
      lock.unlock()
      continuation.resume(throwing: TracerouteError.cancelled)
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
      self.readSource?.cancel()
      self.deadlineTimer?.cancel()
      self.retryTimer?.cancel()
      self.readSource = nil
      self.deadlineTimer = nil
      self.retryTimer = nil
      currentContinuation?.resume(throwing: TracerouteError.cancelled)
    }
  }

  private func setupSources() {
    // Guard against setup after cancel() already completed
    if checkFinishedSync() { return }

    // Read source for incoming ICMP responses
    let source = DispatchSource.makeReadSource(fileDescriptor: sockfd, queue: queue)
    source.setEventHandler { self.handleRead() }
    source.setCancelHandler {}
    source.activate()
    self.readSource = source

    // Overall deadline timer
    let deadline = DispatchSource.makeTimerSource(queue: queue)
    deadline.schedule(deadline: .now() + streamConfig.probeTimeout)
    deadline.setEventHandler { self.finish() }
    deadline.activate()
    self.deadlineTimer = deadline

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
    if checkFinishedSync() { return }

    while true {
      guard
        let received = recvTraceMessage(
          sockfd: sockfd, family: family,
          recvBuffer: &recvBuffer, cmsgBuffer: &cmsgBuffer)
      else { break }
      let parsed = received.parsed

      switch parsed.kind {
      case .echoReply(let id, let seq):
        guard id == identifier else { continue }
        if let info = outstanding.removeValue(forKey: seq) {
          if let destTTL = reachedTTL, info.ttl > destTTL { continue }
          let rtt = monotonicNow() - info.sentAt
          if !receivedTTLs.contains(info.ttl) {
            receivedTTLs.insert(info.ttl)
            yieldHop(
              StreamingHop(
                ttl: info.ttl, ipAddress: parsed.sourceAddress, rtt: rtt, reachedDestination: true))
            if reachedTTL == nil || info.ttl < reachedTTL! {
              reachedTTL = info.ttl
            }
          }
        }

      case .timeExceeded(let originalID, let originalSeq):
        guard originalID == nil || originalID == identifier else { continue }
        if let seq = originalSeq {
          emitIntermediateHop(seq: seq, parsed: parsed)
        }

      case .destinationUnreachable(let originalID, let originalSeq):
        guard originalID == nil || originalID == identifier else { continue }
        if let seq = originalSeq {
          emitIntermediateHop(seq: seq, parsed: parsed)
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

  private func emitIntermediateHop(seq: UInt16, parsed: ParsedICMP) {
    guard let info = outstanding[seq] else { return }
    if let destTTL = reachedTTL, info.ttl > destTTL { return }
    if receivedTTLs.contains(info.ttl) { return }

    let rtt = monotonicNow() - info.sentAt
    receivedTTLs.insert(info.ttl)
    yieldHop(
      StreamingHop(
        ttl: info.ttl, ipAddress: parsed.sourceAddress, rtt: rtt, reachedDestination: false))
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

    for ttl in missingTTLs {
      do {
        try setTraceHopLimit(sockfd: sockfd, family: family, ttl: ttl)
      } catch {
        continue
      }
      let seq: UInt16 = UInt16(truncatingIfNeeded: ttl + maxHops)
      let sentAt = monotonicNow()
      do {
        try sendTraceProbe(
          sockfd: sockfd, resolved: resolved, identifier: identifier,
          sequence: seq, payloadSize: payloadSize)
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

    readSource?.cancel()
    deadlineTimer?.cancel()
    retryTimer?.cancel()
    readSource = nil
    deadlineTimer = nil
    retryTimer = nil

    // Emit timeout placeholders for missing TTLs
    if streamConfig.emitTimeouts {
      let cutoff = reachedTTL ?? maxHops
      for ttl in 1...cutoff {
        if !receivedTTLs.contains(ttl) {
          yieldHop(
            StreamingHop(ttl: ttl, ipAddress: nil, rtt: nil, reachedDestination: false))
        }
      }
    }

    if enableLogging {
      print(
        "[SwiftFTR] Streaming trace complete: \(receivedTTLs.count) hops received, reachedTTL=\(reachedTTL.map(String.init) ?? "nil")"
      )
    }

    guard let continuation = currentContinuation else { return }
    continuation.resume()
  }

  private func checkFinishedSync() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return isFinished
  }
}
