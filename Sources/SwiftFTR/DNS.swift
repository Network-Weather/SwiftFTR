import Foundation

#if canImport(Darwin)
  import Darwin
#endif

// MARK: - High-Precision Timing

/// High-precision time measurement using mach_absolute_time()
/// Returns time in milliseconds with 0.1ms precision
@available(macOS 10.0, *)
private struct HighPrecisionTimer {
  private let start: UInt64
  private static let timebaseInfo: mach_timebase_info = {
    var info = mach_timebase_info()
    mach_timebase_info(&info)
    return info
  }()

  init() {
    self.start = mach_absolute_time()
  }

  /// Get elapsed time in milliseconds with 0.1ms precision
  func elapsedMs() -> Double {
    let end = mach_absolute_time()
    let elapsed = end - start
    let nanos = elapsed * UInt64(Self.timebaseInfo.numer) / UInt64(Self.timebaseInfo.denom)
    let ms = Double(nanos) / 1_000_000.0
    // Round to 0.1ms precision
    return (ms * 10.0).rounded() / 10.0
  }
}

// MARK: - Public DNS Probe API

/// Errors that can occur during DNS queries
public enum DNSError: Error, Sendable {
  /// Invalid IP address format
  case invalidIP(String)
  /// Invalid hostname format
  case invalidHostname(String)
  /// Failed to create socket
  case socketCreationFailed
  /// Failed to bind to interface or source IP
  case bindFailed(String)
  /// Failed to send DNS query
  case sendFailed
  /// Query timed out waiting for response
  case timeout
  /// Received malformed DNS response
  case malformedResponse
  /// Query succeeded but no matching records found
  case noRecords
  /// DNS server returned an error code
  case serverError(rcode: Int)
}

/// DNS record types supported by SwiftFTR
public enum DNSRecordType: UInt16, Sendable {
  /// IPv4 address record
  case a = 1
  /// Authoritative name server
  case ns = 2
  /// Canonical name (alias)
  case cname = 5
  /// Start of authority
  case soa = 6
  /// Domain name pointer (reverse DNS)
  case ptr = 12
  /// Mail exchange
  case mx = 15
  /// Text record
  case txt = 16
  /// IPv6 address record
  case aaaa = 28
  /// Service locator
  case srv = 33
  /// HTTPS service binding (RFC 9460)
  case https = 65
  /// Certification Authority Authorization (RFC 6844)
  case caa = 257
}

/// Parsed DNS record data
public enum DNSRecordData: Sendable {
  /// IPv4 address (A record)
  case ipv4(String)
  /// IPv6 address (AAAA record)
  case ipv6(String)
  /// Hostname (PTR, NS, CNAME records)
  case hostname(String)
  /// Mail exchange with priority (MX record)
  case mx(priority: UInt16, exchange: String)
  /// Text strings (TXT record)
  case txt([String])
  /// Service record (SRV)
  case srv(priority: UInt16, weight: UInt16, port: UInt16, target: String)
  /// Start of authority (SOA)
  case soa(
    primaryNS: String, adminEmail: String, serial: UInt32, refresh: UInt32, retry: UInt32,
    expire: UInt32, minimumTTL: UInt32)
  /// Certification Authority Authorization (CAA)
  case caa(flags: UInt8, tag: String, value: String)
  /// HTTPS service binding (HTTPS)
  case https(priority: UInt16, target: String, svcParams: Data)
  /// Raw unparsed data
  case raw(Data)
}

/// A single DNS record from a query response
public struct DNSRecord: Sendable {
  /// Record name (e.g., "example.com")
  public let name: String
  /// Record type
  public let type: DNSRecordType
  /// Record class (typically 1 for IN/Internet)
  public let recordClass: UInt16
  /// Time-to-live in seconds
  public let ttl: UInt32
  /// Parsed record data
  public let data: DNSRecordData
}

/// Result of a DNS query
public struct DNSQueryResult: Sendable {
  /// The query that was performed (hostname or IP)
  public let query: String
  /// The type of query performed
  public let queryType: DNSRecordType
  /// The DNS server that was queried
  public let server: String
  /// All records returned in the response
  public let records: [DNSRecord]
  /// Round-trip time in milliseconds (0.1ms precision)
  public let rttMs: Double
  /// Timestamp when the query was made
  public let timestamp: Date
}

/// DNS query interface providing access to various DNS record types
public struct DNSQueries: Sendable {
  private let tracer: SwiftFTR

  internal init(tracer: SwiftFTR) {
    self.tracer = tracer
  }

  /// Query for IPv4 address (A record)
  ///
  /// - Parameters:
  ///   - hostname: Domain name to query
  ///   - server: DNS server to use (defaults to config or 8.8.8.8)
  ///   - timeout: Query timeout in seconds (defaults to config or 3.0)
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with A records
  /// - Throws: DNSError on query failure
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func a(
    hostname: String,
    server: String? = nil,
    timeout: TimeInterval? = nil,
    interface: String? = nil,
    sourceIP: String? = nil
  ) async throws -> DNSQueryResult {
    let timer = HighPrecisionTimer()
    let startTime = Date()

    guard !hostname.isEmpty else {
      throw DNSError.invalidHostname(hostname)
    }

    // Use config defaults
    let resolvedServer = server ?? "8.8.8.8"
    let resolvedTimeout = timeout ?? 3.0
    let resolvedInterface = interface ?? tracer.config.interface
    let resolvedSourceIP = sourceIP ?? tracer.config.sourceIP

    // Query A record
    let answers = try await runDetachedBlockingIO {
      try performDNSQueryInternal(
        server: resolvedServer,
        query: hostname,
        queryType: DNSRecordType.a.rawValue,
        timeout: resolvedTimeout,
        interface: resolvedInterface,
        sourceIP: resolvedSourceIP
      )
    }

    let rttMs = timer.elapsedMs()

    // Parse all A records
    var records: [DNSRecord] = []
    for answer in answers where answer.type == DNSRecordType.a.rawValue {
      if let ipv4 = DNSClient.parseA(rdata: answer.rdata) {
        records.append(
          DNSRecord(
            name: answer.name,
            type: .a,
            recordClass: answer.klass,
            ttl: answer.ttl,
            data: .ipv4(ipv4)
          ))
      }
    }

    return DNSQueryResult(
      query: hostname,
      queryType: .a,
      server: resolvedServer,
      records: records,
      rttMs: rttMs,
      timestamp: startTime
    )
  }

  /// Query for IPv6 address (AAAA record)
  ///
  /// - Parameters:
  ///   - hostname: Domain name to query
  ///   - server: DNS server to use (defaults to config or 8.8.8.8)
  ///   - timeout: Query timeout in seconds (defaults to config or 3.0)
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with AAAA records
  /// - Throws: DNSError on query failure
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func aaaa(
    hostname: String,
    server: String? = nil,
    timeout: TimeInterval? = nil,
    interface: String? = nil,
    sourceIP: String? = nil
  ) async throws -> DNSQueryResult {
    let timer = HighPrecisionTimer()
    let startTime = Date()

    guard !hostname.isEmpty else {
      throw DNSError.invalidHostname(hostname)
    }

    // Use config defaults
    let resolvedServer = server ?? "8.8.8.8"
    let resolvedTimeout = timeout ?? 3.0
    let resolvedInterface = interface ?? tracer.config.interface
    let resolvedSourceIP = sourceIP ?? tracer.config.sourceIP

    // Query AAAA record
    let answers = try await runDetachedBlockingIO {
      try performDNSQueryInternal(
        server: resolvedServer,
        query: hostname,
        queryType: DNSRecordType.aaaa.rawValue,
        timeout: resolvedTimeout,
        interface: resolvedInterface,
        sourceIP: resolvedSourceIP
      )
    }

    let rttMs = timer.elapsedMs()

    // Parse all AAAA records
    var records: [DNSRecord] = []
    for answer in answers where answer.type == DNSRecordType.aaaa.rawValue {
      if let ipv6 = DNSClient.parseAAAA(rdata: answer.rdata) {
        records.append(
          DNSRecord(
            name: answer.name,
            type: .aaaa,
            recordClass: answer.klass,
            ttl: answer.ttl,
            data: .ipv6(ipv6)
          ))
      }
    }

    return DNSQueryResult(
      query: hostname,
      queryType: .aaaa,
      server: resolvedServer,
      records: records,
      rttMs: rttMs,
      timestamp: startTime
    )
  }

  /// Reverse DNS lookup for IPv4 address (PTR record)
  ///
  /// - Parameters:
  ///   - ip: IPv4 address to look up
  ///   - server: DNS server to use (defaults to config or 8.8.8.8)
  ///   - timeout: Query timeout in seconds (defaults to config or 3.0)
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with PTR records
  /// - Throws: DNSError on query failure
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func reverseIPv4(
    ip: String,
    server: String? = nil,
    timeout: TimeInterval? = nil,
    interface: String? = nil,
    sourceIP: String? = nil
  ) async throws -> DNSQueryResult {
    let timer = HighPrecisionTimer()
    let startTime = Date()

    // Format IP to in-addr.arpa
    guard let arpaQuery = _formatReverseDNS(ip) else {
      throw DNSError.invalidIP(ip)
    }

    // Use config defaults
    let resolvedServer = server ?? "8.8.8.8"
    let resolvedTimeout = timeout ?? 3.0
    let resolvedInterface = interface ?? tracer.config.interface
    let resolvedSourceIP = sourceIP ?? tracer.config.sourceIP

    // Query PTR record
    let answers = try await runDetachedBlockingIO {
      try performDNSQueryInternal(
        server: resolvedServer,
        query: arpaQuery,
        queryType: DNSRecordType.ptr.rawValue,
        timeout: resolvedTimeout,
        interface: resolvedInterface,
        sourceIP: resolvedSourceIP
      )
    }

    let rttMs = timer.elapsedMs()

    // Parse all PTR records
    var records: [DNSRecord] = []
    for answer in answers where answer.type == DNSRecordType.ptr.rawValue {
      if let hostname = DNSClient.parsePTR(
        rdata: answer.rdata,
        rdataOffsetInMessage: answer.rdataOffset,
        fullMessage: answer.fullMessage
      ) {
        records.append(
          DNSRecord(
            name: answer.name,
            type: .ptr,
            recordClass: answer.klass,
            ttl: answer.ttl,
            data: .hostname(hostname)
          ))
      }
    }

    return DNSQueryResult(
      query: ip,
      queryType: .ptr,
      server: resolvedServer,
      records: records,
      rttMs: rttMs,
      timestamp: startTime
    )
  }

  /// Reverse DNS lookup for IPv6 address (PTR record via ip6.arpa)
  ///
  /// - Parameters:
  ///   - ip: IPv6 address to look up (e.g. "2001:4860:4860::8888")
  ///   - server: DNS server to use (defaults to config or 8.8.8.8)
  ///   - timeout: Query timeout in seconds (defaults to config or 3.0)
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with PTR records
  /// - Throws: DNSError on query failure
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func reverseIPv6(
    ip: String,
    server: String? = nil,
    timeout: TimeInterval? = nil,
    interface: String? = nil,
    sourceIP: String? = nil
  ) async throws -> DNSQueryResult {
    let timer = HighPrecisionTimer()
    let startTime = Date()

    // Format IP to ip6.arpa
    guard let arpaQuery = _formatReverseDNS(ip) else {
      throw DNSError.invalidIP(ip)
    }

    // Use config defaults
    let resolvedServer = server ?? "8.8.8.8"
    let resolvedTimeout = timeout ?? 3.0
    let resolvedInterface = interface ?? tracer.config.interface
    let resolvedSourceIP = sourceIP ?? tracer.config.sourceIP

    // Query PTR record
    let answers = try await runDetachedBlockingIO {
      try performDNSQueryInternal(
        server: resolvedServer,
        query: arpaQuery,
        queryType: DNSRecordType.ptr.rawValue,
        timeout: resolvedTimeout,
        interface: resolvedInterface,
        sourceIP: resolvedSourceIP
      )
    }

    let rttMs = timer.elapsedMs()

    // Parse all PTR records
    var records: [DNSRecord] = []
    for answer in answers where answer.type == DNSRecordType.ptr.rawValue {
      if let hostname = DNSClient.parsePTR(
        rdata: answer.rdata,
        rdataOffsetInMessage: answer.rdataOffset,
        fullMessage: answer.fullMessage
      ) {
        records.append(
          DNSRecord(
            name: answer.name,
            type: .ptr,
            recordClass: answer.klass,
            ttl: answer.ttl,
            data: .hostname(hostname)
          ))
      }
    }

    return DNSQueryResult(
      query: ip,
      queryType: .ptr,
      server: resolvedServer,
      records: records,
      rttMs: rttMs,
      timestamp: startTime
    )
  }

  /// Query for text record (TXT record)
  ///
  /// - Parameters:
  ///   - hostname: Domain name to query
  ///   - server: DNS server to use (defaults to config or 8.8.8.8)
  ///   - timeout: Query timeout in seconds (defaults to config or 3.0)
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with TXT records
  /// - Throws: DNSError on query failure
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func txt(
    hostname: String,
    server: String? = nil,
    timeout: TimeInterval? = nil,
    interface: String? = nil,
    sourceIP: String? = nil
  ) async throws -> DNSQueryResult {
    let timer = HighPrecisionTimer()
    let startTime = Date()

    guard !hostname.isEmpty else {
      throw DNSError.invalidHostname(hostname)
    }

    // Use config defaults
    let resolvedServer = server ?? "8.8.8.8"
    let resolvedTimeout = timeout ?? 3.0
    let resolvedInterface = interface ?? tracer.config.interface
    let resolvedSourceIP = sourceIP ?? tracer.config.sourceIP

    // Query TXT record
    let answers = try await runDetachedBlockingIO {
      try performDNSQueryInternal(
        server: resolvedServer,
        query: hostname,
        queryType: DNSRecordType.txt.rawValue,
        timeout: resolvedTimeout,
        interface: resolvedInterface,
        sourceIP: resolvedSourceIP
      )
    }

    let rttMs = timer.elapsedMs()

    // Parse all TXT records
    var records: [DNSRecord] = []
    for answer in answers where answer.type == DNSRecordType.txt.rawValue {
      if let txtStrings = DNSClient.parseTXT(rdata: answer.rdata) {
        records.append(
          DNSRecord(
            name: answer.name,
            type: .txt,
            recordClass: answer.klass,
            ttl: answer.ttl,
            data: .txt(txtStrings)
          ))
      }
    }

    return DNSQueryResult(
      query: hostname,
      queryType: .txt,
      server: resolvedServer,
      records: records,
      rttMs: rttMs,
      timestamp: startTime
    )
  }

  /// Generic DNS query for any record type
  ///
  /// - Parameters:
  ///   - name: Domain name or IP to query
  ///   - type: DNS record type to query
  ///   - server: DNS server to use (defaults to config or 8.8.8.8)
  ///   - timeout: Query timeout in seconds (defaults to config or 3.0)
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with records of the requested type
  /// - Throws: DNSError on query failure
  #if compiler(>=6.2)
    @concurrent
  #endif
  public func query(
    name: String,
    type: DNSRecordType,
    server: String? = nil,
    timeout: TimeInterval? = nil,
    interface: String? = nil,
    sourceIP: String? = nil
  ) async throws -> DNSQueryResult {
    let timer = HighPrecisionTimer()
    let startTime = Date()

    guard !name.isEmpty else {
      throw DNSError.invalidHostname(name)
    }

    // Use config defaults
    let resolvedServer = server ?? "8.8.8.8"
    let resolvedTimeout = timeout ?? 3.0
    let resolvedInterface = interface ?? tracer.config.interface
    let resolvedSourceIP = sourceIP ?? tracer.config.sourceIP

    // Perform query
    let answers = try await runDetachedBlockingIO {
      try performDNSQueryInternal(
        server: resolvedServer,
        query: name,
        queryType: type.rawValue,
        timeout: resolvedTimeout,
        interface: resolvedInterface,
        sourceIP: resolvedSourceIP
      )
    }

    let rttMs = timer.elapsedMs()

    // Parse records based on type
    var records: [DNSRecord] = []
    for answer in answers where answer.type == type.rawValue {
      let data: DNSRecordData

      // Parse known types, return raw for unknown
      switch type {
      case .a:
        if let ipv4 = DNSClient.parseA(rdata: answer.rdata) {
          data = .ipv4(ipv4)
        } else {
          data = .raw(answer.rdata)
        }
      case .aaaa:
        if let ipv6 = DNSClient.parseAAAA(rdata: answer.rdata) {
          data = .ipv6(ipv6)
        } else {
          data = .raw(answer.rdata)
        }
      case .ptr:
        if let hostname = DNSClient.parsePTR(
          rdata: answer.rdata,
          rdataOffsetInMessage: answer.rdataOffset,
          fullMessage: answer.fullMessage
        ) {
          data = .hostname(hostname)
        } else {
          data = .raw(answer.rdata)
        }
      case .txt:
        if let txtStrings = DNSClient.parseTXT(rdata: answer.rdata) {
          data = .txt(txtStrings)
        } else {
          data = .raw(answer.rdata)
        }
      case .ns:
        if let hostname = DNSClient.parseNS(
          rdata: answer.rdata,
          rdataOffsetInMessage: answer.rdataOffset,
          fullMessage: answer.fullMessage
        ) {
          data = .hostname(hostname)
        } else {
          data = .raw(answer.rdata)
        }
      case .cname:
        if let hostname = DNSClient.parseCNAME(
          rdata: answer.rdata,
          rdataOffsetInMessage: answer.rdataOffset,
          fullMessage: answer.fullMessage
        ) {
          data = .hostname(hostname)
        } else {
          data = .raw(answer.rdata)
        }
      case .mx:
        if let (priority, exchange) = DNSClient.parseMX(
          rdata: answer.rdata,
          rdataOffsetInMessage: answer.rdataOffset,
          fullMessage: answer.fullMessage
        ) {
          data = .mx(priority: priority, exchange: exchange)
        } else {
          data = .raw(answer.rdata)
        }
      case .soa:
        if let soa = DNSClient.parseSOA(
          rdata: answer.rdata,
          rdataOffsetInMessage: answer.rdataOffset,
          fullMessage: answer.fullMessage
        ) {
          data = .soa(
            primaryNS: soa.primaryNS,
            adminEmail: soa.adminEmail,
            serial: soa.serial,
            refresh: soa.refresh,
            retry: soa.retry,
            expire: soa.expire,
            minimumTTL: soa.minimumTTL
          )
        } else {
          data = .raw(answer.rdata)
        }
      case .srv:
        if let srv = DNSClient.parseSRV(
          rdata: answer.rdata,
          rdataOffsetInMessage: answer.rdataOffset,
          fullMessage: answer.fullMessage
        ) {
          data = .srv(
            priority: srv.priority,
            weight: srv.weight,
            port: srv.port,
            target: srv.target
          )
        } else {
          data = .raw(answer.rdata)
        }
      case .caa:
        if let caa = DNSClient.parseCAA(rdata: answer.rdata) {
          data = .caa(flags: caa.flags, tag: caa.tag, value: caa.value)
        } else {
          data = .raw(answer.rdata)
        }
      case .https:
        if let https = DNSClient.parseHTTPS(
          rdata: answer.rdata,
          rdataOffsetInMessage: answer.rdataOffset,
          fullMessage: answer.fullMessage
        ) {
          data = .https(priority: https.priority, target: https.target, svcParams: https.svcParams)
        } else {
          data = .raw(answer.rdata)
        }
      @unknown default:
        data = .raw(answer.rdata)
      }

      records.append(
        DNSRecord(
          name: answer.name,
          type: type,
          recordClass: answer.klass,
          ttl: answer.ttl,
          data: data
        ))
    }

    return DNSQueryResult(
      query: name,
      queryType: type,
      server: resolvedServer,
      records: records,
      rttMs: rttMs,
      timestamp: startTime
    )
  }
}

/// Configuration for DNS probe
public struct DNSProbeConfig: Sendable {
  /// DNS server to query
  public let server: String

  /// Query name (default: "example.com")
  public let query: String

  /// Query type (1 = A, 16 = TXT, 28 = AAAA)
  public let queryType: UInt16

  /// Timeout in seconds
  public let timeout: TimeInterval

  /// Network interface to bind to for this DNS probe.
  ///
  /// When specified, this probe uses only this interface. If `nil`, uses system routing.
  ///
  /// Example:
  /// ```swift
  /// // Test DNS resolution via specific interface
  /// let result = try await dnsProbe(
  ///   config: DNSProbeConfig(
  ///     server: "8.8.8.8",
  ///     query: "example.com",
  ///     interface: "en0"
  ///   )
  /// )
  /// ```
  public let interface: String?

  /// Source IP address to bind to for this DNS probe.
  ///
  /// When specified, outgoing packets use this IP as the source address.
  /// The IP must be assigned to the selected interface.
  ///
  /// **Note**: Most users only need to set ``interface``.
  public let sourceIP: String?

  public init(
    server: String,
    query: String = "example.com",
    queryType: UInt16 = 1,  // A record
    timeout: TimeInterval = 2.0,
    interface: String? = nil,
    sourceIP: String? = nil
  ) {
    self.server = server
    self.query = query
    self.queryType = queryType
    self.timeout = timeout
    self.interface = interface
    self.sourceIP = sourceIP
  }
}

/// Result from DNS probe
public struct DNSProbeResult: Sendable, Codable {
  /// DNS server queried
  public let server: String

  /// Query name
  public let query: String

  /// Whether server responded (success even if NXDOMAIN)
  public let isReachable: Bool

  /// Round-trip time (nil if timeout)
  public let rtt: TimeInterval?

  /// Response code (0 = NOERROR, 3 = NXDOMAIN, etc.)
  public let responseCode: Int?

  /// Error message (if any)
  public let error: String?

  /// Timestamp
  public let timestamp: Date

  public init(
    server: String,
    query: String,
    isReachable: Bool,
    rtt: TimeInterval?,
    responseCode: Int?,
    error: String?,
    timestamp: Date = Date()
  ) {
    self.server = server
    self.query = query
    self.isReachable = isReachable
    self.rtt = rtt
    self.responseCode = responseCode
    self.error = error
    self.timestamp = timestamp
  }
}

/// DNS probe - tests if DNS server responds
/// Returns success if ANY response received (even NXDOMAIN or errors)
/// Returns failure only on timeout
#if compiler(>=6.2)
  @concurrent
#endif
public func dnsProbe(
  server: String,
  query: String = "example.com",
  timeout: TimeInterval = 2.0
) async throws -> DNSProbeResult {
  let config = DNSProbeConfig(server: server, query: query, timeout: timeout)
  return try await dnsProbe(config: config)
}

#if compiler(>=6.2)
  @concurrent
#endif
public func dnsProbe(config: DNSProbeConfig) async throws -> DNSProbeResult {
  let startTime = Date()

  // Perform DNS query
  let result = await performDNSProbe(
    server: config.server,
    query: config.query,
    queryType: config.queryType,
    timeout: config.timeout,
    interface: config.interface,
    sourceIP: config.sourceIP
  )

  let rtt = result.isReachable ? Date().timeIntervalSince(startTime) : nil

  return DNSProbeResult(
    server: config.server,
    query: config.query,
    isReachable: result.isReachable,
    rtt: rtt,
    responseCode: result.responseCode,
    error: result.error,
    timestamp: startTime
  )
}

// MARK: - DNS Query Result Types (0.7.1)

/// Result from reverse DNS query
public struct ReverseDNSResult: Sendable, Codable {
  /// IP address queried
  public let ip: String

  /// DNS server used
  public let server: String

  /// Resolved hostname (nil if no PTR record)
  public let hostname: String?

  /// Round-trip time
  public let rtt: TimeInterval

  /// Timestamp
  public let timestamp: Date

  public init(
    ip: String, server: String, hostname: String?, rtt: TimeInterval, timestamp: Date = Date()
  ) {
    self.ip = ip
    self.server = server
    self.hostname = hostname
    self.rtt = rtt
    self.timestamp = timestamp
  }
}

/// Result from AAAA query
public struct AAAAQueryResult: Sendable, Codable {
  /// Hostname queried
  public let hostname: String

  /// DNS server used
  public let server: String

  /// IPv6 addresses found
  public let addresses: [String]

  /// Round-trip time
  public let rtt: TimeInterval

  /// Timestamp
  public let timestamp: Date

  public init(
    hostname: String, server: String, addresses: [String], rtt: TimeInterval,
    timestamp: Date = Date()
  ) {
    self.hostname = hostname
    self.server = server
    self.addresses = addresses
    self.rtt = rtt
    self.timestamp = timestamp
  }
}

/// Result from A query
public struct AQueryResult: Sendable, Codable {
  /// Hostname queried
  public let hostname: String

  /// DNS server used
  public let server: String

  /// IPv4 addresses found
  public let addresses: [String]

  /// Round-trip time
  public let rtt: TimeInterval

  /// Timestamp
  public let timestamp: Date

  public init(
    hostname: String, server: String, addresses: [String], rtt: TimeInterval,
    timestamp: Date = Date()
  ) {
    self.hostname = hostname
    self.server = server
    self.addresses = addresses
    self.rtt = rtt
    self.timestamp = timestamp
  }
}

// MARK: - DNS Query APIs (0.7.1)

/// Perform reverse DNS lookup (PTR query)
///
/// Queries the specified DNS server for the hostname associated with an IP address.
/// This is useful for identifying network devices like gateways by their hostnames.
///
/// Example:
/// ```swift
/// // Query gateway for its own hostname
/// let result = try await reverseDNS(
///   ip: "10.1.10.1",
///   server: "10.1.10.1"
/// )
/// if let hostname = result.hostname {
///   print("Gateway: \(hostname) (RTT: \(String(format: "%.2f", result.rtt * 1000))ms)")
///   // Prints: "Gateway: Docsis-Gateway.hsd1.ca.comcast.net (RTT: 12.34ms)"
/// }
/// ```
///
/// - Parameters:
///   - ip: IPv4 address to resolve (e.g., "10.1.10.1")
///   - server: DNS server to query (can be the IP itself!)
///   - timeout: Query timeout in seconds (default: 2.0)
///   - interface: Network interface to bind to (macOS only, optional)
///   - sourceIP: Source IP address to bind to (optional)
/// - Returns: ReverseDNSResult containing hostname (or nil) and timing information
/// - Throws: DNSError on network failures or invalid input
#if compiler(>=6.2)
  @concurrent
#endif
public func reverseDNS(
  ip: String,
  server: String,
  timeout: TimeInterval = 2.0,
  interface: String? = nil,
  sourceIP: String? = nil
) async throws -> ReverseDNSResult {
  let startTime = Date()

  // Convert IP to reverse DNS format (e.g., "10.1.10.1" -> "1.10.1.10.in-addr.arpa")
  guard let reverseName = _formatReverseDNS(ip) else {
    throw DNSError.invalidIP(ip)
  }

  // Query PTR record
  let answers = try await runDetachedBlockingIO {
    try performDNSQueryInternal(
      server: server,
      query: reverseName,
      queryType: 12,  // PTR
      timeout: timeout,
      interface: interface,
      sourceIP: sourceIP
    )
  }

  let rtt = Date().timeIntervalSince(startTime)

  // Parse first PTR record
  for answer in answers where answer.type == 12 {
    if let hostname = DNSClient.parsePTR(
      rdata: answer.rdata,
      rdataOffsetInMessage: answer.rdataOffset,
      fullMessage: answer.fullMessage
    ) {
      return ReverseDNSResult(
        ip: ip,
        server: server,
        hostname: hostname,
        rtt: rtt,
        timestamp: startTime
      )
    }
  }

  return ReverseDNSResult(
    ip: ip,
    server: server,
    hostname: nil,
    rtt: rtt,
    timestamp: startTime
  )
}

/// Perform reverse DNS lookup for an IPv6 address (PTR query via ip6.arpa)
///
/// - Parameters:
///   - ip: IPv6 address to resolve (e.g., "2001:4860:4860::8888")
///   - server: DNS server to query
///   - timeout: Query timeout in seconds (default: 2.0)
///   - interface: Network interface to bind to (macOS only, optional)
///   - sourceIP: Source IP address to bind to (optional)
/// - Returns: ReverseDNSResult containing hostname (or nil) and timing information
/// - Throws: DNSError on network failures or invalid input
#if compiler(>=6.2)
  @concurrent
#endif
public func reverseIPv6(
  ip: String,
  server: String,
  timeout: TimeInterval = 2.0,
  interface: String? = nil,
  sourceIP: String? = nil
) async throws -> ReverseDNSResult {
  let startTime = Date()

  // Convert IPv6 to reverse DNS format (ip6.arpa)
  guard let reverseName = _formatReverseDNS(ip) else {
    throw DNSError.invalidIP(ip)
  }

  // Query PTR record
  let answers = try await runDetachedBlockingIO {
    try performDNSQueryInternal(
      server: server,
      query: reverseName,
      queryType: 12,  // PTR
      timeout: timeout,
      interface: interface,
      sourceIP: sourceIP
    )
  }

  let rtt = Date().timeIntervalSince(startTime)

  // Parse first PTR record
  for answer in answers where answer.type == 12 {
    if let hostname = DNSClient.parsePTR(
      rdata: answer.rdata,
      rdataOffsetInMessage: answer.rdataOffset,
      fullMessage: answer.fullMessage
    ) {
      return ReverseDNSResult(
        ip: ip,
        server: server,
        hostname: hostname,
        rtt: rtt,
        timestamp: startTime
      )
    }
  }

  return ReverseDNSResult(
    ip: ip,
    server: server,
    hostname: nil,
    rtt: rtt,
    timestamp: startTime
  )
}

/// Query IPv6 address (AAAA record)
///
/// Queries the specified DNS server for IPv6 addresses associated with a hostname.
///
/// Example:
/// ```swift
/// let result = try await queryAAAA(
///   hostname: "google.com",
///   server: "8.8.8.8"
/// )
/// for addr in result.addresses {
///   print("IPv6: \(addr)")
/// }
/// print("Query RTT: \(String(format: "%.2f", result.rtt * 1000))ms")
/// ```
///
/// - Parameters:
///   - hostname: Domain name to resolve (e.g., "google.com")
///   - server: DNS server to query
///   - timeout: Query timeout in seconds (default: 2.0)
///   - interface: Network interface to bind to (macOS only, optional)
///   - sourceIP: Source IP address to bind to (optional)
/// - Returns: AAAAQueryResult containing IPv6 addresses and timing information
/// - Throws: DNSError on network failures or invalid input
#if compiler(>=6.2)
  @concurrent
#endif
public func queryAAAA(
  hostname: String,
  server: String,
  timeout: TimeInterval = 2.0,
  interface: String? = nil,
  sourceIP: String? = nil
) async throws -> AAAAQueryResult {
  let startTime = Date()

  guard !hostname.isEmpty else {
    throw DNSError.invalidHostname(hostname)
  }

  // Query AAAA record
  let answers = try await runDetachedBlockingIO {
    try performDNSQueryInternal(
      server: server,
      query: hostname,
      queryType: 28,  // AAAA
      timeout: timeout,
      interface: interface,
      sourceIP: sourceIP
    )
  }

  let rtt = Date().timeIntervalSince(startTime)

  // Parse all AAAA records
  var ipv6Addresses: [String] = []
  for answer in answers where answer.type == 28 {
    if let ipv6 = DNSClient.parseAAAA(rdata: answer.rdata) {
      ipv6Addresses.append(ipv6)
    }
  }

  return AAAAQueryResult(
    hostname: hostname,
    server: server,
    addresses: ipv6Addresses,
    rtt: rtt,
    timestamp: startTime
  )
}

/// Query IPv4 address (A record)
///
/// Queries the specified DNS server for IPv4 addresses associated with a hostname.
///
/// Example:
/// ```swift
/// let result = try await queryA(
///   hostname: "example.com",
///   server: "1.1.1.1"
/// )
/// for addr in result.addresses {
///   print("IPv4: \(addr)")
/// }
/// print("Query RTT: \(String(format: "%.2f", result.rtt * 1000))ms")
/// ```
///
/// - Parameters:
///   - hostname: Domain name to resolve (e.g., "example.com")
///   - server: DNS server to query
///   - timeout: Query timeout in seconds (default: 2.0)
///   - interface: Network interface to bind to (macOS only, optional)
///   - sourceIP: Source IP address to bind to (optional)
/// - Returns: AQueryResult containing IPv4 addresses and timing information
/// - Throws: DNSError on network failures or invalid input
#if compiler(>=6.2)
  @concurrent
#endif
public func queryA(
  hostname: String,
  server: String,
  timeout: TimeInterval = 2.0,
  interface: String? = nil,
  sourceIP: String? = nil
) async throws -> AQueryResult {
  let startTime = Date()

  guard !hostname.isEmpty else {
    throw DNSError.invalidHostname(hostname)
  }

  // Query A record
  let answers = try await runDetachedBlockingIO {
    try performDNSQueryInternal(
      server: server,
      query: hostname,
      queryType: 1,  // A
      timeout: timeout,
      interface: interface,
      sourceIP: sourceIP
    )
  }

  let rtt = Date().timeIntervalSince(startTime)

  // Parse all A records
  var ipv4Addresses: [String] = []
  for answer in answers where answer.type == 1 {
    if let ipv4 = DNSClient.parseA(rdata: answer.rdata) {
      ipv4Addresses.append(ipv4)
    }
  }

  return AQueryResult(
    hostname: hostname,
    server: server,
    addresses: ipv4Addresses,
    rtt: rtt,
    timestamp: startTime
  )
}

// MARK: - Private Helpers

private struct DNSProbeResultInternal {
  let isReachable: Bool
  let responseCode: Int?
  let error: String?
}

/// Shared DNS query implementation that returns parsed answers
/// - Parameters:
///   - server: DNS server IP address
///   - query: Domain name to query (or reverse DNS format)
///   - queryType: DNS record type (A=1, AAAA=28, PTR=12, TXT=16, etc.)
///   - timeout: Query timeout in seconds
///   - interface: Network interface to bind to (macOS only)
///   - sourceIP: Source IP address to bind to
/// - Returns: Array of parsed DNS answers
/// - Throws: DNSError on failure
private func performDNSQueryInternal(
  server: String,
  query: String,
  queryType: UInt16,
  timeout: TimeInterval,
  interface: String?,
  sourceIP: String?
) throws -> [DNSClient.Answer] {
  // Detect server address family (IPv4 vs IPv6)
  let serverFamily = detectAddressFamily(server)
  guard serverFamily == AF_INET || serverFamily == AF_INET6 else {
    throw DNSError.invalidIP(server)
  }

  let fd = socket(serverFamily, SOCK_DGRAM, IPPROTO_UDP)
  guard fd >= 0 else {
    throw DNSError.socketCreationFailed
  }
  defer { close(fd) }

  // Bind to interface if specified
  if let iface = interface {
    #if canImport(Darwin)
      let ifaceIndex = if_nametoindex(iface)
      guard ifaceIndex != 0 else {
        throw DNSError.bindFailed("Interface '\(iface)' not found")
      }

      var index = ifaceIndex
      let (proto, opt) =
        serverFamily == AF_INET6
        ? (IPPROTO_IPV6, IPV6_BOUND_IF) : (IPPROTO_IP, IP_BOUND_IF)
      let result = setsockopt(
        fd, proto, opt,
        &index, socklen_t(MemoryLayout<UInt32>.size))

      guard result >= 0 else {
        throw DNSError.bindFailed("Failed to bind to interface '\(iface)'")
      }
    #else
      throw DNSError.bindFailed("Interface binding not supported on this platform")
    #endif
  }

  // Bind to source IP if specified
  if let srcIP = sourceIP {
    let srcFamily = detectAddressFamily(srcIP)
    guard srcFamily == serverFamily else {
      throw DNSError.bindFailed(
        "Source IP family (\(srcFamily == AF_INET ? "IPv4" : "IPv6")) doesn't match server family")
    }

    if serverFamily == AF_INET6 {
      let (bare6, scopeID) = parseIPv6Scoped(srcIP)
      var sourceAddr6 = sockaddr_in6()
      sourceAddr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      sourceAddr6.sin6_family = sa_family_t(AF_INET6)
      sourceAddr6.sin6_port = 0
      sourceAddr6.sin6_scope_id = scopeID
      guard inet_pton(AF_INET6, bare6, &sourceAddr6.sin6_addr) == 1 else {
        throw DNSError.bindFailed("Invalid source IPv6 address '\(srcIP)'")
      }
      let bindResult = withUnsafePointer(to: &sourceAddr6) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
          bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
      }
      guard bindResult >= 0 else {
        throw DNSError.bindFailed("Failed to bind to source IP '\(srcIP)'")
      }
    } else {
      var sourceAddr = sockaddr_in()
      sourceAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      sourceAddr.sin_family = sa_family_t(AF_INET)
      sourceAddr.sin_port = 0

      guard inet_pton(AF_INET, srcIP, &sourceAddr.sin_addr) == 1 else {
        throw DNSError.bindFailed("Invalid source IP address '\(srcIP)'")
      }

      let bindResult = withUnsafePointer(to: &sourceAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
          bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }

      guard bindResult >= 0 else {
        throw DNSError.bindFailed("Failed to bind to source IP '\(srcIP)'")
      }
    }
  }

  // Set timeout
  var tv = timeval(
    tv_sec: Int(timeout),
    tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000)
  )
  _ = withUnsafePointer(to: &tv) { p in
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
  }
  _ = withUnsafePointer(to: &tv) { p in
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
  }

  // Build DNS query message
  var msg = Data()
  let id = UInt16.random(in: 0...UInt16.max)

  func append16(_ v: UInt16) {
    var b = v.bigEndian
    withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) }
  }

  // Header
  append16(id)  // ID
  append16(0x0100)  // RD (recursion desired)
  append16(1)  // QDCOUNT
  append16(0)  // ANCOUNT
  append16(0)  // NSCOUNT
  append16(0)  // ARCOUNT

  // Question
  msg.append(contentsOf: _encodeQName(query))
  append16(queryType)  // QTYPE
  append16(1)  // QCLASS IN

  // Prepare destination and send
  let sent: ssize_t
  if serverFamily == AF_INET6 {
    let (bare6, scopeID) = parseIPv6Scoped(server)
    var dst6 = sockaddr_in6()
    dst6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    dst6.sin6_family = sa_family_t(AF_INET6)
    dst6.sin6_port = in_port_t(53).bigEndian
    dst6.sin6_scope_id = scopeID
    guard inet_pton(AF_INET6, bare6, &dst6.sin6_addr) == 1 else {
      throw DNSError.invalidIP(server)
    }
    sent = msg.withUnsafeBytes { raw in
      withUnsafePointer(to: &dst6) { aptr in
        aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
          sendto(
            fd, raw.baseAddress!, raw.count, 0, saptr,
            socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
      }
    }
  } else {
    var dst4 = sockaddr_in()
    dst4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    dst4.sin_family = sa_family_t(AF_INET)
    dst4.sin_port = in_port_t(53).bigEndian
    guard server.withCString({ cs in inet_pton(AF_INET, cs, &dst4.sin_addr) }) == 1 else {
      throw DNSError.invalidIP(server)
    }
    sent = msg.withUnsafeBytes { raw in
      withUnsafePointer(to: &dst4) { aptr in
        aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
          sendto(
            fd, raw.baseAddress!, raw.count, 0, saptr,
            socklen_t(MemoryLayout<sockaddr_in>.size))
        }
      }
    }
  }

  guard sent > 0 else {
    throw DNSError.sendFailed
  }

  // Receive response (sockaddr_storage is large enough for both families)
  var buf = [UInt8](repeating: 0, count: 2048)
  var fromStorage = sockaddr_storage()
  var fromlen: socklen_t = socklen_t(MemoryLayout<sockaddr_storage>.size)
  let n = withUnsafeMutablePointer(to: &fromStorage) { aptr -> ssize_t in
    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
      recvfrom(fd, &buf, buf.count, 0, saptr, &fromlen)
    }
  }

  guard n > 0 else {
    throw DNSError.timeout
  }

  // Parse response
  let responseData = Data(buf.prefix(n))

  guard n >= 12 else {
    throw DNSError.malformedResponse
  }

  // Extract RCODE from flags (bits 0-3 of byte 3)
  let flags = UInt16(buf[2]) << 8 | UInt16(buf[3])
  let rcode = Int(flags & 0x000F)

  // Check for DNS errors (RCODE != 0)
  guard rcode == 0 else {
    throw DNSError.serverError(rcode: rcode)
  }

  // Parse answers
  guard let answers = DNSClient.parseAnswers(message: responseData) else {
    throw DNSError.malformedResponse
  }

  return answers
}

/// Legacy wrapper for dnsProbe() that preserves behavior of returning success even for NXDOMAIN
private func performDNSProbe(
  server: String,
  query: String,
  queryType: UInt16,
  timeout: TimeInterval,
  interface: String?,
  sourceIP: String?
) async -> DNSProbeResultInternal {
  do {
    // Try to perform query - success means RCODE=0
    _ = try await runDetachedBlockingIO {
      try performDNSQueryInternal(
        server: server,
        query: query,
        queryType: queryType,
        timeout: timeout,
        interface: interface,
        sourceIP: sourceIP
      )
    }
    return DNSProbeResultInternal(
      isReachable: true,
      responseCode: 0,
      error: nil
    )
  } catch DNSError.serverError(let rcode) {
    // DNS server responded with non-zero RCODE (NXDOMAIN, etc.)
    // This is still "reachable" for probe purposes
    return DNSProbeResultInternal(
      isReachable: true,
      responseCode: rcode,
      error: nil
    )
  } catch DNSError.timeout {
    return DNSProbeResultInternal(
      isReachable: false,
      responseCode: nil,
      error: "Timeout - no response"
    )
  } catch DNSError.socketCreationFailed {
    return DNSProbeResultInternal(
      isReachable: false,
      responseCode: nil,
      error: "Failed to create socket"
    )
  } catch DNSError.bindFailed(let msg) {
    return DNSProbeResultInternal(
      isReachable: false,
      responseCode: nil,
      error: msg
    )
  } catch DNSError.invalidIP(let ip) {
    return DNSProbeResultInternal(
      isReachable: false,
      responseCode: nil,
      error: "Invalid server IP: \(ip)"
    )
  } catch DNSError.sendFailed {
    return DNSProbeResultInternal(
      isReachable: false,
      responseCode: nil,
      error: "Failed to send query"
    )
  } catch DNSError.malformedResponse {
    return DNSProbeResultInternal(
      isReachable: true,  // Got response, even if malformed
      responseCode: nil,
      error: "Malformed response"
    )
  } catch {
    return DNSProbeResultInternal(
      isReachable: false,
      responseCode: nil,
      error: "Unexpected error: \(error)"
    )
  }
}

// MARK: - Existing DNS Client

// Fileprivate helper so tests can call an SPI wrapper without exposing the type.
private func _encodeQName(_ name: String) -> [UInt8] {
  var out: [UInt8] = []
  for label in name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).split(separator: ".") {
    let lb = Array(label.utf8)
    guard lb.count < 64 else { continue }
    out.append(UInt8(lb.count))
    out.append(contentsOf: lb)
  }
  out.append(0)  // terminator
  return out
}

/// Format an IP address for reverse DNS (PTR) query.
/// - IPv4 example: `"10.1.10.1"` → `"1.10.1.10.in-addr.arpa"`
/// - IPv6 example: `"2001:4860:4860::8888"` → `"8.8.8.8.0.0.0.0...0.6.8.4.0.6.8.4.1.0.0.2.ip6.arpa"`
private func _formatReverseDNS(_ ip: String) -> String? {
  // Try IPv4 first
  let octets = ip.split(separator: ".").compactMap { Int($0) }
  if octets.count == 4, octets.allSatisfy({ $0 >= 0 && $0 <= 255 }) {
    return "\(octets[3]).\(octets[2]).\(octets[1]).\(octets[0]).in-addr.arpa"
  }

  // Try IPv6 — expand via inet_pton to get 16 raw bytes
  let bare = ip.split(separator: "%", maxSplits: 1).first.map(String.init) ?? ip
  var addr6 = in6_addr()
  guard inet_pton(AF_INET6, bare, &addr6) == 1 else { return nil }

  // Read 16 bytes, expand each byte to two hex nibbles, reverse all 32 nibbles
  let rawBytes = withUnsafeBytes(of: &addr6) { Array($0) }
  var nibbles: [String] = []
  for byte in rawBytes {
    nibbles.append(String(byte >> 4, radix: 16))
    nibbles.append(String(byte & 0x0F, radix: 16))
  }
  return nibbles.reversed().joined(separator: ".") + ".ip6.arpa"
}

struct DNSClient {
  struct Answer {
    let name: String
    let type: UInt16
    let klass: UInt16
    let ttl: UInt32
    let rdata: Data
    let rdataOffset: Int  // Offset in full message where RDATA starts
    let fullMessage: Data  // Full DNS message (needed for PTR parsing with compression)
  }

  static func queryTXT(
    name: String, timeout: TimeInterval = 1.0, servers: [String] = ["1.1.1.1", "8.8.8.8"]
  )
    -> [String]?
  {
    for server in servers {
      if let res = queryTXTOnce(name: name, timeout: timeout, server: server) {
        return res
      }
    }
    return nil
  }

  private static func queryTXTOnce(name: String, timeout: TimeInterval, server: String) -> [String]?
  {
    let serverFamily = detectAddressFamily(server)
    guard serverFamily == AF_INET || serverFamily == AF_INET6 else { return nil }

    let fd = socket(serverFamily, SOCK_DGRAM, IPPROTO_UDP)
    if fd < 0 { return nil }
    defer { close(fd) }
    var tv = timeval(
      tv_sec: Int(timeout), tv_usec: __darwin_suseconds_t((timeout - floor(timeout)) * 1_000_000))
    _ = withUnsafePointer(to: &tv) { p in
      setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
    }
    _ = withUnsafePointer(to: &tv) { p in
      setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, p, socklen_t(MemoryLayout<timeval>.size))
    }

    var msg = Data()
    let id = UInt16.random(in: 0...UInt16.max)
    func append16(_ v: UInt16) {
      var b = v.bigEndian
      withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) }
    }
    func append32(_ v: UInt32) {
      var b = v.bigEndian
      withUnsafeBytes(of: &b) { msg.append(contentsOf: $0) }
    }

    // Header
    append16(id)  // ID
    append16(0x0100)  // RD
    append16(1)  // QDCOUNT
    append16(0)  // ANCOUNT
    append16(0)  // NSCOUNT
    append16(0)  // ARCOUNT

    // Question
    msg.append(contentsOf: _encodeQName(name))
    append16(16)  // QTYPE TXT
    append16(1)  // QCLASS IN

    // Send to server (IPv4 or IPv6)
    let sent: ssize_t
    if serverFamily == AF_INET6 {
      let (bare6, scopeID) = parseIPv6Scoped(server)
      var dst6 = sockaddr_in6()
      dst6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
      dst6.sin6_family = sa_family_t(AF_INET6)
      dst6.sin6_port = in_port_t(53).bigEndian
      dst6.sin6_scope_id = scopeID
      guard inet_pton(AF_INET6, bare6, &dst6.sin6_addr) == 1 else { return nil }
      sent = msg.withUnsafeBytes { raw in
        withUnsafePointer(to: &dst6) { aptr in
          aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
            sendto(
              fd, raw.baseAddress!, raw.count, 0, saptr,
              socklen_t(MemoryLayout<sockaddr_in6>.size))
          }
        }
      }
    } else {
      var dst4 = sockaddr_in()
      dst4.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      dst4.sin_family = sa_family_t(AF_INET)
      dst4.sin_port = in_port_t(53).bigEndian
      guard server.withCString({ cs in inet_pton(AF_INET, cs, &dst4.sin_addr) }) == 1 else {
        return nil
      }
      sent = msg.withUnsafeBytes { raw in
        withUnsafePointer(to: &dst4) { aptr in
          aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
            sendto(
              fd, raw.baseAddress!, raw.count, 0, saptr,
              socklen_t(MemoryLayout<sockaddr_in>.size))
          }
        }
      }
    }
    if sent <= 0 { return nil }

    // Receive response (sockaddr_storage handles both families)
    var buf = [UInt8](repeating: 0, count: 2048)
    var fromStorage = sockaddr_storage()
    var fromlen: socklen_t = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let n = withUnsafeMutablePointer(to: &fromStorage) { aptr -> ssize_t in
      aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
        recvfrom(fd, &buf, buf.count, 0, saptr, &fromlen)
      }
    }
    if n <= 0 { return nil }
    let data = Data(buf.prefix(Int(n)))

    guard let answers = parseAnswers(message: data) else { return nil }
    var out: [String] = []
    for ans in answers where ans.type == 16 && ans.klass == 1 {
      // TXT RDATA: one or more <character-string>; join all chunks into a single string per answer
      var offset = 0
      let bytes = [UInt8](ans.rdata)
      var chunks: [String] = []
      while offset < bytes.count {
        let ln = Int(bytes[offset])
        offset += 1
        guard offset + ln <= bytes.count else { break }
        let s = String(decoding: bytes[offset..<(offset + ln)], as: UTF8.self)
        chunks.append(s)
        offset += ln
      }
      if !chunks.isEmpty { out.append(chunks.joined()) }
    }
    return out.isEmpty ? nil : out
  }

  fileprivate static func parseAnswers(message: Data) -> [Answer]? {
    if message.count < 12 { return nil }
    let bytes = [UInt8](message)
    func r16(_ off: Int) -> UInt16 { return (UInt16(bytes[off]) << 8) | UInt16(bytes[off + 1]) }
    func r32(_ off: Int) -> UInt32 {
      return (UInt32(bytes[off]) << 24) | (UInt32(bytes[off + 1]) << 16)
        | (UInt32(bytes[off + 2]) << 8) | UInt32(bytes[off + 3])
    }
    let id = r16(0)
    _ = id
    let qd = Int(r16(4))
    let an = Int(r16(6))
    var off = 12
    for _ in 0..<qd {
      guard parseName(bytes, &off) != nil else { return nil }
      off += 4  // type+class
      if off > bytes.count { return nil }
    }
    var answers: [Answer] = []
    for _ in 0..<an {
      guard parseName(bytes, &off) != nil else { return nil }
      if off + 10 > bytes.count { return nil }
      let typ = r16(off)
      let cls = r16(off + 2)
      let ttl = r32(off + 4)
      let rdlen = Int(r16(off + 8))
      off += 10
      let rdataOffset = off  // Track where RDATA starts
      if off + rdlen > bytes.count { return nil }
      let rdata = Data(bytes[off..<(off + rdlen)])
      off += rdlen
      answers.append(
        Answer(
          name: "",
          type: typ,
          klass: cls,
          ttl: ttl,
          rdata: rdata,
          rdataOffset: rdataOffset,
          fullMessage: message
        )
      )
    }
    return answers
  }

  // Returns (name, newOffset)
  private static func parseName(_ bytes: [UInt8], _ offset: inout Int) -> (String, Int)? {
    var labels: [String] = []
    var off = offset
    var jumpedTo: Int? = nil
    var loops = 0
    while true {
      if loops > 255 { return nil }  // prevent infinite loops
      loops += 1
      if off >= bytes.count { return nil }
      let len = Int(bytes[off])
      if len == 0 {
        off += 1
        break
      }
      if (len & 0xC0) == 0xC0 {  // pointer
        if off + 1 >= bytes.count { return nil }
        let ptr = ((len & 0x3F) << 8) | Int(bytes[off + 1])
        if jumpedTo == nil { jumpedTo = off + 2 }
        off = ptr
        continue
      } else {
        if off + 1 + len > bytes.count { return nil }
        let s = String(decoding: bytes[(off + 1)..<(off + 1 + len)], as: UTF8.self)
        labels.append(s)
        off += 1 + len
      }
    }
    if let j = jumpedTo { offset = j } else { offset = off }
    let name = labels.joined(separator: ".")
    return (name, off)
  }

  // MARK: - RDATA Parsers

  /// Parse A record (IPv4 address) from RDATA
  static func parseA(rdata: Data) -> String? {
    guard rdata.count == 4 else { return nil }
    let bytes = [UInt8](rdata)
    return "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])"
  }

  /// Parse AAAA record (IPv6 address) from RDATA
  static func parseAAAA(rdata: Data) -> String? {
    guard rdata.count == 16 else { return nil }
    let bytes = [UInt8](rdata)

    // Convert to 8 groups of 2-byte hex values
    var groups: [UInt16] = []
    for i in stride(from: 0, to: 16, by: 2) {
      let value = (UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1])
      groups.append(value)
    }

    // Find longest run of consecutive zeros for :: compression (RFC 5952)
    var bestStart = -1
    var bestLen = 0
    var currentStart = -1
    var currentLen = 0

    for (i, group) in groups.enumerated() {
      if group == 0 {
        if currentStart < 0 {
          currentStart = i
          currentLen = 1
        } else {
          currentLen += 1
        }
      } else {
        if currentLen > bestLen {
          bestStart = currentStart
          bestLen = currentLen
        }
        currentStart = -1
        currentLen = 0
      }
    }

    // Check final run
    if currentLen > bestLen {
      bestStart = currentStart
      bestLen = currentLen
    }

    // Only use :: compression if run is at least 2 zeros
    let useCompression = bestLen >= 2

    // Build formatted address
    var result = ""
    var i = 0
    while i < groups.count {
      if useCompression && i == bestStart {
        result += "::"
        i += bestLen
        if i >= groups.count { break }
      } else {
        if !result.isEmpty && !result.hasSuffix("::") {
          result += ":"
        }
        result += String(format: "%x", groups[i])
        i += 1
      }
    }

    return result
  }

  /// Parse PTR record (hostname) from RDATA
  /// Requires full message and offset because PTR uses DNS name compression
  static func parsePTR(rdata: Data, rdataOffsetInMessage: Int, fullMessage: Data) -> String? {
    let bytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage
    guard let (name, _) = parseName(bytes, &offset) else { return nil }
    return name
  }

  /// Parse TXT record (text strings) from RDATA
  /// Returns array of strings (one per <character-string> in RDATA)
  static func parseTXT(rdata: Data) -> [String]? {
    guard !rdata.isEmpty else { return nil }
    let bytes = [UInt8](rdata)
    var offset = 0
    var strings: [String] = []

    while offset < bytes.count {
      let length = Int(bytes[offset])
      offset += 1

      guard offset + length <= bytes.count else { return nil }
      let stringData = Data(bytes[offset..<(offset + length)])
      let string = String(decoding: stringData, as: UTF8.self)
      strings.append(string)
      offset += length
    }

    return strings.isEmpty ? nil : strings
  }

  /// Parse MX record (mail exchange) from RDATA
  /// Returns (priority, exchange hostname) tuple
  static func parseMX(rdata: Data, rdataOffsetInMessage: Int, fullMessage: Data) -> (
    UInt16, String
  )? {
    guard rdata.count >= 2 else { return nil }
    let bytes = [UInt8](rdata)

    // Read priority (2 bytes)
    let priority = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])

    // Read exchange name (domain name with compression)
    let fullBytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage + 2  // Skip priority
    guard let (exchange, _) = parseName(fullBytes, &offset) else { return nil }

    return (priority, exchange)
  }

  /// Parse NS record (name server) from RDATA
  /// Returns name server hostname
  static func parseNS(rdata: Data, rdataOffsetInMessage: Int, fullMessage: Data) -> String? {
    let bytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage
    guard let (name, _) = parseName(bytes, &offset) else { return nil }
    return name
  }

  /// Parse CNAME record (canonical name) from RDATA
  /// Returns canonical name
  static func parseCNAME(rdata: Data, rdataOffsetInMessage: Int, fullMessage: Data) -> String? {
    let bytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage
    guard let (name, _) = parseName(bytes, &offset) else { return nil }
    return name
  }

  /// Parse SOA record (start of authority) from RDATA
  /// Returns tuple with all SOA fields
  static func parseSOA(rdata: Data, rdataOffsetInMessage: Int, fullMessage: Data) -> (
    primaryNS: String, adminEmail: String, serial: UInt32, refresh: UInt32, retry: UInt32,
    expire: UInt32, minimumTTL: UInt32
  )? {
    let bytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage

    // Parse primary name server
    guard let (primaryNS, _) = parseName(bytes, &offset) else { return nil }

    // Parse admin email
    guard let (adminEmail, _) = parseName(bytes, &offset) else { return nil }

    // Parse 5 32-bit values: serial, refresh, retry, expire, minimum
    guard offset + 20 <= bytes.count else { return nil }

    func read32(_ off: Int) -> UInt32 {
      return (UInt32(bytes[off]) << 24) | (UInt32(bytes[off + 1]) << 16)
        | (UInt32(bytes[off + 2]) << 8) | UInt32(bytes[off + 3])
    }

    let serial = read32(offset)
    let refresh = read32(offset + 4)
    let retry = read32(offset + 8)
    let expire = read32(offset + 12)
    let minimumTTL = read32(offset + 16)

    return (primaryNS, adminEmail, serial, refresh, retry, expire, minimumTTL)
  }

  /// Parse SRV record (service) from RDATA
  /// Returns tuple with priority, weight, port, target
  static func parseSRV(rdata: Data, rdataOffsetInMessage: Int, fullMessage: Data) -> (
    priority: UInt16, weight: UInt16, port: UInt16, target: String
  )? {
    guard rdata.count >= 6 else { return nil }
    let bytes = [UInt8](rdata)

    // Read priority, weight, port (2 bytes each)
    let priority = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    let weight = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
    let port = (UInt16(bytes[4]) << 8) | UInt16(bytes[5])

    // Read target name
    let fullBytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage + 6  // Skip priority, weight, port
    guard let (target, _) = parseName(fullBytes, &offset) else { return nil }

    return (priority, weight, port, target)
  }

  /// Parse CAA record (Certification Authority Authorization) from RDATA
  /// Returns tuple with flags, tag, value
  /// RFC 6844: flags (1 byte), tag length (1 byte), tag (string), value (string)
  static func parseCAA(rdata: Data) -> (flags: UInt8, tag: String, value: String)? {
    guard rdata.count >= 2 else { return nil }
    let bytes = [UInt8](rdata)

    // Read flags (1 byte)
    let flags = bytes[0]

    // Read tag length (1 byte)
    let tagLength = Int(bytes[1])
    guard tagLength > 0, 2 + tagLength <= bytes.count else { return nil }

    // Read tag (ASCII string)
    let tagData = Data(bytes[2..<(2 + tagLength)])
    guard let tag = String(data: tagData, encoding: .ascii) else { return nil }

    // Read value (remaining bytes, UTF-8 string)
    let valueOffset = 2 + tagLength
    guard valueOffset < bytes.count else { return nil }
    let valueData = Data(bytes[valueOffset..<bytes.count])
    let value = String(decoding: valueData, as: UTF8.self)

    return (flags, tag, value)
  }

  /// Parse HTTPS record (HTTPS Service Binding) from RDATA
  /// Returns tuple with priority, target, svcParams
  /// RFC 9460: priority (2 bytes), target (domain name), svcParams (key-value pairs)
  static func parseHTTPS(rdata: Data, rdataOffsetInMessage: Int, fullMessage: Data) -> (
    priority: UInt16, target: String, svcParams: Data
  )? {
    guard rdata.count >= 2 else { return nil }
    let bytes = [UInt8](rdata)

    // Read priority (2 bytes)
    let priority = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])

    // Read target name
    let fullBytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage + 2  // Skip priority
    guard let (target, newOffset) = parseName(fullBytes, &offset) else { return nil }

    // Remaining bytes are SvcParams (keep as raw data for now - parsing is complex)
    let svcParamsStart = newOffset - rdataOffsetInMessage
    let svcParams =
      svcParamsStart < rdata.count ? rdata.subdata(in: svcParamsStart..<rdata.count) : Data()

    return (priority, target, svcParams)
  }

}

// SPI: lightweight wrappers for tests (avoid exposing DNSClient or internals)
@_spi(Test)
public struct __TXTAnswer: Sendable {
  public let type: UInt16
  public let klass: UInt16
  public let rdata: Data
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsEncodeQName(_ name: String) -> [UInt8] { _encodeQName(name) }

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParseTXTAnswers(message: Data) -> [__TXTAnswer]? {
  // Minimal independent parser for TXT answers (sufficient for tests).
  // This mirrors parseAnswers enough for tests.
  let bytes = [UInt8](message)
  if bytes.count < 12 { return nil }
  func r16(_ off: Int) -> UInt16 { return (UInt16(bytes[off]) << 8) | UInt16(bytes[off + 1]) }
  func r32(_ off: Int) -> UInt32 {
    return (UInt32(bytes[off]) << 24) | (UInt32(bytes[off + 1]) << 16)
      | (UInt32(bytes[off + 2]) << 8) | UInt32(bytes[off + 3])
  }
  let qd = Int(r16(4))
  let an = Int(r16(6))
  var off = 12
  // skip questions
  for _ in 0..<qd {
    // skip qname
    while off < bytes.count {
      let len = Int(bytes[off])
      off += 1
      if len == 0 { break }
      if (len & 0xC0) == 0xC0 {
        off += 1
        break
      }
      off += len
    }
    off += 4
    if off > bytes.count { return nil }
  }
  var out: [__TXTAnswer] = []
  for _ in 0..<an {
    // skip name
    if off >= bytes.count { return nil }
    let b0 = Int(bytes[off])
    if (b0 & 0xC0) == 0xC0 {
      off += 2
    } else {
      while off < bytes.count {
        let len = Int(bytes[off])
        off += 1
        if len == 0 { break }
        off += len
      }
    }
    if off + 10 > bytes.count { return nil }
    let typ = r16(off)
    let cls = r16(off + 2)
    _ = r32(off + 4)
    let rdlen = Int(r16(off + 8))
    off += 10
    if off + rdlen > bytes.count { return nil }
    let rdata = Data(bytes[off..<(off + rdlen)])
    off += rdlen
    out.append(__TXTAnswer(type: typ, klass: cls, rdata: rdata))
  }
  return out
}

// MARK: - 0.7.1 Test Wrappers

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParseA(rdata: Data) -> String? {
  DNSClient.parseA(rdata: rdata)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParseAAAA(rdata: Data) -> String? {
  DNSClient.parseAAAA(rdata: rdata)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParsePTR(
  rdata: Data,
  rdataOffsetInMessage: Int,
  fullMessage: Data
) -> String? {
  DNSClient.parsePTR(
    rdata: rdata,
    rdataOffsetInMessage: rdataOffsetInMessage,
    fullMessage: fullMessage
  )
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsFormatReverseDNS(_ ip: String) -> String? {
  _formatReverseDNS(ip)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __detectAddressFamily(_ ip: String) -> Int32 {
  detectAddressFamily(ip)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __parseIPv6Scoped(_ server: String) -> (ip: String, scopeID: UInt32) {
  parseIPv6Scoped(server)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParseTXT(rdata: Data) -> [String]? {
  DNSClient.parseTXT(rdata: rdata)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParseMX(
  rdata: Data,
  rdataOffsetInMessage: Int,
  fullMessage: Data
) -> (UInt16, String)? {
  DNSClient.parseMX(
    rdata: rdata,
    rdataOffsetInMessage: rdataOffsetInMessage,
    fullMessage: fullMessage
  )
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParseNS(
  rdata: Data,
  rdataOffsetInMessage: Int,
  fullMessage: Data
) -> String? {
  DNSClient.parseNS(
    rdata: rdata,
    rdataOffsetInMessage: rdataOffsetInMessage,
    fullMessage: fullMessage
  )
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParseCNAME(
  rdata: Data,
  rdataOffsetInMessage: Int,
  fullMessage: Data
) -> String? {
  DNSClient.parseCNAME(
    rdata: rdata,
    rdataOffsetInMessage: rdataOffsetInMessage,
    fullMessage: fullMessage
  )
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParseSOA(
  rdata: Data,
  rdataOffsetInMessage: Int,
  fullMessage: Data
) -> (
  primaryNS: String, adminEmail: String, serial: UInt32, refresh: UInt32, retry: UInt32,
  expire: UInt32, minimumTTL: UInt32
)? {
  DNSClient.parseSOA(
    rdata: rdata,
    rdataOffsetInMessage: rdataOffsetInMessage,
    fullMessage: fullMessage
  )
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParseSRV(
  rdata: Data,
  rdataOffsetInMessage: Int,
  fullMessage: Data
) -> (priority: UInt16, weight: UInt16, port: UInt16, target: String)? {
  DNSClient.parseSRV(
    rdata: rdata,
    rdataOffsetInMessage: rdataOffsetInMessage,
    fullMessage: fullMessage
  )
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParseCAA(rdata: Data) -> (flags: UInt8, tag: String, value: String)? {
  DNSClient.parseCAA(rdata: rdata)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsParseHTTPS(
  rdata: Data,
  rdataOffsetInMessage: Int,
  fullMessage: Data
) -> (priority: UInt16, target: String, svcParams: Data)? {
  DNSClient.parseHTTPS(
    rdata: rdata,
    rdataOffsetInMessage: rdataOffsetInMessage,
    fullMessage: fullMessage
  )
}
