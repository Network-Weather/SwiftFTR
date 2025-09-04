import Foundation

public enum HopCategory: String, Sendable, Codable {
    case local = "LOCAL"
    case isp = "ISP"
    case transit = "TRANSIT"
    case destination = "DESTINATION"
    case unknown = "UNKNOWN"
}

public struct ClassifiedHop: Sendable, Codable {
    public let ttl: Int
    public let ip: String?
    public let rtt: TimeInterval?
    public let asn: Int?
    public let asName: String?
    public let category: HopCategory
}

public struct ClassifiedTrace: Sendable, Codable {
    public let destinationHost: String
    public let destinationIP: String
    public let publicIP: String?
    public let clientASN: Int?
    public let clientASName: String?
    public let destinationASN: Int?
    public let destinationASName: String?
    public let hops: [ClassifiedHop]
}

public struct TraceClassifier: Sendable {
    public init() {}

    public func classify(
        trace: TraceResult,
        destinationIP: String,
        resolver: ASNResolver,
        timeout: TimeInterval = 1.5
    ) throws -> ClassifiedTrace {
        // Gather IPs
        let hopIPs: [String] = trace.hops.compactMap { $0.host }
        var allIPs = Set(hopIPs)
        allIPs.insert(destinationIP)
        var publicIP: String? = nil
        let env = ProcessInfo.processInfo.environment
        if let pubOverride = env["PTR_PUBLIC_IP"], !pubOverride.isEmpty {
            publicIP = pubOverride
            allIPs.insert(pubOverride)
        } else {
            // Try STUN (best effort) unless disabled via env
            let skipSTUN = env["PTR_SKIP_STUN"] == "1"
            if !skipSTUN {
                if let pub = try? stunGetPublicIPv4(timeout: 0.8) { publicIP = pub.ip; allIPs.insert(pub.ip) }
            }
        }

        // Lookup ASNs in batch
        let asnMap = try? resolver.resolve(ipv4Addrs: Array(allIPs), timeout: timeout)
        let clientAS = publicIP.flatMap { asnMap?[$0] }
        let clientASN = clientAS?.asn
        let clientASName = clientAS?.name
        let destAS = asnMap?[destinationIP]
        let destASN = destAS?.asn
        let destASName = destAS?.name

        // Classify hops
        var out: [ClassifiedHop] = []
        for hop in trace.hops {
            let ip = hop.host
            var cat: HopCategory = .unknown
            var asn: Int? = nil
            var name: String? = nil
            if let ip = ip {
                if isPrivateIPv4(ip) {
                    cat = .local
                } else if isCGNATIPv4(ip) {
                    // CGNAT indicates ISP regardless of ASN lookup availability
                    cat = .isp
                }
                asn = asnMap?[ip]?.asn
                name = asnMap?[ip]?.name
                if let asn = asn {
                    if let cASN = clientASN, asn == cASN { cat = .isp }
                    if let dASN = destASN, asn == dASN { cat = .destination }
                    if cat == .unknown { cat = .transit }
                } else if cat == .unknown {
                    // No ASN found for a public IP: mark as TRANSIT per spec
                    cat = .transit
                }
            }
            out.append(ClassifiedHop(ttl: hop.ttl, ip: ip, rtt: hop.rtt, asn: asn, asName: name, category: cat))
        }

        // Interpolate non-reported segments (ip == nil) that are sandwiched between
        // identical categories (and, when possible, the same ASN) on both sides.
        if out.count >= 3 {
            var filled = out
            var i = 0
            while i < filled.count {
                // Find a run of missing replies
                if filled[i].ip == nil {
                    let start = i
                    var end = i
                    while end < filled.count && filled[end].ip == nil { end += 1 }
                    let leftIdx = start - 1
                    let rightIdx = end
                    if leftIdx >= 0 && rightIdx < filled.count {
                        let left = filled[leftIdx]
                        let right = filled[rightIdx]
                        if left.category != .unknown && right.category != .unknown && left.category == right.category {
                            // Category to fill
                            let cat = left.category
                            // ASN to fill if consistent on both sides
                            var fillASN: Int? = nil
                            var fillName: String? = nil
                            if let la = left.asn, let ra = right.asn, la == ra {
                                fillASN = la
                                fillName = left.asName ?? right.asName
                            }
                            for k in start..<end {
                                let hop = filled[k]
                                filled[k] = ClassifiedHop(ttl: hop.ttl, ip: hop.ip, rtt: hop.rtt, asn: fillASN, asName: fillName, category: cat)
                            }
                        }
                    }
                    i = end
                } else {
                    i += 1
                }
            }
            out = filled
        }

        return ClassifiedTrace(
            destinationHost: trace.destination,
            destinationIP: destinationIP,
            publicIP: publicIP,
            clientASN: clientASN,
            clientASName: clientASName,
            destinationASN: destASN,
            destinationASName: destASName,
            hops: out
        )
    }
}
