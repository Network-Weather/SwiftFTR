import Foundation

// MARK: - Flow Identifier

/// Flow identifier used for Paris/Dublin Traceroute
///
/// Represents the tuple of values that identify a flow through the network.
/// For Paris Traceroute, these values remain constant within a single trace.
/// For Dublin Traceroute, we systematically vary these to discover ECMP paths.
public struct FlowIdentifier: Sendable, Hashable, Codable {
  /// ICMP identifier (16-bit, stable across all TTLs in this flow)
  public let icmpID: UInt16

  /// Variation number that generated this flow ID
  public let variation: Int

  public init(icmpID: UInt16, variation: Int) {
    self.icmpID = icmpID
    self.variation = variation
  }

  /// Generate a stable flow identifier for a given variation
  ///
  /// Uses timestamp + variation to ensure uniqueness across concurrent operations
  /// while maintaining determinism for a given variation number.
  public static func generate(variation: Int) -> FlowIdentifier {
    // Use timestamp as base, add prime-spaced variation
    let timestamp = UInt16(truncatingIfNeeded: UInt64(Date().timeIntervalSince1970 * 1000))
    let variedID = timestamp &+ UInt16(variation * 173)  // Prime spacing

    return FlowIdentifier(icmpID: variedID, variation: variation)
  }
}

// MARK: - Multipath Configuration

/// Configuration for multipath discovery (Dublin Traceroute)
public struct MultipathConfig: Sendable {
  /// Number of different flow identifiers to try (default: 8)
  public let flowVariations: Int

  /// Maximum unique paths to discover before stopping (default: 16)
  public let maxPaths: Int

  /// Stop early if same path seen consecutively N times (default: 3)
  public let earlyStopThreshold: Int

  /// Timeout per flow variation in milliseconds (default: 2000)
  public let timeoutMs: Int

  /// Maximum TTL/hops to probe (default: 30)
  public let maxHops: Int

  public init(
    flowVariations: Int = 8,
    maxPaths: Int = 16,
    earlyStopThreshold: Int = 3,
    timeoutMs: Int = 2000,
    maxHops: Int = 30
  ) {
    self.flowVariations = flowVariations
    self.maxPaths = maxPaths
    self.earlyStopThreshold = earlyStopThreshold
    self.timeoutMs = timeoutMs
    self.maxHops = maxHops
  }
}

// MARK: - Network Topology

/// Network topology with discovered paths
///
/// Represents the complete set of paths discovered to a destination,
/// with utility methods for extracting monitoring targets and analyzing
/// path diversity.
public struct NetworkTopology: Sendable, Codable {
  /// Destination host
  public let destination: String

  /// Resolved destination IP
  public let destinationIP: String

  /// Source adapter interface (e.g., "en0")
  public let sourceAdapter: String?

  /// Source IP address
  public let sourceIP: String?

  /// Public IP (from STUN)
  public let publicIP: String?

  /// All discovered paths (may contain duplicates if fingerprints match)
  public let paths: [DiscoveredPath]

  /// Number of unique paths (by fingerprint)
  public let uniquePathCount: Int

  /// Total time spent discovering paths
  public let discoveryDuration: TimeInterval

  public init(
    destination: String,
    destinationIP: String,
    sourceAdapter: String?,
    sourceIP: String?,
    publicIP: String?,
    paths: [DiscoveredPath],
    uniquePathCount: Int,
    discoveryDuration: TimeInterval
  ) {
    self.destination = destination
    self.destinationIP = destinationIP
    self.sourceAdapter = sourceAdapter
    self.sourceIP = sourceIP
    self.publicIP = publicIP
    self.paths = paths
    self.uniquePathCount = uniquePathCount
    self.discoveryDuration = discoveryDuration
  }

  /// Extract all unique hops across all paths (for monitoring)
  ///
  /// Returns deduplicated list of hops sorted by TTL, then IP.
  /// Useful for extracting monitoring targets after multipath discovery.
  public func uniqueHops() -> [ClassifiedHop] {
    var seen: Set<String> = []
    var unique: [ClassifiedHop] = []

    for path in paths {
      for hop in path.trace.hops {
        guard let ip = hop.ip, !seen.contains(ip) else { continue }
        seen.insert(ip)
        unique.append(hop)
      }
    }

    // Sort by TTL, then IP for stable ordering
    return unique.sorted { ($0.ttl, $0.ip ?? "") < ($1.ttl, $1.ip ?? "") }
  }

  /// Find TTL where paths diverge (ECMP split point)
  ///
  /// Returns the first TTL where different paths have different IPs.
  /// Timeouts (nil IPs) are treated as distinct values.
  /// Returns nil if all paths are identical or only one path exists.
  public func divergencePoint() -> Int? {
    // No divergence if only one unique path
    guard uniquePathCount > 1 else { return nil }

    let maxTTL = paths.map { $0.trace.hops.count }.max() ?? 0

    for ttl in 1...maxTTL {
      let ipsAtTTL = Set(
        paths.map { path in
          path.trace.hops.first(where: { $0.ttl == ttl })?.ip ?? "*"
        })

      if ipsAtTTL.count > 1 {
        return ttl
      }
    }

    return nil
  }

  /// Get common path prefix (shared by all paths)
  ///
  /// Returns hops that appear in the same position across all paths.
  /// Stops at first divergence.
  public func commonPrefix() -> [ClassifiedHop] {
    guard let firstPath = paths.first else { return [] }

    var prefix: [ClassifiedHop] = []

    for (index, hop) in firstPath.trace.hops.enumerated() {
      // Check if all paths have same IP at this position
      let allMatch = paths.allSatisfy { path in
        guard index < path.trace.hops.count else { return false }
        return path.trace.hops[index].ip == hop.ip
      }

      if allMatch {
        prefix.append(hop)
      } else {
        break
      }
    }

    return prefix
  }

  /// Get paths that traverse a specific hop IP
  public func paths(throughIP ip: String) -> [DiscoveredPath] {
    paths.filter { path in
      path.trace.hops.contains { $0.ip == ip }
    }
  }

  /// Get paths that traverse a specific ASN
  public func paths(throughASN asn: Int) -> [DiscoveredPath] {
    paths.filter { path in
      path.trace.hops.contains { $0.asn == asn }
    }
  }
}

// MARK: - Discovered Path

/// A single discovered path with its flow identifier
public struct DiscoveredPath: Sendable, Codable {
  /// Flow identifier that produced this path
  public let flowIdentifier: FlowIdentifier

  /// The classified trace for this path
  public let trace: ClassifiedTrace

  /// Path fingerprint (IP sequence) for deduplication
  public let fingerprint: String

  /// Whether this path is unique (first time this fingerprint was seen)
  public let isUnique: Bool

  public init(
    flowIdentifier: FlowIdentifier,
    trace: ClassifiedTrace,
    fingerprint: String,
    isUnique: Bool
  ) {
    self.flowIdentifier = flowIdentifier
    self.trace = trace
    self.fingerprint = fingerprint
    self.isUnique = isUnique
  }
}

// MARK: - Multipath Discovery Actor

/// Dublin Traceroute implementation for ECMP path enumeration
///
/// ## ICMP vs UDP Path Discovery
///
/// This implementation uses **ICMP Echo Request** packets with varying ICMP ID fields
/// to discover multiple paths. This has important implications:
///
/// **ICMP-based discovery (current implementation):**
/// - Varies ICMP ID field for flow identification
/// - Shows paths that ICMP packets actually traverse
/// - Many ECMP routers **do not hash ICMP ID field** or route all ICMP on single path
/// - Typically finds **fewer unique paths** than UDP-based methods
/// - Advantage: No special permissions required (uses SOCK_DGRAM)
/// - Use case: Accurate for ping/monitoring path discovery
///
/// **UDP-based discovery (future enhancement, see ROADMAP.md):**
/// - Varies UDP destination port for flow identification
/// - ECMP routers hash full UDP 5-tuple (src/dst IP + src/dst port + protocol)
/// - Typically finds **more unique paths** due to better ECMP hashing
/// - Disadvantage: Requires raw sockets and elevated privileges
/// - Use case: TCP/UDP application path discovery
///
/// **Real-world example:** Dublin-traceroute (UDP) found 7 unique paths to 8.8.8.8,
/// while this implementation found 1 path. Both are correct - they show different
/// protocols' actual routing behavior.
///
/// For monitoring ICMP reachability (ping), ICMP-based discovery is more accurate.
/// For monitoring TCP/UDP application traffic, UDP-based discovery would be preferred.
struct MultipathDiscovery: Sendable {
  private let workerSpawner: SwiftFTR.MultipathWorkerSpawner
  private let config: SwiftFTRConfig
  private let debugTracing: Bool

  init(workerSpawner: SwiftFTR.MultipathWorkerSpawner, config: SwiftFTRConfig) {
    self.workerSpawner = workerSpawner
    self.config = config
    self.debugTracing =
      ProcessInfo.processInfo.environment["SWIFTFTR_DEBUG_MULTIPATH"] != nil
  }

  /// Discover all ECMP paths to target
  func discoverPaths(to target: String, multipathConfig: MultipathConfig) async throws
    -> NetworkTopology
  {
    let startTime = monotonicTime()
    let parentStart = startTime

    var discoveredPaths: [DiscoveredPath] = []
    var canonicalPaths: [ClassifiedTrace] = []  // Unique paths with holes filled
    var recentlyUnique: [Bool] = []  // For early stopping

    // Parallel flow variations with early stopping support
    // Process flows in batches to enable early termination while maintaining parallelism
    let batchSize = 5  // Balance parallelism vs early stopping responsiveness
    var variation = 0
    let spawner = workerSpawner

    while variation < multipathConfig.flowVariations {
      let batchEnd = min(variation + batchSize, multipathConfig.flowVariations)
      var batchResults: [(FlowIdentifier, ClassifiedTrace)] = []

      // Launch batch of flows in parallel
      try await withThrowingTaskGroup(
        of: (FlowIdentifier, ClassifiedTrace).self
      ) { group in
        for v in variation..<batchEnd {
          let flowID = FlowIdentifier.generate(variation: v)

          group.addTask {
            let launch = self.debugTracing ? self.monotonicTime() : 0.0
            let task = spawner.scheduleMultipathFlowTask(
              target: target,
              flowID: flowID,
              maxHops: multipathConfig.maxHops,
              timeoutMs: multipathConfig.timeoutMs
            )
            let result = try await task.value
            if self.debugTracing {
              let done = self.monotonicTime()
              let offset = launch - parentStart
              let duration = done - launch
              print(
                "[multipath] flow \(v) launched +\(String(format: "%.3f", offset))s duration \(String(format: "%.3f", duration))s"
              )
            }
            return result
          }
        }

        // Collect batch results
        for try await result in group {
          batchResults.append(result)
        }
      }

      // Process batch results
      for (flowID, trace) in batchResults {
        // Check if this path matches any existing canonical path
        var matchedIndex: Int? = nil
        for (index, canonical) in canonicalPaths.enumerated() {
          if pathsMatch(trace, canonical) {
            matchedIndex = index
            break
          }
        }

        let isUnique: Bool
        let fingerprint = computeFingerprint(trace)

        if let index = matchedIndex {
          // Path matches existing canonical - merge them
          canonicalPaths[index] = mergePaths(canonicalPaths[index], trace)
          isUnique = false
        } else {
          // New unique path
          canonicalPaths.append(trace)
          isUnique = true
        }

        discoveredPaths.append(
          DiscoveredPath(
            flowIdentifier: flowID,
            trace: trace,
            fingerprint: fingerprint,
            isUnique: isUnique
          ))

        // Early stopping check - track recent uniqueness
        recentlyUnique.append(isUnique)
        if recentlyUnique.count > multipathConfig.earlyStopThreshold {
          recentlyUnique.removeFirst()
        }
      }

      variation = batchEnd

      // Check early stopping conditions
      if recentlyUnique.count == multipathConfig.earlyStopThreshold
        && !recentlyUnique.contains(true)
      {
        // No unique paths in last N attempts, likely no more diversity
        break
      }

      if canonicalPaths.count >= multipathConfig.maxPaths {
        // Reached max unique paths limit
        break
      }
    }

    let duration = monotonicTime() - startTime

    return NetworkTopology(
      destination: target,
      destinationIP: discoveredPaths.first?.trace.destinationIP ?? target,
      sourceAdapter: config.interface,
      sourceIP: config.sourceIP,
      publicIP: discoveredPaths.first?.trace.publicIP,
      paths: discoveredPaths,
      uniquePathCount: canonicalPaths.count,
      discoveryDuration: duration
    )
  }

  /// Compute IP-level path fingerprint
  private func computeFingerprint(_ trace: ClassifiedTrace) -> String {
    // IP sequence with timeout markers
    trace.hops.map { hop in
      hop.ip ?? "*"  // Use "*" for timeouts to distinguish from missing
    }.joined(separator: ",")
  }

  /// Check if two paths match, allowing timeouts to match with IPs
  ///
  /// Paths match if they have the same length and at each position:
  /// - Both have the same IP, OR
  /// - At least one has a timeout (nil)
  ///
  /// This accounts for routers that inconsistently respond to ICMP TTL Exceeded.
  private func pathsMatch(_ trace1: ClassifiedTrace, _ trace2: ClassifiedTrace) -> Bool {
    guard trace1.hops.count == trace2.hops.count else { return false }

    for i in 0..<trace1.hops.count {
      let ip1 = trace1.hops[i].ip
      let ip2 = trace2.hops[i].ip

      // If both have IPs, they must match exactly
      if let ip1 = ip1, let ip2 = ip2 {
        if ip1 != ip2 {
          return false
        }
      }
      // If one or both is nil (timeout), consider them matching
      // This handles intermittent ICMP responders
    }

    return true
  }

  /// Merge two matching paths by filling in timeouts with discovered IPs
  ///
  /// Returns a new trace with the canonical path where timeouts are filled
  /// with IPs from the other trace when available.
  private func mergePaths(_ canonical: ClassifiedTrace, _ new: ClassifiedTrace) -> ClassifiedTrace {
    var mergedHops = canonical.hops

    for i in 0..<mergedHops.count {
      // If canonical has timeout but new has IP, fill it in
      if mergedHops[i].ip == nil && new.hops[i].ip != nil {
        mergedHops[i] = new.hops[i]
      }
    }

    return ClassifiedTrace(
      destinationHost: canonical.destinationHost,
      destinationIP: canonical.destinationIP,
      destinationHostname: canonical.destinationHostname,
      publicIP: canonical.publicIP,
      publicHostname: canonical.publicHostname,
      clientASN: canonical.clientASN,
      clientASName: canonical.clientASName,
      destinationASN: canonical.destinationASN,
      destinationASName: canonical.destinationASName,
      hops: mergedHops
    )
  }

  private func monotonicTime() -> TimeInterval {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    let numer = TimeInterval(info.numer)
    let denom = TimeInterval(info.denom)
    let rawTime = TimeInterval(mach_absolute_time())
    return (rawTime * numer / denom) / 1_000_000_000.0
  }
}

// MARK: - SwiftFTR Extension

extension SwiftFTR {
  /// Discover multiple paths to target using Dublin Traceroute
  ///
  /// Systematically varies flow identifiers to enumerate ECMP paths.
  /// Uses sequential flow variation (one flow at a time) with parallel
  /// TTL probing within each flow (maintaining Paris consistency).
  ///
  /// - Parameters:
  ///   - target: Hostname or IP to trace
  ///   - config: Multipath discovery configuration
  /// - Returns: Network topology with all discovered paths
  /// - Throws: `TracerouteError` on failure
  ///
  /// - Important: This implementation uses **ICMP Echo Request** packets with varying
  ///   ICMP ID fields. Many ECMP routers do not hash ICMP fields, so this may find
  ///   fewer paths than UDP-based methods. The discovered paths accurately represent
  ///   ICMP routing behavior, which is ideal for ping monitoring. For TCP/UDP
  ///   application path discovery, a future UDP-based implementation would be preferred.
  ///
  /// ## Example
  /// ```swift
  /// let config = MultipathConfig(flowVariations: 8, maxPaths: 16)
  /// let topology = try await ftr.discoverPaths(to: "example.com", config: config)
  ///
  /// print("Found \(topology.uniquePathCount) unique paths")
  ///
  /// // Extract monitoring targets
  /// let targets = topology.uniqueHops()
  /// for hop in targets {
  ///     let result = try await ftr.ping(to: hop.ip, config: .init(count: 5))
  ///     // Process metrics...
  /// }
  /// ```
  public func discoverPaths(
    to target: String,
    config: MultipathConfig = MultipathConfig()
  ) async throws -> NetworkTopology {
    let swiftConfig = self.config
    let spawner = MultipathWorkerSpawner(
      baseConfig: swiftConfig,
      rdnsCache: self.rdnsCache,
      asnResolver: self.asnResolver,
      cachedPublicIP: self.cachedPublicIP
    )
    let discovery = MultipathDiscovery(workerSpawner: spawner, config: swiftConfig)

    // Run the multipath orchestration detached so scheduling cannot re-enter SwiftFTR.
    return try await Task.detached(priority: .userInitiated) {
      try await discovery.discoverPaths(to: target, multipathConfig: config)
    }.value
  }

  /// Provides detached worker tasks that reuse caches but never hop back to the main actor.
  struct MultipathWorkerSpawner: Sendable {
    let baseConfig: SwiftFTRConfig
    let rdnsCache: RDNSCache
    let asnResolver: ASNResolver
    let cachedPublicIP: String?

    func scheduleMultipathFlowTask(
      target: String,
      flowID: FlowIdentifier,
      maxHops: Int,
      timeoutMs: Int
    ) -> Task<(FlowIdentifier, ClassifiedTrace), Error> {
      let workerConfig = SwiftFTRConfig(
        maxHops: maxHops,
        maxWaitMs: timeoutMs,
        payloadSize: baseConfig.payloadSize,
        publicIP: baseConfig.publicIP,
        enableLogging: baseConfig.enableLogging,
        noReverseDNS: baseConfig.noReverseDNS,
        interface: baseConfig.interface,
        sourceIP: baseConfig.sourceIP
      )

      let cachedIP = baseConfig.publicIP ?? cachedPublicIP
      let rdns = rdnsCache
      let resolver = asnResolver

      return Task.detached(priority: .userInitiated) {
        let worker = SwiftFTR(
          config: workerConfig,
          rdnsCache: rdns,
          asnResolver: resolver,
          cachedPublicIP: cachedIP
        )
        let trace = try await worker.performClassifiedTraceWithFlowID(
          to: target,
          flowIdentifier: flowID.icmpID
        )
        return (flowID, trace)
      }
    }
  }

  /// Internal method to run classified trace with specific flow identifier
  ///
  /// Used by multipath discovery to run Paris Traceroute with controlled flow IDs.
  /// Creates a temporary SwiftFTR instance with multipath-specific config.
  func traceClassifiedWithFlowID(
    to target: String,
    flowID: FlowIdentifier,
    maxHops: Int,
    timeoutMs: Int
  ) async throws -> ClassifiedTrace {
    // Create temporary SwiftFTR instance with multipath config
    let multipathConfig = SwiftFTRConfig(
      maxHops: maxHops,
      maxWaitMs: timeoutMs,
      payloadSize: self.config.payloadSize,
      publicIP: self.config.publicIP,
      enableLogging: self.config.enableLogging,
      noReverseDNS: self.config.noReverseDNS,
      interface: self.config.interface,
      sourceIP: self.config.sourceIP
    )

    let tempTracer = SwiftFTR(
      config: multipathConfig,
      rdnsCache: self.rdnsCache,
      asnResolver: self.asnResolver,
      cachedPublicIP: self.cachedPublicIP
    )

    return try await tempTracer.performClassifiedTraceWithFlowID(
      to: target,
      flowIdentifier: flowID.icmpID
    )
  }

  /// Internal implementation of classified trace with flow ID
  fileprivate func performClassifiedTraceWithFlowID(
    to host: String,
    flowIdentifier: UInt16
  ) async throws -> ClassifiedTrace {
    // Similar to traceClassified but with flow ID override
    let handle = TraceHandle()
    activeTraces.insert(handle)
    defer { activeTraces.remove(handle) }

    // Validate interface early if specified
    if let interfaceName = config.interface {
      _ = try validateInterface(interfaceName)
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

    // Perform base trace with flow ID
    let tr = try await withTaskCancellationHandler {
      try await performTrace(to: host, handle: handle, flowIdentifier: flowIdentifier)
    } onCancel: {
      Task { await handle.cancel() }
    }

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
      // Get any missing hostnames
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

    // Use internal ASN resolver
    let effectiveResolver = asnResolver

    // Classify
    let classifier = TraceClassifier()
    let baseClassified = try await classifier.classify(
      trace: tr,
      destinationIP: destIP,
      resolver: effectiveResolver,
      timeout: 1.5,
      publicIP: effectivePublicIP,
      interface: config.interface,
      sourceIP: config.sourceIP,
      enableLogging: config.enableLogging
    )

    // Enhance classified result with hostnames
    let enhancedHops = baseClassified.hops.map { hop -> ClassifiedHop in
      let hostname: String?
      if let hopIP = hop.ip {
        if let mapped = hostnameMap[hopIP] {
          hostname = mapped
        } else {
          hostname = tr.hops.first { $0.ipAddress == hopIP }?.hostname
        }
      } else {
        hostname = nil
      }

      return ClassifiedHop(
        ttl: hop.ttl,
        ip: hop.ip,
        rtt: hop.rtt,
        asn: hop.asn,
        asName: hop.asName,
        category: hop.category,
        hostname: hostname
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
}
