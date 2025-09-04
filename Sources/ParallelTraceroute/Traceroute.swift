import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct TraceHop: Sendable {
    public let ttl: Int
    public let host: String?
    public let rtt: TimeInterval?
    public let reachedDestination: Bool
}

public struct TraceResult: Sendable {
    public let destination: String
    public let maxHops: Int
    public let reached: Bool
    public let hops: [TraceHop]
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

public struct ParallelTraceroute: Sendable {
    public init() {}

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

        // Set non-blocking
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        // Enable receiving TTL of replies (best-effort)
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
            let sentAt = CFAbsoluteTimeGetCurrent()
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

        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        var storage = sockaddr_storage()

        // Receive loop until timeout or all TTLs resolved up to reachedTTL
        recvLoop: while CFAbsoluteTimeGetCurrent() < deadline {
            var fds = Darwin.pollfd(fd: fd, events: Int16(Darwin.POLLIN), revents: 0)
            let msLeft = Int32(max(0, (deadline - CFAbsoluteTimeGetCurrent()) * 1000))
            let rv = withUnsafeMutablePointer(to: &fds) { p in Darwin.poll(p, 1, msLeft) }
            if rv <= 0 { break }

            // Drain available datagrams
            while true {
                var buf = [UInt8](repeating: 0, count: 2048)
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
                        let rtt = CFAbsoluteTimeGetCurrent() - info.sentAt
                        let hopIndex = min(max(info.ttl - 1, 0), maxHops - 1)
                        if hops[hopIndex] == nil {
                            hops[hopIndex] = TraceHop(ttl: info.ttl, host: parsed.sourceAddress, rtt: rtt, reachedDestination: true)
                        }
                        if reachedTTL == nil || info.ttl < reachedTTL! { reachedTTL = info.ttl }
                    }
                case .timeExceeded(let originalID, let originalSeq):
                    guard originalID == nil || originalID == identifier else { continue }
                    if let seq = originalSeq, let info = outstanding[seq] {
                        let hopIndex = min(max(info.ttl - 1, 0), maxHops - 1)
                        if hops[hopIndex] == nil {
                            let rtt = CFAbsoluteTimeGetCurrent() - info.sentAt
                            hops[hopIndex] = TraceHop(ttl: info.ttl, host: parsed.sourceAddress, rtt: rtt, reachedDestination: false)
                        }
                    }
                case .destinationUnreachable(let originalID, let originalSeq):
                    guard originalID == nil || originalID == identifier else { continue }
                    if let seq = originalSeq, let info = outstanding.removeValue(forKey: seq) {
                        let hopIndex = min(max(info.ttl - 1, 0), maxHops - 1)
                        let rtt = CFAbsoluteTimeGetCurrent() - info.sentAt
                        if hops[hopIndex] == nil {
                            hops[hopIndex] = TraceHop(ttl: info.ttl, host: parsed.sourceAddress, rtt: rtt, reachedDestination: false)
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
                hops[idx] = TraceHop(ttl: ttl, host: nil, rtt: nil, reachedDestination: false)
            }
        }

        let finalHops = Array(hops[0..<(reachedTTL ?? maxHops)]).compactMap { $0 }
        let result = TraceResult(
            destination: host,
            maxHops: maxHops,
            reached: reachedTTL != nil,
            hops: finalHops
        )
        return result
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
