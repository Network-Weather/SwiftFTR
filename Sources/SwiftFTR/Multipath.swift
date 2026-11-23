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
    let variedID = timestamp &+ UInt16(truncatingIfNeeded: variation &* 173)  // Prime spacing

    return FlowIdentifier(icmpID: variedID, variation: variation)
  }
}

// MARK: - Multipath Configuration

/// Configuration for multipath discovery (Dublin Traceroute).
///
/// Values are validated by ``SwiftFTR/discoverPaths(to:config:)`` before discovery starts.
public struct MultipathConfig: Sendable {
  /// Number of different flow identifiers to try (default: 8)
  public let flowVariations: Int

  /// Maximum unique paths to discover before stopping (default: 16)
  public let maxPaths: Int

  /// Stop early if same path seen consecutively N times (default: 3)
  public let earlyStopThreshold: Int

  /// Timeout per flow variation in milliseconds (default: 2000)
  public let timeoutMs: Int

  /// Maximum TTL/hops to probe (default: 40)
  public let maxHops: Int

  public init(
    flowVariations: Int = 8,
    maxPaths: Int = 16,
    earlyStopThreshold: Int = 3,
    timeoutMs: Int = 2000,
    maxHops: Int = 40
  ) {
    self.flowVariations = flowVariations
    self.maxPaths = maxPaths
    self.earlyStopThreshold = earlyStopThreshold
    self.timeoutMs = timeoutMs
    self.maxHops = maxHops
  }
}

/// Multipath probing currently varies IPv4 ICMP identifiers. Reject an
/// incompatible family before launching flow workers so every flow uses
/// the same address family as its configured source.
internal func validateMultipathAddressFamily(_ config: SwiftFTRConfig) throws {
  if case .v6 = config.preferredFamily {
    throw TracerouteError.invalidConfiguration(
      reason: "Multipath discovery currently supports IPv4 destinations only")
  }
  if let sourceIP = config.sourceIP, detectAddressFamily(sourceIP) == AF_INET6 {
    throw TracerouteError.invalidConfiguration(
      reason: "Multipath discovery requires an IPv4 source address")
  }
}

extension SwiftFTRConfig {
  /// Fields a multipath flow worker sets itself rather than taking from the caller's
  /// configuration: the flow's own hop limit and per-probe wait (from `MultipathConfig`), and the
  /// address family, forced to IPv4 because flows vary IPv4 ICMP identifiers (see
  /// ``validateMultipathAddressFamily(_:)``).
  static let multipathFlowOverrides: Set<String> = ["maxHops", "maxWaitMs", "preferredFamily"]

  /// The configuration one multipath flow runs with: this one, field for field, except
  /// ``multipathFlowOverrides``.
  ///
  /// `SwiftFTRConfig`'s stored properties are constants, so the copy is spelled out here.
  /// `MultipathWorkerConfigTests` compares every stored property of the result with the caller's
  /// and fails when a field is added to `SwiftFTRConfig` without being carried over.
  func multipathFlowConfig(maxHops: Int, timeoutMs: Int) -> SwiftFTRConfig {
    SwiftFTRConfig(
      maxHops: maxHops,
      maxWaitMs: timeoutMs,
      payloadSize: payloadSize,
      publicIP: publicIP,
      enableLogging: enableLogging,
      noReverseDNS: noReverseDNS,
      rdnsCacheTTL: rdnsCacheTTL,
      rdnsCacheSize: rdnsCacheSize,
      rdnsLookupTimeout: rdnsLookupTimeout,
      publicIPDiscoveryTimeout: publicIPDiscoveryTimeout,
      interface: interface,
      sourceIP: sourceIP,
      asnResolverStrategy: asnResolverStrategy,
      preferredFamily: .v4,
      publicIPResolver: publicIPResolver
    )
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

  /// Caller-selected BSD source interface, or `nil` when system routing was used.
  public let sourceAdapter: String?

  /// Source IP address
  public let sourceIP: String?

  /// Public address every path was classified with: configured, seeded, cached, or the answer to
  /// the one question the run asked before its first batch.
  public let publicIP: String?

  /// Where ``publicIP`` came from, or `nil` when there is none. See
  /// ``ClassifiedTrace/publicIPSource``.
  public let publicIPSource: PublicIPObservationSource?

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
    self.init(
      destination: destination, destinationIP: destinationIP, sourceAdapter: sourceAdapter,
      sourceIP: sourceIP, publicIP: publicIP, publicIPSource: nil, paths: paths,
      uniquePathCount: uniquePathCount, discoveryDuration: discoveryDuration)
  }

  /// Creates a topology whose public address names its source.
  public init(
    destination: String,
    destinationIP: String,
    sourceAdapter: String?,
    sourceIP: String?,
    publicIP: String?,
    publicIPSource: PublicIPObservationSource?,
    paths: [DiscoveredPath],
    uniquePathCount: Int,
    discoveryDuration: TimeInterval
  ) {
    self.destination = destination
    self.destinationIP = destinationIP
    self.sourceAdapter = sourceAdapter
    self.sourceIP = sourceIP
    self.publicIP = publicIP
    self.publicIPSource = publicIPSource
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
    guard maxTTL > 0 else { return nil }

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

// MARK: - Multipath Discovery

protocol MultipathFlowRunning: Sendable {
  func runMultipathFlow(
    target: String,
    flowID: FlowIdentifier,
    maxHops: Int,
    timeoutMs: Int
  ) async throws -> (FlowIdentifier, ClassifiedTrace)
}

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
struct MultipathDiscovery<Worker: MultipathFlowRunning>: Sendable {
  private let worker: Worker
  private let config: SwiftFTRConfig
  /// The parent's answer to the public-address question, handed to every flow.
  private let publicIP: PublicIPObservation?
  private let debugTracing: Bool

  init(worker: Worker, config: SwiftFTRConfig, publicIP: PublicIPObservation? = nil) {
    self.worker = worker
    self.config = config
    self.publicIP = publicIP
    self.debugTracing =
      ProcessInfo.processInfo.environment["SWIFTFTR_DEBUG_MULTIPATH"] != nil
  }

  /// Discover all ECMP paths to target
  func discoverPaths(to target: String, multipathConfig: MultipathConfig) async throws
    -> NetworkTopology
  {
    try Task.checkCancellation()

    let startTime = monotonicTime()
    let parentStart = startTime

    var discoveredPaths: [DiscoveredPath] = []
    var canonicalPaths: [ClassifiedTrace] = []  // Unique paths with holes filled
    var recentlyUnique: [Bool] = []  // For early stopping

    // Parallel flow variations with early stopping support
    // Process flows in batches to enable early termination while maintaining parallelism
    let batchSize = 5  // Balance parallelism vs early stopping responsiveness
    var variation = 0
    let flowWorker = worker

    while variation < multipathConfig.flowVariations {
      try Task.checkCancellation()

      let batchEnd = min(variation + batchSize, multipathConfig.flowVariations)
      var batchResults: [(FlowIdentifier, ClassifiedTrace)] = []

      // Launch batch of flows in parallel
      try await withThrowingTaskGroup(
        of: (FlowIdentifier, ClassifiedTrace).self
      ) { group in
        for v in variation..<batchEnd {
          let flowID = FlowIdentifier.generate(variation: v)

          group.addTask {
            try Task.checkCancellation()
            let launch = self.debugTracing ? self.monotonicTime() : 0.0
            let result = try await flowWorker.runMultipathFlow(
              target: target,
              flowID: flowID,
              maxHops: multipathConfig.maxHops,
              timeoutMs: multipathConfig.timeoutMs
            )
            try Task.checkCancellation()
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

        do {
          // Collect every child before leaving the group. If either the caller or a
          // flow fails, cancelAll() promptly reaches the remaining structured workers;
          // the task-group scope then joins them before propagating the error.
          for try await result in group {
            batchResults.append(result)
          }
        } catch {
          group.cancelAll()
          throw error
        }
      }

      try Task.checkCancellation()

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

    try Task.checkCancellation()

    let duration = monotonicTime() - startTime

    return NetworkTopology(
      destination: target,
      destinationIP: discoveredPaths.first?.trace.destinationIP ?? target,
      sourceAdapter: config.interface,
      sourceIP: config.sourceIP,
      publicIP: publicIP?.address,
      publicIPSource: publicIP?.source,
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
      publicIPSource: canonical.publicIPSource,
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
  /// Runs flow variations in parallel batches while maintaining Paris
  /// consistency within each flow.
  ///
  /// - Parameters:
  ///   - target: Hostname or IP to trace
  ///   - config: Multipath discovery configuration
  /// - Returns: Network topology with all discovered paths
  /// - Throws: `CancellationError` when the calling task is cancelled,
  ///   `TracerouteError.cancelled` when ``networkChanged()`` or ``cancelActiveTraces()`` ends it,
  ///   or `TracerouteError` when discovery cannot complete.
  ///
  /// - Important: This implementation uses **ICMP Echo Request** packets with varying
  ///   ICMP ID fields. Many ECMP routers do not hash ICMP fields, so this may find
  ///   fewer paths than UDP-based methods. The discovered paths accurately represent
  ///   ICMP routing behavior, which is ideal for ping monitoring. For TCP/UDP
  ///   application path discovery, a future UDP-based implementation would be preferred.
  ///   Multipath discovery currently supports IPv4 destinations and source addresses only.
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
    try validateMultipathAddressFamily(swiftConfig)
    try swiftConfig.validateForOperation()
    try config.validateForOperation()

    // The flow workers are separate tracers, so this tracer's network change cannot reach them
    // through their own handles. Register one here and race discovery against it. Both run as
    // children of one group, so every flow worker is joined before this returns either way.
    let handle = TraceHandle()
    activeTraces.insert(handle)
    defer { activeTraces.remove(handle) }

    let outcome: Result<NetworkTopology, Error>
    do {
      // One question for the whole run, IPv4 by contract, before the first batch. Its answer, or
      // its absence, is handed to every flow, so no flow asks again. It is asked on its own,
      // before the race below, because both wait on the handle's one cancellation slot.
      let publicIP = try await publicIPObservation(for: .v4, handle: handle)
      let worker = MultipathWorkerSpawner(
        baseConfig: swiftConfig,
        rdnsCache: self.rdnsCache,
        asnResolver: self.asnResolver,
        publicIP: publicIP
      )
      let discovery = MultipathDiscovery(worker: worker, config: swiftConfig, publicIP: publicIP)
      outcome = .success(
        try await withThrowingTaskGroup(of: NetworkTopology?.self) { group in
          group.addTask {
            try await discovery.discoverPaths(to: target, multipathConfig: config)
          }
          group.addTask {
            await waitForCancellation(of: handle)
            if await handle.isCancelled { throw TracerouteError.cancelled }
            return nil
          }
          defer { group.cancelAll() }
          while let next = try await group.next() {
            if let topology = next { return topology }
          }
          throw CancellationError()
        })
    } catch {
      outcome = .failure(error)
    }

    if let beforeCommit = TestSeams.beforeMultipathCommit { await beforeCommit() }
    // Commit: decide and return in one step on this actor, with no suspension, whatever the
    // outcome. `cancelActiveTraces()` (and so `networkChanged()`) removes the handle synchronously
    // before it cancels anything, so a missing handle means the tracer invalidated this discovery:
    // its topology or error is discarded and the library-side cancellation is reported, even if
    // the caller also cancelled. Otherwise a cancelled caller gets `CancellationError`, however a
    // flow reported it. Only then is the outcome itself returned or thrown.
    guard activeTraces.contains(handle) else { throw TracerouteError.cancelled }
    if Task.isCancelled { throw CancellationError() }
    return try outcome.get()
  }

  /// Runs flow workers that reuse caches without escaping the caller's task group.
  struct MultipathWorkerSpawner: MultipathFlowRunning {
    let baseConfig: SwiftFTRConfig
    let rdnsCache: RDNSCache
    let asnResolver: ASNResolver
    /// The parent's public address, or `nil` when it has none; a flow never asks for one.
    let publicIP: PublicIPObservation?

    func runMultipathFlow(
      target: String,
      flowID: FlowIdentifier,
      maxHops: Int,
      timeoutMs: Int
    ) async throws -> (FlowIdentifier, ClassifiedTrace) {
      try Task.checkCancellation()
      let worker = makeFlowTracer(maxHops: maxHops, timeoutMs: timeoutMs)
      let trace = try await worker.performClassifiedTraceWithFlowID(
        to: target,
        flowIdentifier: flowID.icmpID,
        publicIP: publicIP
      )
      try Task.checkCancellation()
      return (flowID, trace)
    }

    /// The tracer one flow runs on: the caller's configuration with the flow's overrides, and the
    /// caller's reverse-DNS cache and ASN resolver. Those two carry the settings `SwiftFTR(config:)`
    /// consumes when it builds them (`rdnsCacheTTL`, `rdnsCacheSize`, `rdnsLookupTimeout`,
    /// `asnResolverStrategy`), so sharing them is how a flow honours those settings.
    func makeFlowTracer(maxHops: Int, timeoutMs: Int) -> SwiftFTR {
      SwiftFTR(
        config: baseConfig.multipathFlowConfig(maxHops: maxHops, timeoutMs: timeoutMs),
        rdnsCache: rdnsCache,
        asnResolver: asnResolver,
        publicIPCache: [:]
      )
    }
  }

  /// Internal implementation of classified trace with flow ID
  ///
  /// The flow classifies with `publicIP`, its parent's answer, and asks for nothing itself.
  fileprivate func performClassifiedTraceWithFlowID(
    to host: String,
    flowIdentifier: UInt16,
    publicIP observation: PublicIPObservation?
  ) async throws -> ClassifiedTrace {
    try config.validateForOperation()

    // Similar to traceClassified but with flow ID override
    let handle = TraceHandle()
    activeTraces.insert(handle)
    defer { activeTraces.remove(handle) }

    // Validate interface early if specified
    if let interfaceName = config.interface {
      _ = try validateInterface(interfaceName)
    }

    let effectivePublicIP = observation?.address
    try Task.checkCancellation()

    // Perform base trace with flow ID
    let tr = try await withTaskCancellationHandler {
      try await performTrace(to: host, handle: handle, flowIdentifier: flowIdentifier)
    } onCancel: {
      handle.cancel(for: .callerTask)
    }

    guard let destIP = tr.resolvedIP else {
      throw TracerouteError.resolutionFailed(
        host: host, details: "Trace completed without a resolved destination address")
    }

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
    // Raced against cancellation like traceClassified's classification, so a cancelled flow does
    // not wait on an ASN load it shares with other resolvers.
    try Task.checkCancellation()
    let classifier = TraceClassifier()
    let baseClassified = try await withTraceCancellation(handle: handle) {
      try await classifier.classify(
        trace: tr,
        destinationIP: destIP,
        resolver: effectiveResolver,
        timeout: 1.5,
        publicIP: effectivePublicIP
      )
    }

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
        hostname: hostname,
        outcome: hop.outcome
      )
    }

    return ClassifiedTrace(
      destinationHost: baseClassified.destinationHost,
      destinationIP: baseClassified.destinationIP,
      destinationHostname: hostnameMap[destIP],
      publicIP: baseClassified.publicIP,
      publicIPSource: observation?.source,
      publicHostname: effectivePublicIP.flatMap { hostnameMap[$0] },
      clientASN: baseClassified.clientASN,
      clientASName: baseClassified.clientASName,
      destinationASN: baseClassified.destinationASN,
      destinationASName: baseClassified.destinationASName,
      hops: enhancedHops
    )
  }
}
