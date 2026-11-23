import Foundation

#if canImport(Darwin)
  import Darwin
#endif

// MARK: - Timing

/// `seconds` in milliseconds, rounded to 0.1 ms, the precision `DNSQueryResult.rttMs` reports.
private func roundedMilliseconds(_ seconds: TimeInterval) -> Double {
  (seconds * 10_000).rounded() / 10
}

// MARK: - Public DNS Probe API

/// Errors that can occur during DNS queries
public enum DNSError: Error, Sendable {
  /// Invalid IP address format
  case invalidIP(String)
  /// Invalid hostname format
  case invalidHostname(String)
  /// Invalid query timeout
  case invalidTimeout(TimeInterval)
  /// Failed to create socket
  case socketCreationFailed
  /// Failed to configure a socket option
  case setsockoptFailed(option: String, errno: Int32)
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

/// Validates a timeout before it reaches a socket API or an integer conversion.
///
/// Kept internal so DNS-backed resolvers outside this file can enforce the same contract.
func _validateDNSTimeout(_ timeout: TimeInterval) throws {
  guard timeout.isFinite, timeout > 0, timeout < TimeInterval(Int.max) else {
    throw DNSError.invalidTimeout(timeout)
  }
}

private func _dnsSocketTimeout(_ timeout: TimeInterval) throws -> timeval {
  try _validateDNSTimeout(timeout)

  let wholeSeconds = floor(timeout)
  let seconds = Int(wholeSeconds)
  var microseconds = Int((timeout - wholeSeconds) * 1_000_000)

  // A positive sub-microsecond duration would otherwise become a zero timeval,
  // which disables SO_RCVTIMEO/SO_SNDTIMEO instead of setting a short timeout.
  if seconds == 0, microseconds == 0 {
    microseconds = 1
  }

  return timeval(tv_sec: seconds, tv_usec: __darwin_suseconds_t(microseconds))
}

/// Rejects a source address whose family cannot reach `serverFamily`, before any socket exists.
private func _validateDNSSourceFamily(_ sourceIP: String?, serverFamily: Int32) throws {
  guard let sourceIP else { return }
  let sourceFamily = detectAddressFamily(sourceIP)
  guard sourceFamily == serverFamily else {
    throw DNSError.bindFailed(
      "Source IP family (\(sourceFamily == AF_INET ? "IPv4" : "IPv6")) doesn't match server family")
  }
}

/// Bytes read from a DNS reply. A longer datagram is truncated to this and then fails to parse,
/// which reports it as `DNSError.malformedResponse`.
private let dnsReceiveCapacity = 2048

/// The first datagram a DNS server sent back carrying the query's transaction ID, not yet
/// validated otherwise.
private struct DNSReply {
  let message: Data
  let expectedID: UInt16
  /// Seconds from sending the query to reading this datagram.
  let rtt: TimeInterval

  func answers() throws -> [DNSClient.Answer] {
    try DNSClient.validateResponse(message: message, expectedID: expectedID)
  }
}

/// Sends one DNS query over a ``UDPExchange`` and returns the first datagram back that carries
/// the query's transaction ID, otherwise unvalidated. Any other datagram is ignored and the wait
/// goes on to the same deadline (``DNSClient/carriesTransactionID(_:_:)``).
///
/// The checks that need no I/O (`invalidTimeout`, `invalidHostname`, `invalidIP`, and
/// `bindFailed` for a source address of the wrong family) run first, before any socket is
/// opened. The wait for the reply holds no thread.
///
/// - Parameter serverPort: The server's UDP port. `nil` means 53, or the port a test binds
///   through `TestSeams.dnsServerPort`.
/// - Throws: ``DNSError`` for invalid input or a failed bind or connect, ``UDPExchangeFailure``
///   from the transport, or `CancellationError`.
private func exchangeDNSQuery(
  server: String,
  query: String,
  queryType: UInt16,
  timeout: TimeInterval,
  interface: String?,
  sourceIP: String?,
  serverPort: UInt16? = nil
) async throws -> DNSReply {
  try _validateDNSTimeout(timeout)
  let encodedQuery = try _encodeQName(query)
  let family = detectAddressFamily(server)
  guard family == AF_INET || family == AF_INET6 else { throw DNSError.invalidIP(server) }
  try _validateDNSSourceFamily(sourceIP, serverFamily: family)

  let port = serverPort ?? TestSeams.dnsServerPort ?? 53
  let (request, id) = makeDNSQueryMessage(encodedQuery: encodedQuery, queryType: queryType)
  let reply = try await UDPExchange.perform(
    family: family, request: request, timeout: timeout, receiveCapacity: dnsReceiveCapacity,
    accepts: { DNSClient.carriesTransactionID(id, $0) },
    configure: { fd in
      try bindDNSSocket(fd, family: family, interface: interface, sourceIP: sourceIP)
      // A connected UDP socket only receives responses from this DNS server and port.
      try connectDNSSocket(fd, server: server, port: port, family: family)
    })
  return DNSReply(message: Data(reply.bytes), expectedID: id, rtt: reply.rtt)
}

/// The `DNSError` a query method throws for a transport failure.
///
/// A refusal is `sendFailed`: the query reached the host, but no DNS server was there to take it.
/// Host and network unreachable, and other receive errors, stay `timeout`, as they were when the
/// client waited in a blocking `recv`.
private func dnsError(for failure: UDPExchangeFailure) -> DNSError {
  switch failure {
  case .socketCreationFailed: .socketCreationFailed
  case .nonBlockingFailed(let code): .setsockoptFailed(option: "O_NONBLOCK", errno: code)
  case .sendFailed, .refused: .sendFailed
  case .unreachable, .receiveFailed, .timedOut: .timeout
  }
}

/// Runs one DNS query and returns its validated answers with the measured round-trip time.
///
/// - Throws: ``DNSError``, or `CancellationError` when the calling task is cancelled.
private func runDNSQuery(
  server: String,
  query: String,
  queryType: UInt16,
  timeout: TimeInterval,
  interface: String?,
  sourceIP: String?,
  serverPort: UInt16? = nil
) async throws -> (answers: [DNSClient.Answer], rtt: TimeInterval) {
  let reply: DNSReply
  do {
    reply = try await exchangeDNSQuery(
      server: server, query: query, queryType: queryType, timeout: timeout,
      interface: interface, sourceIP: sourceIP, serverPort: serverPort)
  } catch let failure as UDPExchangeFailure {
    throw dnsError(for: failure)
  } catch is DNSConnectFailure {
    throw DNSError.sendFailed
  }
  return (try reply.answers(), reply.rtt)
}

private func _applyDNSSocketTimeout(fd: Int32, timeout: TimeInterval) throws {
  var socketTimeout = try _dnsSocketTimeout(timeout)
  let optionSize = socklen_t(MemoryLayout<timeval>.size)
  let options = [
    (value: SO_RCVTIMEO, name: "SO_RCVTIMEO"),
    (value: SO_SNDTIMEO, name: "SO_SNDTIMEO"),
  ]

  for option in options {
    let result = withUnsafePointer(to: &socketTimeout) { pointer in
      setsockopt(fd, SOL_SOCKET, option.value, pointer, optionSize)
    }
    if result != 0 {
      let errorCode = errno
      throw DNSError.setsockoptFailed(option: option.name, errno: errorCode)
    }
  }
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
  ///   - timeout: An optional query timeout in seconds. When provided, it must be finite and
  ///     greater than zero. Defaults to 3.0.
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with A records
  /// - Throws: ``DNSError`` if the hostname, server or source address, or timeout is invalid;
  ///   if socket creation, configuration, binding, sending, or receiving fails; or if the
  ///   response is malformed or contains a server error.
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
    let (answers, rtt) = try await runDNSQuery(
      server: resolvedServer, query: hostname, queryType: DNSRecordType.a.rawValue,
      timeout: resolvedTimeout,
      interface: resolvedInterface, sourceIP: resolvedSourceIP)

    let rttMs = roundedMilliseconds(rtt)

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
  ///   - timeout: An optional query timeout in seconds. When provided, it must be finite and
  ///     greater than zero. Defaults to 3.0.
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with AAAA records
  /// - Throws: ``DNSError`` if the hostname, server or source address, or timeout is invalid;
  ///   if socket creation, configuration, binding, sending, or receiving fails; or if the
  ///   response is malformed or contains a server error.
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
    let (answers, rtt) = try await runDNSQuery(
      server: resolvedServer, query: hostname, queryType: DNSRecordType.aaaa.rawValue,
      timeout: resolvedTimeout,
      interface: resolvedInterface, sourceIP: resolvedSourceIP)

    let rttMs = roundedMilliseconds(rtt)

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
  ///   - timeout: An optional query timeout in seconds. When provided, it must be finite and
  ///     greater than zero. Defaults to 3.0.
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with PTR records
  /// - Throws: ``DNSError`` if the IP address, server or source address, or timeout is invalid;
  ///   if socket creation, configuration, binding, sending, or receiving fails; or if the
  ///   response is malformed or contains a server error.
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
    let startTime = Date()

    // Format IP to in-addr.arpa
    guard let arpaQuery = _formatReverseDNS(ip, expectedFamily: AF_INET) else {
      throw DNSError.invalidIP(ip)
    }

    // Use config defaults
    let resolvedServer = server ?? "8.8.8.8"
    let resolvedTimeout = timeout ?? 3.0
    let resolvedInterface = interface ?? tracer.config.interface
    let resolvedSourceIP = sourceIP ?? tracer.config.sourceIP

    // Query PTR record
    let (answers, rtt) = try await runDNSQuery(
      server: resolvedServer, query: arpaQuery, queryType: DNSRecordType.ptr.rawValue,
      timeout: resolvedTimeout,
      interface: resolvedInterface, sourceIP: resolvedSourceIP)

    let rttMs = roundedMilliseconds(rtt)

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
  ///   - timeout: An optional query timeout in seconds. When provided, it must be finite and
  ///     greater than zero. Defaults to 3.0.
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with PTR records
  /// - Throws: ``DNSError`` if the IP address, server or source address, or timeout is invalid;
  ///   if socket creation, configuration, binding, sending, or receiving fails; or if the
  ///   response is malformed or contains a server error.
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
    let startTime = Date()

    // Format IP to ip6.arpa
    guard let arpaQuery = _formatReverseDNS(ip, expectedFamily: AF_INET6) else {
      throw DNSError.invalidIP(ip)
    }

    // Use config defaults
    let resolvedServer = server ?? "8.8.8.8"
    let resolvedTimeout = timeout ?? 3.0
    let resolvedInterface = interface ?? tracer.config.interface
    let resolvedSourceIP = sourceIP ?? tracer.config.sourceIP

    // Query PTR record
    let (answers, rtt) = try await runDNSQuery(
      server: resolvedServer, query: arpaQuery, queryType: DNSRecordType.ptr.rawValue,
      timeout: resolvedTimeout,
      interface: resolvedInterface, sourceIP: resolvedSourceIP)

    let rttMs = roundedMilliseconds(rtt)

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
  ///   - timeout: An optional query timeout in seconds. When provided, it must be finite and
  ///     greater than zero. Defaults to 3.0.
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with TXT records
  /// - Throws: ``DNSError`` if the hostname, server or source address, or timeout is invalid;
  ///   if socket creation, configuration, binding, sending, or receiving fails; or if the
  ///   response is malformed or contains a server error.
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
    let (answers, rtt) = try await runDNSQuery(
      server: resolvedServer, query: hostname, queryType: DNSRecordType.txt.rawValue,
      timeout: resolvedTimeout,
      interface: resolvedInterface, sourceIP: resolvedSourceIP)

    let rttMs = roundedMilliseconds(rtt)

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
  ///   - timeout: An optional query timeout in seconds. When provided, it must be finite and
  ///     greater than zero. Defaults to 3.0.
  ///   - interface: Network interface to bind to (defaults to config)
  ///   - sourceIP: Source IP address to bind to (defaults to config)
  /// - Returns: DNS query result with records of the requested type
  /// - Throws: ``DNSError`` if the name, server or source address, or timeout is invalid; if
  ///   socket creation, configuration, binding, sending, or receiving fails; or if the response
  ///   is malformed or contains a server error.
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
    let (answers, rtt) = try await runDNSQuery(
      server: resolvedServer, query: name, queryType: type.rawValue, timeout: resolvedTimeout,
      interface: resolvedInterface, sourceIP: resolvedSourceIP)

    let rttMs = roundedMilliseconds(rtt)

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
  /// Numeric IPv4 or IPv6 DNS server to query.
  ///
  /// This address selects the socket family independently of ``queryType``. For example, an AAAA
  /// query sent to an IPv4 server still uses an IPv4 UDP transport.
  public let server: String

  /// Query name (default: "example.com")
  public let query: String

  /// Query type (1 = A, 16 = TXT, 28 = AAAA)
  public let queryType: UInt16

  /// The query timeout in seconds.
  ///
  /// The value must be finite and greater than zero when this configuration is used.
  public let timeout: TimeInterval

  /// Network interface to bind to for this DNS probe.
  ///
  /// When specified, this probe uses only this interface. If `nil`, uses system routing.
  ///
  /// Example:
  /// ```swift
  /// func probeDNS(interfaceName: String) async throws {
  ///   let snapshot = await NetworkInterfaceDiscovery().discover()
  ///   guard let selectedInterface = snapshot.interface(named: interfaceName),
  ///     selectedInterface.isUp
  ///   else { return }
  ///
  ///   let result = try await dnsProbe(
  ///     config: DNSProbeConfig(
  ///       server: "8.8.8.8",
  ///       query: "example.com",
  ///       interface: selectedInterface.name
  ///     )
  ///   )
  /// }
  /// ```
  public let interface: String?

  /// Source IP address to bind to for this DNS probe.
  ///
  /// When specified, outgoing packets use this IP as the source address.
  /// The IP must be assigned to the selected interface.
  ///
  /// **Note**: Most users only need to set ``interface``.
  public let sourceIP: String?

  /// Creates a DNS probe configuration.
  ///
  /// Validation occurs when the configuration is passed to ``dnsProbe(config:)``.
  ///
  /// - Parameters:
  ///   - server: The DNS server IP address.
  ///   - query: The domain name to query.
  ///   - queryType: The numeric DNS record type.
  ///   - timeout: The query timeout in seconds. It must be finite and greater than zero when the
  ///     configuration is used.
  ///   - interface: The network interface to bind to, or `nil` to use system routing.
  ///   - sourceIP: The source IP address to bind to, or `nil` to let the system choose one.
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

/// How a ``dnsProbe(config:)`` ended.
///
/// Read it to tell a refused port from silence, or a reply from a malformed one, without parsing
/// ``DNSProbeResult/error``.
///
/// This is a struct with one static member per outcome rather than an enum, so a later release can
/// add an outcome without breaking a consumer's `switch`. Match the members you handle and end the
/// `switch` with `default`:
///
/// ```swift
/// switch result.outcome {
/// case .answered: showHealthy(rtt: result.rtt)
/// case .refused: showNoDNSServer()
/// case .timedOut: showSilent()
/// default: showFailed(result.error)
/// }
/// ```
///
/// It encodes as its raw string, such as `"refused"`, and decodes any string, so a result written
/// by a later release with an outcome this one does not know still decodes.
public struct DNSProbeOutcome: RawRepresentable, Hashable, Sendable, Codable,
  CustomStringConvertible
{
  /// The outcome's stable name, used in JSON.
  public let rawValue: String

  public init(rawValue: String) { self.rawValue = rawValue }

  /// A DNS response arrived, whatever its response code. ``DNSProbeResult/isReachable`` is `true`.
  public static let answered = DNSProbeOutcome(rawValue: "answered")
  /// The server's host replied that nothing is listening on the port (ICMP port unreachable).
  /// The host is up, but no DNS server answered, so ``DNSProbeResult/isReachable`` is `false`.
  public static let refused = DNSProbeOutcome(rawValue: "refused")
  /// No datagram carrying the query's transaction ID arrived before the timeout. Datagrams for
  /// another query, and ones too short to carry an ID, are ignored and do not end the wait.
  public static let timedOut = DNSProbeOutcome(rawValue: "timedOut")
  /// A datagram carried the query's transaction ID but was not a valid DNS response, such as a
  /// truncated one. The server is reachable: ``DNSProbeResult/isReachable`` is `true`.
  public static let malformedReply = DNSProbeOutcome(rawValue: "malformedReply")
  /// The server's host or network cannot be reached: the network reported it after the query was
  /// sent (ICMP host or network unreachable), or this machine refused to send toward it at all
  /// (no route, or the interface is down). ``DNSProbeResult/error`` names the errno.
  public static let unreachable = DNSProbeOutcome(rawValue: "unreachable")
  /// The probe could not run to an answer: invalid input, a socket, bind, connect or send error
  /// other than no route, or a receive error the probe does not classify. ``DNSProbeResult/error`` says which.
  public static let failed = DNSProbeOutcome(rawValue: "failed")

  public var description: String { rawValue }
}

/// Result from DNS probe
public struct DNSProbeResult: Sendable, Codable {
  /// DNS server queried
  public let server: String

  /// Query name
  public let query: String

  /// How the probe ended. See ``DNSProbeOutcome``.
  public let outcome: DNSProbeOutcome

  /// Whether server responded (success even if NXDOMAIN)
  ///
  /// `true` exactly when ``outcome`` is ``DNSProbeOutcome/answered`` or
  /// ``DNSProbeOutcome/malformedReply``.
  public let isReachable: Bool

  /// Round-trip time (nil if timeout)
  ///
  /// Seconds from sending the query to reading the reply; set exactly when ``isReachable`` is.
  public let rtt: TimeInterval?

  /// Seconds from sending the query until something came back from the network, and `nil` when
  /// nothing did.
  ///
  /// Set only when something came back: ``DNSProbeOutcome/answered``,
  /// ``DNSProbeOutcome/malformedReply``, ``DNSProbeOutcome/refused``, and
  /// ``DNSProbeOutcome/unreachable`` when the network reported it. An ``DNSProbeOutcome/unreachable``
  /// from this machine itself (no route at `connect` or `send`) has no `elapsed`, nor do
  /// ``DNSProbeOutcome/timedOut`` and ``DNSProbeOutcome/failed``. Equal to ``rtt`` when the server
  /// is reachable; the only timing for a refusal, where ``rtt`` is `nil`.
  public let elapsed: TimeInterval?

  /// Response code (0 = NOERROR, 3 = NXDOMAIN, etc.)
  public let responseCode: Int?

  /// Error message (if any)
  public let error: String?

  /// Timestamp
  public let timestamp: Date

  /// Creates a result with an explicit ``outcome`` and ``elapsed`` time.
  public init(
    server: String,
    query: String,
    outcome: DNSProbeOutcome,
    isReachable: Bool,
    rtt: TimeInterval?,
    elapsed: TimeInterval?,
    responseCode: Int?,
    error: String?,
    timestamp: Date = Date()
  ) {
    self.server = server
    self.query = query
    self.outcome = outcome
    self.isReachable = isReachable
    self.rtt = rtt
    self.elapsed = elapsed
    self.responseCode = responseCode
    self.error = error
    self.timestamp = timestamp
  }

  /// Creates a result from the fields that predate ``outcome``, deriving ``outcome`` and
  /// ``elapsed`` from them.
  ///
  /// - A reachable result is ``DNSProbeOutcome/answered`` when it has a response code or no
  ///   error, and ``DNSProbeOutcome/malformedReply`` when it has an error and no response code.
  ///   ``elapsed`` is `rtt`.
  /// - An unreachable result is read from the messages ``dnsProbe(config:)`` writes:
  ///   ``DNSProbeOutcome/refused`` for "Connection refused…", ``DNSProbeOutcome/unreachable`` for
  ///   "Host unreachable…" or "Network unreachable…", ``DNSProbeOutcome/timedOut`` for
  ///   "Timeout…" or no error, and ``DNSProbeOutcome/failed`` for any other message. ``elapsed``
  ///   is `nil`, since these fields do not record it.
  ///
  /// The derived outcome is a best effort. SwiftFTR 0.17 wrote "Timeout - no response" for a
  /// refused port, an unreachable report and a receive error as well as for silence, so a result
  /// recorded by 0.17 derives ``DNSProbeOutcome/timedOut`` for all of them: it cannot tell a
  /// refusal from silence. Only a result measured by 0.18 or later carries a measured outcome.
  public init(
    server: String,
    query: String,
    isReachable: Bool,
    rtt: TimeInterval?,
    responseCode: Int?,
    error: String?,
    timestamp: Date = Date()
  ) {
    let (outcome, elapsed) = Self.legacyOutcome(
      isReachable: isReachable, rtt: rtt, responseCode: responseCode, error: error)
    self.init(
      server: server, query: query, outcome: outcome, isReachable: isReachable, rtt: rtt,
      elapsed: elapsed, responseCode: responseCode, error: error, timestamp: timestamp)
  }

  private enum CodingKeys: String, CodingKey {
    case server, query, outcome, isReachable, rtt, elapsed, responseCode, error, timestamp
  }

  /// Decodes a result. JSON without an `outcome` key, as written before it existed, derives
  /// ``outcome`` and ``elapsed`` as the initializer without them does, with the same limit: a
  /// result written by 0.17 cannot tell a refusal from silence, and derives
  /// ``DNSProbeOutcome/timedOut`` for both.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    server = try container.decode(String.self, forKey: .server)
    query = try container.decode(String.self, forKey: .query)
    isReachable = try container.decode(Bool.self, forKey: .isReachable)
    rtt = try container.decodeIfPresent(TimeInterval.self, forKey: .rtt)
    responseCode = try container.decodeIfPresent(Int.self, forKey: .responseCode)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    timestamp = try container.decode(Date.self, forKey: .timestamp)
    if let outcome = try container.decodeIfPresent(DNSProbeOutcome.self, forKey: .outcome) {
      self.outcome = outcome
      elapsed = try container.decodeIfPresent(TimeInterval.self, forKey: .elapsed)
    } else {
      (outcome, elapsed) = Self.legacyOutcome(
        isReachable: isReachable, rtt: rtt, responseCode: responseCode, error: error)
    }
  }

  private static func legacyOutcome(
    isReachable: Bool, rtt: TimeInterval?, responseCode: Int?, error: String?
  ) -> (DNSProbeOutcome, TimeInterval?) {
    if isReachable {
      return (responseCode == nil && error != nil ? .malformedReply : .answered, rtt)
    }
    guard let error else { return (.timedOut, nil) }
    if error.hasPrefix(DNSProbeMessage.refusedPrefix) { return (.refused, nil) }
    if error.hasPrefix(DNSProbeMessage.hostUnreachablePrefix)
      || error.hasPrefix(DNSProbeMessage.networkUnreachablePrefix)
    {
      return (.unreachable, nil)
    }
    if error.hasPrefix(DNSProbeMessage.timeoutPrefix) { return (.timedOut, nil) }
    return (.failed, nil)
  }
}

/// Tests whether a DNS server responds.
///
/// Any DNS response, including NXDOMAIN, marks the server as reachable. Network and socket
/// failures are reported in the returned result.
///
/// - Parameters:
///   - server: The DNS server IP address.
///   - query: The domain name to query.
///   - timeout: The query timeout in seconds. It must be finite and greater than zero.
/// - Returns: A result describing reachability and any network or socket failure.
/// - Throws: ``DNSError/invalidTimeout(_:)`` if `timeout` is not finite and greater than zero,
///   ``DNSError/invalidHostname(_:)`` if `query` cannot be encoded as a DNS name, or
///   `CancellationError` if the calling task is cancelled.
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

/// Tests whether a DNS server responds using a configuration.
///
/// Any DNS response, including NXDOMAIN, marks the server as reachable. Network and socket
/// failures are reported in the returned result.
///
/// - Parameter config: The probe configuration. Its timeout must be finite and greater than zero.
/// - Returns: A result describing reachability and any network or socket failure.
/// - Throws: ``DNSError/invalidTimeout(_:)`` if `config.timeout` is not finite and greater than
///   zero, ``DNSError/invalidHostname(_:)`` if `config.query` cannot be encoded as a DNS name, or
///   `CancellationError` if the calling task is cancelled.
#if compiler(>=6.2)
  @concurrent
#endif
public func dnsProbe(config: DNSProbeConfig) async throws -> DNSProbeResult {
  try _validateDNSTimeout(config.timeout)
  _ = try _encodeQName(config.query)

  let startTime = Date()

  // Perform DNS query
  let result = try await performDNSProbe(
    server: config.server,
    query: config.query,
    queryType: config.queryType,
    timeout: config.timeout,
    interface: config.interface,
    sourceIP: config.sourceIP
  )

  return DNSProbeResult(
    server: config.server,
    query: config.query,
    outcome: result.outcome,
    isReachable: result.isReachable,
    rtt: result.rtt,
    elapsed: result.elapsed,
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
///   - timeout: Query timeout in seconds. It must be finite and greater than zero (default: 2.0).
///   - interface: Network interface to bind to (macOS only, optional)
///   - sourceIP: Source IP address to bind to (optional)
/// - Returns: ReverseDNSResult containing hostname (or nil) and timing information
/// - Throws: ``DNSError`` if the IP address, server or source address, or timeout is invalid; if
///   socket creation, configuration, binding, sending, or receiving fails; or if the response is
///   malformed or contains a server error.
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
  guard let reverseName = _formatReverseDNS(ip, expectedFamily: AF_INET) else {
    throw DNSError.invalidIP(ip)
  }

  // Query PTR record
  let (answers, rtt) = try await runDNSQuery(
    server: server, query: reverseName, queryType: 12, timeout: timeout,
    interface: interface, sourceIP: sourceIP)

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
///   - timeout: Query timeout in seconds. It must be finite and greater than zero (default: 2.0).
///   - interface: Network interface to bind to (macOS only, optional)
///   - sourceIP: Source IP address to bind to (optional)
/// - Returns: ReverseDNSResult containing hostname (or nil) and timing information
/// - Throws: ``DNSError`` if the IP address, server or source address, or timeout is invalid; if
///   socket creation, configuration, binding, sending, or receiving fails; or if the response is
///   malformed or contains a server error.
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
  guard let reverseName = _formatReverseDNS(ip, expectedFamily: AF_INET6) else {
    throw DNSError.invalidIP(ip)
  }

  // Query PTR record
  let (answers, rtt) = try await runDNSQuery(
    server: server, query: reverseName, queryType: 12, timeout: timeout,
    interface: interface, sourceIP: sourceIP)

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
///   - timeout: Query timeout in seconds. It must be finite and greater than zero (default: 2.0).
///   - interface: Network interface to bind to (macOS only, optional)
///   - sourceIP: Source IP address to bind to (optional)
/// - Returns: AAAAQueryResult containing IPv6 addresses and timing information
/// - Throws: ``DNSError`` if the hostname, server or source address, or timeout is invalid; if
///   socket creation, configuration, binding, sending, or receiving fails; or if the response is
///   malformed or contains a server error.
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
  let (answers, rtt) = try await runDNSQuery(
    server: server, query: hostname, queryType: 28, timeout: timeout,
    interface: interface, sourceIP: sourceIP)

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
///   - timeout: Query timeout in seconds. It must be finite and greater than zero (default: 2.0).
///   - interface: Network interface to bind to (macOS only, optional)
///   - sourceIP: Source IP address to bind to (optional)
/// - Returns: AQueryResult containing IPv4 addresses and timing information
/// - Throws: ``DNSError`` if the hostname, server or source address, or timeout is invalid; if
///   socket creation, configuration, binding, sending, or receiving fails; or if the response is
///   malformed or contains a server error.
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
  let (answers, rtt) = try await runDNSQuery(
    server: server, query: hostname, queryType: 1, timeout: timeout,
    interface: interface, sourceIP: sourceIP)

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
  let outcome: DNSProbeOutcome
  let isReachable: Bool
  /// Seconds from sending the query to reading the answer; set exactly when `isReachable` is.
  let rtt: TimeInterval?
  /// Seconds from sending the query to whatever came back from the network, if anything did.
  let elapsed: TimeInterval?
  let responseCode: Int?
  let error: String?
}

/// The messages ``dnsProbe(config:)`` writes that the legacy ``DNSProbeResult`` initializer reads
/// back to derive an outcome.
private enum DNSProbeMessage {
  static let refusedPrefix = "Connection refused"
  static let refused =
    "Connection refused - the host is up but no DNS server is listening on this port"
  static let hostUnreachablePrefix = "Host unreachable"
  static let networkUnreachablePrefix = "Network unreachable"
  static let timeoutPrefix = "Timeout"
  static let timeout = "Timeout - no response"

  static func detail(_ code: Int32) -> String {
    "(errno=\(code): \(String(cString: strerror(code))))"
  }

  /// The network's report, after the query was sent, that the server cannot be reached.
  static func unreachable(errno code: Int32) -> String {
    code == ENETUNREACH
      ? "\(networkUnreachablePrefix) - the network reported no route to the server \(detail(code))"
      : "\(hostUnreachablePrefix) - the network reported the server's host unreachable \(detail(code))"
  }

  /// This machine's refusal, at `connect` or `send`, to send toward the server.
  static func locallyUnreachable(errno code: Int32) -> String {
    switch code {
    case ENETUNREACH:
      "\(networkUnreachablePrefix) - this machine has no route to the server \(detail(code))"
    case ENETDOWN:
      "\(networkUnreachablePrefix) - the interface toward the server is down \(detail(code))"
    default:
      "\(hostUnreachablePrefix) - this machine cannot reach the server's host \(detail(code))"
    }
  }

  static let sendFailed = "Failed to send query"

  static func receiveFailed(errno code: Int32) -> String {
    "Receive failed - the socket reported an error while waiting for the reply \(detail(code))"
  }
}

/// The `connect(2)` and `send(2)` errnos that mean this machine cannot reach the server. Darwin's
/// manual pages list `EHOSTUNREACH`, `ENETDOWN` and `ENETUNREACH` for both calls. `EHOSTDOWN` is not
/// listed there; XNU's address resolution returns it from `send` when an on-link host does not
/// answer, so it is included as the same condition.
private let locallyUnreachableErrnos: Set<Int32> = [EHOSTUNREACH, EHOSTDOWN, ENETUNREACH, ENETDOWN]

/// Why a probe ended without a valid answer: the transport's failure, or the error a query step
/// threw.
private enum DNSProbeFailure {
  case transport(UDPExchangeFailure)
  /// `replyRTT` is set when the error came from validating a reply that arrived.
  case query(DNSError, replyRTT: TimeInterval?)
  /// `connect(2)` failed with `errno`.
  case connect(errno: Int32)
  /// Any other error but cancellation. None is known to reach here.
  case unexpected(any Error)
}

/// The probe result for every way a probe can end without a valid answer. Every outcome other
/// than a clean answer is decided here.
private func probeResult(for failure: DNSProbeFailure) -> DNSProbeResultInternal {
  func notReachable(
    _ outcome: DNSProbeOutcome, _ error: String, elapsed: TimeInterval? = nil
  ) -> DNSProbeResultInternal {
    DNSProbeResultInternal(
      outcome: outcome, isReachable: false, rtt: nil, elapsed: elapsed, responseCode: nil,
      error: error)
  }
  // Nothing came back from the network, so `elapsed` stays nil.
  func sendStageFailure(_ code: Int32, stage: String) -> DNSProbeResultInternal {
    locallyUnreachableErrnos.contains(code)
      ? notReachable(.unreachable, DNSProbeMessage.locallyUnreachable(errno: code))
      : notReachable(
        .failed, "\(DNSProbeMessage.sendFailed) - \(stage) failed \(DNSProbeMessage.detail(code))")
  }
  func optionFailure(_ option: String, _ code: Int32) -> String {
    "Failed to configure \(option) (errno=\(code)): \(String(cString: strerror(code)))"
  }

  switch failure {
  case .transport(.refused(let rtt)):
    return notReachable(.refused, DNSProbeMessage.refused, elapsed: rtt)
  case .transport(.unreachable(let code, let rtt)):
    return notReachable(.unreachable, DNSProbeMessage.unreachable(errno: code), elapsed: rtt)
  case .transport(.timedOut):
    return notReachable(.timedOut, DNSProbeMessage.timeout)
  case .transport(.receiveFailed(let code)):
    return notReachable(.failed, DNSProbeMessage.receiveFailed(errno: code))
  case .transport(.sendFailed(let code?)):
    return sendStageFailure(code, stage: "send")
  case .transport(.sendFailed(nil)):
    // A short send, or a deadline that passed before the datagram left.
    return notReachable(.failed, DNSProbeMessage.sendFailed)
  case .connect(let code):
    return sendStageFailure(code, stage: "connect")
  case .transport(.socketCreationFailed):
    return notReachable(.failed, "Failed to create socket")
  case .transport(.nonBlockingFailed(let code)):
    return notReachable(.failed, optionFailure("O_NONBLOCK", code))

  case .query(.serverError(let rcode), let replyRTT):
    // Any response code means a DNS server answered.
    return DNSProbeResultInternal(
      outcome: .answered, isReachable: true, rtt: replyRTT, elapsed: replyRTT,
      responseCode: rcode, error: nil)
  case .query(.noRecords, let replyRTT):
    return DNSProbeResultInternal(
      outcome: .answered, isReachable: true, rtt: replyRTT, elapsed: replyRTT, responseCode: 0,
      error: nil)
  case .query(.malformedResponse, let replyRTT):
    return DNSProbeResultInternal(
      outcome: .malformedReply, isReachable: true, rtt: replyRTT, elapsed: replyRTT,
      responseCode: nil, error: "Malformed response")
  case .query(.timeout, _):
    return notReachable(.timedOut, DNSProbeMessage.timeout)
  case .query(.socketCreationFailed, _):
    return notReachable(.failed, "Failed to create socket")
  case .query(.setsockoptFailed(let option, let code), _):
    return notReachable(.failed, optionFailure(option, code))
  case .query(.bindFailed(let message), _):
    return notReachable(.failed, message)
  case .query(.invalidIP(let ip), _):
    return notReachable(.failed, "Invalid server IP: \(ip)")
  case .query(.sendFailed, _):
    return notReachable(.failed, DNSProbeMessage.sendFailed)
  case .query(.invalidHostname(let name), _):
    return notReachable(.failed, "Invalid hostname: \(name)")
  case .query(.invalidTimeout(let timeout), _):
    return notReachable(.failed, "Invalid timeout: \(timeout)")
  case .unexpected(let error):
    return notReachable(.failed, "Unexpected error: \(error)")
  }
}

/// `connect(2)` on a DNS socket failed. The query methods report it as `DNSError.sendFailed`;
/// ``dnsProbe(config:)`` reports the errno.
private struct DNSConnectFailure: Error {
  let errno: Int32
}

/// Connect a UDP socket to a DNS server so the kernel only accepts datagrams
/// from the queried address and port.
///
/// - Throws: ``DNSError/invalidIP(_:)``, or ``DNSConnectFailure`` when `connect` fails.
private func connectDNSSocket(
  _ fd: Int32,
  server: String,
  port: UInt16,
  family: Int32
) throws {
  // The event-based path runs this on the async side, where the task-local is visible.
  let connectSocket = TestSeams.connectSocket ?? { connect($0, $1, $2) }
  let result: Int32

  if family == AF_INET6 {
    let (bare6, scopeID) = parseIPv6Scoped(server)
    var address = sockaddr_in6()
    address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    address.sin6_family = sa_family_t(AF_INET6)
    address.sin6_port = in_port_t(port).bigEndian
    address.sin6_scope_id = scopeID
    guard inet_pton(AF_INET6, bare6, &address.sin6_addr) == 1 else {
      throw DNSError.invalidIP(server)
    }
    result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        connectSocket(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in6>.size))
      }
    }
  } else {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    guard inet_pton(AF_INET, server, &address.sin_addr) == 1 else {
      throw DNSError.invalidIP(server)
    }
    result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        connectSocket(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
  }

  guard result == 0 else {
    throw DNSConnectFailure(errno: errno)
  }
}

/// Binds a DNS socket to `interface` and to `sourceIP`, when given.
private func bindDNSSocket(
  _ fd: Int32,
  family serverFamily: Int32,
  interface: String?,
  sourceIP: String?
) throws {
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
    try _validateDNSSourceFamily(srcIP, serverFamily: serverFamily)

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
}

/// Builds a DNS query for `encodedQuery` with a random transaction ID.
private func makeDNSQueryMessage(encodedQuery: [UInt8], queryType: UInt16) -> (
  bytes: [UInt8], id: UInt16
) {
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
  msg.append(contentsOf: encodedQuery)
  append16(queryType)  // QTYPE
  append16(1)  // QCLASS IN
  return ([UInt8](msg), id)
}

/// A DNS query that waits for its reply in a blocking `recv` on the calling thread.
///
/// Its only caller is ``DNSClient/queryTXTBlocking(name:timeout:servers:)``, for the whoami
/// fallback in `getPublicIPv4ViaDNS`, which runs inside a blocking public-IP closure and cannot
/// await. Every other DNS query uses the event-based ``exchangeDNSQuery``. Refusals and host and
/// network unreachable are all `DNSError.timeout` here. As on the event-based path, a datagram
/// without the query's transaction ID (an empty one included) is ignored, and the wait goes on
/// with the time left.
private func performDNSQueryBlocking(
  server: String,
  query: String,
  queryType: UInt16,
  timeout: TimeInterval,
  interface: String?,
  sourceIP: String?
) throws -> [DNSClient.Answer] {
  try _validateDNSTimeout(timeout)
  let encodedQuery = try _encodeQName(query)

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

  try bindDNSSocket(fd, family: serverFamily, interface: interface, sourceIP: sourceIP)
  try _applyDNSSocketTimeout(fd: fd, timeout: timeout)

  // A connected UDP socket only receives responses from this DNS server and port.
  do {
    try connectDNSSocket(
      fd, server: server, port: TestSeams.dnsServerPort ?? 53, family: serverFamily)
  } catch is DNSConnectFailure {
    throw DNSError.sendFailed
  }

  let (msg, id) = makeDNSQueryMessage(encodedQuery: encodedQuery, queryType: queryType)
  let deadline = monotonicNow() + timeout
  let sent = msg.withUnsafeBytes { raw in
    send(fd, raw.baseAddress, raw.count, 0)
  }

  guard sent == msg.count else {
    throw DNSError.sendFailed
  }

  // Receive from the connected peer until a datagram carries this query's transaction ID. Read on
  // the calling thread, so a test's task-local seam is visible here; production has none.
  let receiveDatagram =
    TestSeams.receiveDatagram ?? { fd, buffer in recv(fd, buffer.baseAddress, buffer.count, 0) }
  var buf = [UInt8](repeating: 0, count: dnsReceiveCapacity)
  while true {
    let n = buf.withUnsafeMutableBytes { receiveDatagram(fd, $0) }
    // `SO_RCVTIMEO` bounds the wait only to the kernel's timer granularity (about 2 ms past it on
    // loopback), so a datagram can still be returned after the deadline. A blocking `recv` returns
    // once the datagram is there, so the stamp taken on return is the earliest one that bounds its
    // arrival; one past the deadline is a timeout, on the first read as on any later one.
    guard n >= 0, monotonicNow() <= deadline else { throw DNSError.timeout }
    if DNSClient.carriesTransactionID(id, buf.prefix(n)) {
      return try DNSClient.validateResponse(message: Data(buf.prefix(n)), expectedID: id)
    }
    // Not this query's reply: wait again, for the time left rather than a fresh timeout.
    try _applyDNSSocketTimeout(fd: fd, timeout: max(deadline - monotonicNow(), 1e-6))
  }
}

/// Runs the query behind ``dnsProbe(config:)`` and reports it as a probe outcome.
///
/// Any DNS response, including an error code or a malformed reply, means the server is reachable.
/// A refusal does not: the host is up, but no DNS server answers on the port. ``probeResult(for:)``
/// decides every outcome other than a clean answer.
///
/// - Throws: `CancellationError` when the calling task is cancelled, and nothing else.
private func performDNSProbe(
  server: String,
  query: String,
  queryType: UInt16,
  timeout: TimeInterval,
  interface: String?,
  sourceIP: String?
) async throws -> DNSProbeResultInternal {
  let reply: DNSReply
  do {
    reply = try await exchangeDNSQuery(
      server: server, query: query, queryType: queryType, timeout: timeout,
      interface: interface, sourceIP: sourceIP)
  } catch let failure as UDPExchangeFailure {
    return probeResult(for: .transport(failure))
  } catch let error as DNSError {
    return probeResult(for: .query(error, replyRTT: nil))
  } catch let failure as DNSConnectFailure {
    return probeResult(for: .connect(errno: failure.errno))
  } catch let error where !(error is CancellationError) {
    return probeResult(for: .unexpected(error))
  }

  do {
    _ = try reply.answers()
  } catch let error as DNSError {
    return probeResult(for: .query(error, replyRTT: reply.rtt))
  }
  return DNSProbeResultInternal(
    outcome: .answered, isReachable: true, rtt: reply.rtt, elapsed: reply.rtt, responseCode: 0,
    error: nil)
}

// MARK: - Existing DNS Client

// Fileprivate helper so tests can call an SPI wrapper without exposing the type.
private func _encodeQName(_ name: String) throws -> [UInt8] {
  if name == "." {
    return [0]
  }

  guard !name.isEmpty else {
    throw DNSError.invalidHostname(name)
  }

  var labels = name.split(separator: ".", omittingEmptySubsequences: false)
  if labels.last?.isEmpty == true {
    labels.removeLast()
  }

  guard !labels.isEmpty, labels.allSatisfy({ !$0.isEmpty }) else {
    throw DNSError.invalidHostname(name)
  }

  var out: [UInt8] = []
  for label in labels {
    let lb = Array(label.utf8)
    guard lb.count <= 63 else {
      throw DNSError.invalidHostname(name)
    }
    out.append(UInt8(lb.count))
    out.append(contentsOf: lb)
  }

  guard out.count < 255 else {
    throw DNSError.invalidHostname(name)
  }

  out.append(0)  // terminator
  return out
}

/// Format an IP address for reverse DNS (PTR) query.
/// - IPv4 example: `"10.1.10.1"` → `"1.10.1.10.in-addr.arpa"`
/// - IPv6 example: `"2001:4860:4860::8888"` → `"8.8.8.8.0.0.0.0...0.6.8.4.0.6.8.4.1.0.0.2.ip6.arpa"`
private func _formatReverseDNS(_ ip: String, expectedFamily: Int32? = nil) -> String? {
  var addr4 = in_addr()
  if ip.withCString({ inet_pton(AF_INET, $0, &addr4) }) == 1 {
    guard expectedFamily == nil || expectedFamily == AF_INET else { return nil }
    let octets = withUnsafeBytes(of: &addr4) { Array($0) }
    return octets.reversed().map(String.init).joined(separator: ".") + ".in-addr.arpa"
  }

  // Try IPv6 — expand via inet_pton to get 16 raw bytes
  guard expectedFamily == nil || expectedFamily == AF_INET6 else { return nil }
  let scopedParts = ip.split(separator: "%", omittingEmptySubsequences: false)
  guard scopedParts.count <= 2,
    let addressPart = scopedParts.first,
    !addressPart.isEmpty,
    scopedParts.count == 1 || scopedParts[1].isEmpty == false
  else {
    return nil
  }

  let bare = String(addressPart)
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

  /// Servers the TXT lookups try, in order, when the caller names none.
  static let defaultTXTServers = ["1.1.1.1", "8.8.8.8"]

  /// TXT strings for `name` from the first of `servers` that answers, or `nil`.
  ///
  /// Each server gets `timeout` seconds. The wait holds no thread, and cancelling the calling
  /// task ends it at once.
  static func queryTXT(
    name: String, timeout: TimeInterval = 1.0, servers: [String] = defaultTXTServers
  ) async -> [String]? {
    for server in servers {
      // After cancellation each remaining attempt throws before it opens a socket.
      let answers = try? await runDNSQuery(
        server: server, query: name, queryType: DNSRecordType.txt.rawValue, timeout: timeout,
        interface: nil, sourceIP: nil
      ).answers
      if let answers, let strings = txtStrings(from: answers) { return strings }
    }
    return nil
  }

  /// ``queryTXT(name:timeout:servers:)`` waiting in a blocking `recv` on the calling thread.
  ///
  /// Its only caller is `getPublicIPv4ViaDNS`, which runs inside a blocking public-IP closure and
  /// cannot await. Do not add callers: use the async ``queryTXT(name:timeout:servers:)``.
  static func queryTXTBlocking(
    name: String, timeout: TimeInterval = 1.0, servers: [String] = defaultTXTServers
  ) -> [String]? {
    for server in servers {
      let answers = try? performDNSQueryBlocking(
        server: server,
        query: name,
        queryType: DNSRecordType.txt.rawValue,
        timeout: timeout,
        interface: nil,
        sourceIP: nil
      )
      if let answers, let strings = txtStrings(from: answers) { return strings }
    }
    return nil
  }

  /// The IN-class TXT answers, each answer's character-strings joined into one string, or `nil`
  /// when there are none.
  private static func txtStrings(from answers: [Answer]) -> [String]? {
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

  /// Whether `datagram` is addressed to the query with transaction ID `id`: it is at least the two
  /// bytes of an ID, and they are `id`. A datagram that fails this cannot be attributed to the
  /// query (a stale reply to an earlier one on the same port, or noise), so it is ignored rather
  /// than reported as a malformed reply. Every other check stays in ``validateResponse``.
  static func carriesTransactionID(_ id: UInt16, _ datagram: ArraySlice<UInt8>) -> Bool {
    guard datagram.count >= 2 else { return false }
    let start = datagram.startIndex
    return (UInt16(datagram[start]) << 8 | UInt16(datagram[start + 1])) == id
  }

  fileprivate static func validateResponse(message: Data, expectedID: UInt16) throws -> [Answer] {
    guard message.count >= 12 else {
      throw DNSError.malformedResponse
    }

    let bytes = [UInt8](message)
    func read16(_ offset: Int) -> UInt16 {
      (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    guard read16(0) == expectedID else {
      throw DNSError.malformedResponse
    }

    let flags = read16(2)
    let isResponse = (flags & 0x8000) != 0
    let opcode = flags & 0x7800
    let isTruncated = (flags & 0x0200) != 0
    guard isResponse, opcode == 0, !isTruncated else {
      throw DNSError.malformedResponse
    }

    // The question and answer records the header declares must all be present before the
    // response code is believed, whatever it is: an error reply that declares records it does
    // not carry is as malformed as a NOERROR one. A reply that declares none (QDCOUNT 0, as some
    // REFUSED and FORMERR replies are sent) passes. The authority and additional sections are
    // not checked, for any response code.
    guard let answers = parseAnswers(message: message) else {
      throw DNSError.malformedResponse
    }

    let responseCode = Int(flags & 0x000F)
    guard responseCode == 0 else {
      throw DNSError.serverError(rcode: responseCode)
    }
    return answers
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
      guard let (name, _) = parseName(bytes, &off) else { return nil }
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
          name: name,
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

  // Returns (name, newOffset). `encodedEnd` bounds the bytes used by the encoded
  // name itself; compression pointers may still refer to names elsewhere in the message.
  private static func parseName(
    _ bytes: [UInt8],
    _ offset: inout Int,
    encodedEnd: Int? = nil
  ) -> (String, Int)? {
    let initialEnd = encodedEnd ?? bytes.count
    guard offset >= 0, offset <= initialEnd, initialEnd <= bytes.count else { return nil }

    var labels: [String] = []
    var off = offset
    var jumpedTo: Int? = nil
    var visitedPointers: Set<Int> = []
    var expandedLength = 1  // Include the terminating root label.

    while true {
      let currentEnd = jumpedTo == nil ? initialEnd : bytes.count
      guard off >= 0, off < currentEnd else { return nil }

      let len = Int(bytes[off])
      if len == 0 {
        off += 1
        break
      }

      switch len & 0xC0 {
      case 0xC0:  // Compression pointer.
        guard off + 1 < currentEnd else { return nil }
        let ptr = ((len & 0x3F) << 8) | Int(bytes[off + 1])
        guard
          ptr < off,
          visitedPointers.insert(ptr).inserted
        else { return nil }
        if jumpedTo == nil { jumpedTo = off + 2 }
        off = ptr

      case 0x00:  // Ordinary label (maximum length 63 by construction).
        guard off + 1 + len <= currentEnd else { return nil }
        expandedLength += 1 + len
        guard expandedLength <= 255 else { return nil }
        let s = String(decoding: bytes[(off + 1)..<(off + 1 + len)], as: UTF8.self)
        labels.append(s)
        off += 1 + len

      default:  // 01xxxxxx and 10xxxxxx are reserved label encodings.
        return nil
      }
    }

    if let j = jumpedTo { offset = j } else { offset = off }
    let name = labels.joined(separator: ".")
    return (name, offset)
  }

  private static func rdataEnd(
    rdata: Data,
    rdataOffsetInMessage: Int,
    fullMessage: Data
  ) -> Int? {
    guard
      rdataOffsetInMessage >= 0,
      rdataOffsetInMessage <= fullMessage.count,
      rdata.count <= fullMessage.count - rdataOffsetInMessage
    else { return nil }

    return rdataOffsetInMessage + rdata.count
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
    guard
      let end = rdataEnd(
        rdata: rdata,
        rdataOffsetInMessage: rdataOffsetInMessage,
        fullMessage: fullMessage
      ),
      let (name, _) = parseName(bytes, &offset, encodedEnd: end),
      offset == end
    else { return nil }
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
    guard
      rdata.count >= 2,
      let end = rdataEnd(
        rdata: rdata,
        rdataOffsetInMessage: rdataOffsetInMessage,
        fullMessage: fullMessage
      )
    else { return nil }
    let bytes = [UInt8](rdata)

    // Read priority (2 bytes)
    let priority = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])

    // Read exchange name (domain name with compression)
    let fullBytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage + 2  // Skip priority
    guard
      let (exchange, _) = parseName(fullBytes, &offset, encodedEnd: end),
      offset == end
    else { return nil }

    return (priority, exchange)
  }

  /// Parse NS record (name server) from RDATA
  /// Returns name server hostname
  static func parseNS(rdata: Data, rdataOffsetInMessage: Int, fullMessage: Data) -> String? {
    let bytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage
    guard
      let end = rdataEnd(
        rdata: rdata,
        rdataOffsetInMessage: rdataOffsetInMessage,
        fullMessage: fullMessage
      ),
      let (name, _) = parseName(bytes, &offset, encodedEnd: end),
      offset == end
    else { return nil }
    return name
  }

  /// Parse CNAME record (canonical name) from RDATA
  /// Returns canonical name
  static func parseCNAME(rdata: Data, rdataOffsetInMessage: Int, fullMessage: Data) -> String? {
    let bytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage
    guard
      let end = rdataEnd(
        rdata: rdata,
        rdataOffsetInMessage: rdataOffsetInMessage,
        fullMessage: fullMessage
      ),
      let (name, _) = parseName(bytes, &offset, encodedEnd: end),
      offset == end
    else { return nil }
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
    guard
      let end = rdataEnd(
        rdata: rdata,
        rdataOffsetInMessage: rdataOffsetInMessage,
        fullMessage: fullMessage
      )
    else { return nil }

    // Parse primary name server
    guard let (primaryNS, _) = parseName(bytes, &offset, encodedEnd: end) else { return nil }

    // Parse admin email
    guard let (adminEmail, _) = parseName(bytes, &offset, encodedEnd: end) else { return nil }

    // Parse 5 32-bit values: serial, refresh, retry, expire, minimum
    guard offset <= end, end - offset == 20 else { return nil }

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
    guard
      rdata.count >= 6,
      let end = rdataEnd(
        rdata: rdata,
        rdataOffsetInMessage: rdataOffsetInMessage,
        fullMessage: fullMessage
      )
    else { return nil }
    let bytes = [UInt8](rdata)

    // Read priority, weight, port (2 bytes each)
    let priority = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    let weight = (UInt16(bytes[2]) << 8) | UInt16(bytes[3])
    let port = (UInt16(bytes[4]) << 8) | UInt16(bytes[5])

    // Read target name
    let fullBytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage + 6  // Skip priority, weight, port
    guard
      let (target, _) = parseName(fullBytes, &offset, encodedEnd: end),
      offset == end
    else { return nil }

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
    guard
      rdata.count >= 2,
      rdataOffsetInMessage >= 0,
      rdataOffsetInMessage <= fullMessage.count,
      rdata.count <= fullMessage.count - rdataOffsetInMessage
    else { return nil }
    let bytes = [UInt8](rdata)

    // Read priority (2 bytes)
    let priority = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])

    // Read target name
    let fullBytes = [UInt8](fullMessage)
    var offset = rdataOffsetInMessage + 2  // Skip priority
    guard let (target, consumedOffset) = parseName(fullBytes, &offset) else { return nil }

    // Remaining bytes are SvcParams (keep as raw data for now - parsing is complex)
    let svcParamsStart = consumedOffset - rdataOffsetInMessage
    guard svcParamsStart >= 2, svcParamsStart <= rdata.count else { return nil }
    let svcParams = rdata.subdata(in: svcParamsStart..<rdata.count)

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

@_spi(Test)
public struct __DNSAnswer: Sendable {
  public let name: String
  public let type: UInt16
  public let klass: UInt16
  public let ttl: UInt32
  public let rdata: Data
}

/// One DNS query over the event-based transport to `server` on `port`, the path every public
/// query method takes.
// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsQuery(
  server: String,
  port: UInt16,
  name: String,
  type: UInt16,
  timeout: TimeInterval = 1.0
) async throws -> [__DNSAnswer] {
  try await runDNSQuery(
    server: server,
    query: name,
    queryType: type,
    timeout: timeout,
    interface: nil,
    sourceIP: nil,
    serverPort: port
  ).answers.map { answer in
    __DNSAnswer(
      name: answer.name,
      type: answer.type,
      klass: answer.klass,
      ttl: answer.ttl,
      rdata: answer.rdata
    )
  }
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsEncodeQName(_ name: String) -> [UInt8] {
  // Preserve the original nonthrowing SPI used by parser fixtures. Production query paths call
  // the throwing encoder directly and surface invalid names as `DNSError.invalidHostname`.
  (try? _encodeQName(name)) ?? []
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __dnsApplySocketTimeout(fd: Int32, timeout: TimeInterval) throws {
  try _applyDNSSocketTimeout(fd: fd, timeout: timeout)
}

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
