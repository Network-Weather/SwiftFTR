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

  @available(*, deprecated, message: "Use ipAddress instead", renamed: "ipAddress")
  public var host: String? { ipAddress }
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
public struct SwiftFTRConfig: Sendable {
  /// Maximum TTL/hops to probe (default: 30)
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

  public init(
    maxHops: Int = 30,
    maxWaitMs: Int = 1000,
    payloadSize: Int = 56,
    publicIP: String? = nil,
    enableLogging: Bool = false,
    noReverseDNS: Bool = false,
    rdnsCacheTTL: TimeInterval? = nil,
    rdnsCacheSize: Int? = nil
  ) {
    self.maxHops = maxHops
    self.maxWaitMs = maxWaitMs
    self.payloadSize = payloadSize
    self.publicIP = publicIP
    self.enableLogging = enableLogging
    self.noReverseDNS = noReverseDNS
    self.rdnsCacheTTL = rdnsCacheTTL
    self.rdnsCacheSize = rdnsCacheSize
  }
}

/// Top-level entry point for performing fast, parallel traceroutes.
///
/// SwiftFTR is an actor providing thread-safe traceroute operations with
/// built-in caching for rDNS lookups and STUN public IP discovery.
@available(macOS 13.0, *)
public actor SwiftFTR {
  private var config: SwiftFTRConfig

  // Cache storage
  private var cachedPublicIP: String?
  private let rdnsCache: RDNSCache
  private let asnResolver: ASNResolver

  // Active trace tracking
  private var activeTraces: Set<TraceHandle> = []

  /// Creates a tracer instance with optional configuration.
  /// - Parameter config: Configuration for traceroute behavior
  public init(config: SwiftFTRConfig = SwiftFTRConfig()) {
    self.config = config
    self.rdnsCache = RDNSCache(
      ttl: config.rdnsCacheTTL ?? 86400,
      maxSize: config.rdnsCacheSize ?? 1000
    )
    self.asnResolver = CachingASNResolver(base: CymruDNSResolver())
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

  // Internal implementation of trace with cancellation support
  private func performTrace(
    to host: String,
    handle: TraceHandle
  ) async throws -> TraceResult {
    let maxHops = config.maxHops
    let timeout = TimeInterval(config.maxWaitMs) / 1000.0
    let payloadSize = config.payloadSize

    if config.enableLogging {
      print(
        "[SwiftFTR] Starting trace to \(host) with maxHops=\(maxHops), timeout=\(timeout)s, payloadSize=\(payloadSize)"
      )
    }
    // Resolve host (IPv4 only)
    let destAddr = try resolveIPv4(host: host, enableLogging: config.enableLogging)

    // Create ICMP datagram socket (no root required on macOS)
    if config.enableLogging {
      print("[SwiftFTR] Creating ICMP datagram socket...")
    }

    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    if fd < 0 {
      let error = errno
      let details =
        "This typically indicates: (1) Platform doesn't support ICMP datagram sockets, (2) Network permissions denied, (3) Running in sandbox without network entitlement. On macOS, this should work without root privileges."
      throw TracerouteError.socketCreateFailed(errno: error, details: details)
    }

    if config.enableLogging {
      print("[SwiftFTR] Socket created successfully (fd=\(fd))")
    }
    defer { close(fd) }

    // Set non-blocking: avoid blocking recvfrom; we use poll(2) for readiness.
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

    // Enable receiving TTL of replies (best-effort). Some stacks may not support IP_RECVTTL; this is non-fatal
    // and only affects extra metadata, not core correctness.
    var on: Int32 = 1
    if setsockopt(fd, IPPROTO_IP, IP_RECVTTL, &on, socklen_t(MemoryLayout<Int32>.size)) != 0 {
      // Not fatal; ignore
    }

    // Use a random identifier per run
    let identifier = UInt16.random(in: 0...UInt16.max)

    // Tracking maps
    struct SendInfo {
      let ttl: Int
      let sentAt: TimeInterval
    }
    var outstanding: [UInt16: SendInfo] = [:]  // key = sequence (== ttl)

    // Send one probe per TTL, quickly adjusting IP_TTL between sends.
    if config.enableLogging {
      print("[SwiftFTR] Sending \(maxHops) probes...")
    }

    for ttl in 1...maxHops {
      var ttlVar: Int32 = Int32(ttl)
      if setsockopt(fd, IPPROTO_IP, IP_TTL, &ttlVar, socklen_t(MemoryLayout<Int32>.size)) != 0 {
        throw TracerouteError.setsockoptFailed(option: "IP_TTL", errno: errno)
      }
      let seq: UInt16 = UInt16(truncatingIfNeeded: ttl)
      let packet = makeICMPEchoRequest(
        identifier: identifier, sequence: seq, payloadSize: payloadSize)
      let sentAt = monotonicNow()
      var addr = destAddr
      let sent = packet.withUnsafeBytes { rawBuf in
        withUnsafePointer(to: &addr) { aptr -> ssize_t in
          aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            sendto(
              fd, rawBuf.baseAddress!, rawBuf.count, 0, saPtr,
              socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
      }
      if sent < 0 { throw TracerouteError.sendFailed(errno: errno) }
      outstanding[seq] = SendInfo(ttl: ttl, sentAt: sentAt)
    }

    // Prepare hops
    var hops: [TraceHop?] = Array(repeating: nil, count: maxHops)
    var reachedTTL: Int? = nil

    // Global deadline for the receive loop. We probe all TTLs up-front,
    // then wait until either all earlier hops are filled or the timeout hits.
    let startWall = Date()
    let deadline = monotonicNow() + timeout

    if config.enableLogging {
      print("[SwiftFTR] Entering receive loop, deadline in \(timeout)s...")
    }
    var storage = sockaddr_storage()
    // Use a named constant to avoid magic numbers for buffer sizes.
    var buf = [UInt8](repeating: 0, count: Constants.receiveBufferSize)

    // Receive loop until timeout or all TTLs resolved up to reachedTTL.
    // The loop uses poll(2) to wait for readability and then drains datagrams.
    recvLoop: while monotonicNow() < deadline {
      // Check if cancelled
      if await handle.isCancelled {
        throw TracerouteError.cancelled
      }

      var fds = Darwin.pollfd(fd: fd, events: Int16(Darwin.POLLIN), revents: 0)
      // Use shorter poll timeout for responsive cancellation (max 100ms)
      let msLeft = Int32(min(100, max(0, (deadline - monotonicNow()) * 1000)))
      let rv = withUnsafeMutablePointer(to: &fds) { p in Darwin.poll(p, 1, msLeft) }
      if rv == 0 { continue }  // Timeout - check cancellation and continue
      if rv < 0 { break }  // Error

      // Drain available datagrams
      while true {
        var addrlen: socklen_t = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let n = withUnsafeMutablePointer(to: &storage) { sptr -> ssize_t in
          sptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
            return recvfrom(fd, &buf, buf.count, 0, saptr, &addrlen)
          }
        }
        if n < 0 {
          if errno == EWOULDBLOCK || errno == EAGAIN { break } else { break }
        }
        let parsedOpt: ParsedICMP? = buf.withUnsafeBytes { rawPtr in
          let slice = UnsafeRawBufferPointer(rebasing: rawPtr.prefix(Int(n)))
          return parseICMPv4Message(buffer: slice, from: storage)
        }
        guard let parsed = parsedOpt else { continue }

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
            // Destination unreachable could mean we've hit the dest depending on method, but for ICMP echo it usually signals admin blocks; keep going
          }
        case .other:
          continue
        }

        // Stop early if we reached destination and resolved all earlier hops (or timed out)
        if let rttl = reachedTTL {
          var done = true
          for i in 0..<(rttl) {
            if hops[i] == nil {
              done = false
              break
            }
          }
          if done { break recvLoop }
        }
      }
    }

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
  /// - Parameters:
  ///   - host: Destination hostname or IPv4 address.
  ///   - resolver: ASN resolver implementation (default: uses internal cached resolver).
  /// - Returns: A ClassifiedTrace containing segment labels and (when available) ASN info.
  /// - Throws: `TracerouteError` if resolution or socket operations fail
  public func traceClassified(
    to host: String,
    resolver: ASNResolver? = nil
  ) async throws -> ClassifiedTrace {
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

    // Resolve destination IP
    let destAddr = try resolveIPv4(host: host, enableLogging: config.enableLogging)
    let destIP = ipString(destAddr)

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

    // Classify with enhanced data
    let classifier = TraceClassifier()
    let baseClassified = try classifier.classify(
      trace: tr,
      destinationIP: destIP,
      resolver: effectiveResolver,
      timeout: 1.5,
      publicIP: effectivePublicIP
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

  /// Discover public IP via STUN
  private func discoverPublicIP() async throws -> String {
    try stunGetPublicIPv4(timeout: 0.8).ip
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

// Helpers
private func resolveIPv4(host: String, enableLogging: Bool = false) throws -> sockaddr_in {
  if enableLogging {
    print("[SwiftFTR] Resolving host: \(host)")
  }
  // Try numeric IPv4 first (fast path, works without DNS)
  var addr = sockaddr_in()
  addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
  addr.sin_family = sa_family_t(AF_INET)
  if host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 {
    return addr
  }

  // Fall back to getaddrinfo for names
  var hints = addrinfo(
    ai_flags: AI_ADDRCONFIG,
    ai_family: AF_INET,
    ai_socktype: 0,
    ai_protocol: 0,
    ai_addrlen: 0,
    ai_canonname: nil,
    ai_addr: nil,
    ai_next: nil
  )
  var res: UnsafeMutablePointer<addrinfo>? = nil
  let err = getaddrinfo(host, nil, &hints, &res)
  guard err == 0, let info = res else {
    let details =
      err != 0
      ? "getaddrinfo error: \(String(cString: gai_strerror(err)))" : "Failed to get address info"
    throw TracerouteError.resolutionFailed(host: host, details: details)
  }
  defer { freeaddrinfo(info) }
  if info.pointee.ai_family == AF_INET, let sa = info.pointee.ai_addr {
    memcpy(&addr, sa, min(MemoryLayout<sockaddr_in>.size, Int(info.pointee.ai_addrlen)))
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa.pointee.sa_family
    return addr
  }
  throw TracerouteError.resolutionFailed(
    host: host, details: "Host resolved but no IPv4 address available")
}

// Use Darwin.poll and Darwin.pollfd directly

private enum Constants {
  /// Receive buffer size for incoming ICMP datagrams.
  static let receiveBufferSize = 2048
}
