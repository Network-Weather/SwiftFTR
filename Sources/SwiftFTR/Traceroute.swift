import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One hop result in a traceroute.
/// - Note: `ipAddress` is the responder's IPv4 address string. It is not a hostname.
public struct TraceHop: Sendable {
    /// Time-To-Live probed for this hop (1-based).
    public let ttl: Int
    /// Responder IPv4 address as a string (not reverse-resolved). `nil` if timed out.
    public let ipAddress: String?
    /// Round-trip time in seconds for this hop, or `nil` if no reply.
    public let rtt: TimeInterval?
    /// Whether this reply came from the destination host.
    public let reachedDestination: Bool
    public init(ttl: Int, ipAddress: String?, rtt: TimeInterval?, reachedDestination: Bool) {
        self.ttl = ttl; self.ipAddress = ipAddress; self.rtt = rtt; self.reachedDestination = reachedDestination
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
    public init(destination: String, maxHops: Int, reached: Bool, hops: [TraceHop], duration: TimeInterval = 0) {
        self.destination = destination
        self.maxHops = maxHops
        self.reached = reached
        self.hops = hops
        self.duration = duration
    }
}

public enum TracerouteError: Error, CustomStringConvertible {
    case resolutionFailed
    case socketCreateFailed(errno: Int32)
    case setsockoptFailed(option: String, errno: Int32)
    case sendFailed(errno: Int32)

    public var description: String {
        switch self {
        case .resolutionFailed: return "Failed to resolve host"
        case .socketCreateFailed(let e): return "socket() failed: \(String(cString: strerror(e)))"
        case .setsockoptFailed(let opt, let e): return "setsockopt(\(opt)) failed: \(String(cString: strerror(e)))"
        case .sendFailed(let e): return "sendto failed: \(String(cString: strerror(e)))"
        }
    }
}

public struct SwiftFTR: Sendable {
    public init() {}

    /// Perform a fast traceroute by sending one ICMP Echo per TTL and waiting once.
    /// - Parameters:
    ///   - host: Destination hostname or IPv4 address.
    ///   - maxHops: Maximum TTL to probe. Typical internet paths are under 30.
    ///   - timeout: Overall wait (seconds) after sending all probes. Controls wall-clock duration.
    ///   - payloadSize: Size in bytes of the Echo payload. Larger payloads can influence path/MTU behavior.
    /// - Returns: A `TraceResult` with ordered hops and whether the destination responded.
    public func trace(
        to host: String,
        maxHops: Int = 30,
        timeout: TimeInterval = 1.0,
        payloadSize: Int = 56
    ) async throws -> TraceResult {
        // Resolve host (IPv4 only)
        let destAddr = try resolveIPv4(host: host)

        // Create ICMP datagram socket (no root required on macOS)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        if fd < 0 { throw TracerouteError.socketCreateFailed(errno: errno) }
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
        struct SendInfo { let ttl: Int; let sentAt: TimeInterval }
        var outstanding: [UInt16: SendInfo] = [:] // key = sequence (== ttl)

        // Send one probe per TTL, quickly adjusting IP_TTL between sends.
        for ttl in 1...maxHops {
            var ttlVar: Int32 = Int32(ttl)
            if setsockopt(fd, IPPROTO_IP, IP_TTL, &ttlVar, socklen_t(MemoryLayout<Int32>.size)) != 0 {
                throw TracerouteError.setsockoptFailed(option: "IP_TTL", errno: errno)
            }
            let seq: UInt16 = UInt16(truncatingIfNeeded: ttl)
            let packet = makeICMPEchoRequest(identifier: identifier, sequence: seq, payloadSize: payloadSize)
            let sentAt = monotonicNow()
            var addr = destAddr
            let sent = packet.withUnsafeBytes { rawBuf in
                withUnsafePointer(to: &addr) { aptr -> ssize_t in
                    aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                        sendto(fd, rawBuf.baseAddress!, rawBuf.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
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
        var storage = sockaddr_storage()
        // Use a named constant to avoid magic numbers for buffer sizes.
        var buf = [UInt8](repeating: 0, count: Constants.receiveBufferSize)

        // Receive loop until timeout or all TTLs resolved up to reachedTTL.
        // The loop uses poll(2) to wait for readability and then drains datagrams.
        recvLoop: while monotonicNow() < deadline {
            var fds = Darwin.pollfd(fd: fd, events: Int16(Darwin.POLLIN), revents: 0)
            let msLeft = Int32(max(0, (deadline - monotonicNow()) * 1000))
            let rv = withUnsafeMutablePointer(to: &fds) { p in Darwin.poll(p, 1, msLeft) }
            if rv <= 0 { break }

            // Drain available datagrams
            while true {
                var addrlen: socklen_t = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let n = withUnsafeMutablePointer(to: &storage) { sptr -> ssize_t in
                    sptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saptr in
                        return recvfrom(fd, &buf, buf.count, 0, saptr, &addrlen)
                    }
                }
                if n < 0 {
                    if errno == EWOULDBLOCK || errno == EAGAIN { break }
                    else { break }
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
                            hops[hopIndex] = TraceHop(ttl: info.ttl, ipAddress: parsed.sourceAddress, rtt: rtt, reachedDestination: true)
                        }
                        if reachedTTL == nil || info.ttl < reachedTTL! { reachedTTL = info.ttl }
                    }
                case .timeExceeded(let originalID, let originalSeq):
                    guard originalID == nil || originalID == identifier else { continue }
                    if let seq = originalSeq, let info = outstanding[seq] {
                        let hopIndex = min(max(info.ttl - 1, 0), maxHops - 1)
                        if hops[hopIndex] == nil {
                            let rtt = monotonicNow() - info.sentAt
                            hops[hopIndex] = TraceHop(ttl: info.ttl, ipAddress: parsed.sourceAddress, rtt: rtt, reachedDestination: false)
                        }
                    }
                case .destinationUnreachable(let originalID, let originalSeq):
                    guard originalID == nil || originalID == identifier else { continue }
                    if let seq = originalSeq, let info = outstanding.removeValue(forKey: seq) {
                        let hopIndex = min(max(info.ttl - 1, 0), maxHops - 1)
                        let rtt = monotonicNow() - info.sentAt
                        if hops[hopIndex] == nil {
                            hops[hopIndex] = TraceHop(ttl: info.ttl, ipAddress: parsed.sourceAddress, rtt: rtt, reachedDestination: false)
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
                        if hops[i] == nil { done = false; break }
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

        let finalHops = Array(hops[0..<(reachedTTL ?? maxHops)]).compactMap { $0 }
        let result = TraceResult(
            destination: host,
            maxHops: maxHops,
            reached: reachedTTL != nil,
            hops: finalHops,
            duration: Date().timeIntervalSince(startWall)
        )
        return result
    }

    public func traceClassified(
        to host: String,
        maxHops: Int = 30,
        timeout: TimeInterval = 1.0,
        payloadSize: Int = 56,
        resolver: ASNResolver = CachingASNResolver(base: CymruDNSResolver())
    ) async throws -> ClassifiedTrace {
        // Do the trace
        let destAddr = try resolveIPv4(host: host)
        let destIP = ipString(destAddr)
        let tr = try await trace(to: host, maxHops: maxHops, timeout: timeout, payloadSize: payloadSize)
        // Classify
        let classifier = TraceClassifier()
        return try classifier.classify(trace: tr, destinationIP: destIP, resolver: resolver, timeout: 1.5)
    }
}

// Helpers
fileprivate func resolveIPv4(host: String) throws -> sockaddr_in {
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
    guard err == 0, let info = res else { throw TracerouteError.resolutionFailed }
    defer { freeaddrinfo(info) }
    if info.pointee.ai_family == AF_INET, let sa = info.pointee.ai_addr {
        memcpy(&addr, sa, min(MemoryLayout<sockaddr_in>.size, Int(info.pointee.ai_addrlen)))
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa.pointee.sa_family
        return addr
    }
    throw TracerouteError.resolutionFailed
}

// Use Darwin.poll and Darwin.pollfd directly

private enum Constants {
    /// Receive buffer size for incoming ICMP datagrams.
    static let receiveBufferSize = 2048
}
