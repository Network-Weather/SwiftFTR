// ICMPv6 traceroute spike.
//
// Manually drives hop-limit cycling 1..maxHops against a v6 target from a single
// SOCK_DGRAM IPPROTO_ICMPV6 socket. Validates three things before Traceroute.swift
// gets touched:
//   1. Intermediate routers actually deliver ICMPv6 Time Exceeded in this network
//      environment (some networks/firewalls drop them).
//   2. The library's existing parseICMPv6Message correctly recovers the embedded
//      original identifier/sequence from real Time Exceeded messages.
//   3. The same socket can receive both Echo Reply (from destination) and Time
//      Exceeded (from intermediates) without trouble.
//
// Uses the @_spi(Test) parser exposed by Stage 1 — `__parseV6PingMessage` from
// SwiftFTR — so we exercise the actual production code path on real wire data.
//
// Run:
//     swift run traceroute6probe                          # defaults to Cloudflare
//     swift run traceroute6probe 2001:4860:4860::8888    # custom target
//     swift run traceroute6probe 2606:4700:4700::1111 20 # custom hop ceiling

import Darwin
import Foundation
@_spi(Test) import SwiftFTR

// IPV6_RECVHOPLIMIT = 37 per <netinet6/in6.h>. Same as Ping.swift / icmpv6probe.
// swift-format-ignore: AlwaysUseLowerCamelCase
private let IPV6_RECVHOPLIMIT_OPT: Int32 = 37

@main
struct Traceroute6Probe {
  static func main() {
    let args = CommandLine.arguments
    let target = args.count >= 2 ? args[1] : "2606:4700:4700::1111"
    let maxHops = args.count >= 3 ? (Int(args[2]) ?? 30) : 30

    print("Tracing \(target) with hop-limit cycling 1..\(maxHops)…\n")

    let sockfd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
    guard sockfd >= 0 else {
      perror("socket")
      exit(1)
    }
    defer { close(sockfd) }

    var on: Int32 = 1
    _ = setsockopt(
      sockfd, IPPROTO_IPV6, IPV6_RECVHOPLIMIT_OPT, &on, socklen_t(MemoryLayout<Int32>.size))

    var dest = sockaddr_in6()
    dest.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    dest.sin6_family = sa_family_t(AF_INET6)
    guard inet_pton(AF_INET6, target, &dest.sin6_addr) == 1 else {
      fputs("FATAL: could not parse \(target) as IPv6\n", stderr)
      exit(1)
    }

    let identifier: UInt16 = 0xABCD

    for ttl in 1...maxHops {
      var hopLimit = Int32(ttl)
      _ = setsockopt(
        sockfd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &hopLimit, socklen_t(MemoryLayout<Int32>.size))

      let sequence = UInt16(ttl)
      var pkt = [UInt8](repeating: 0, count: 16)
      pkt[0] = 128  // ICMPv6 Echo Request
      pkt[4] = UInt8(identifier >> 8)
      pkt[5] = UInt8(identifier & 0xFF)
      pkt[6] = UInt8(sequence >> 8)
      pkt[7] = UInt8(sequence & 0xFF)
      for i in 0..<8 { pkt[8 + i] = 0x61 + UInt8(i) }

      let sent = withUnsafePointer(to: &dest) { dp -> ssize_t in
        dp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          pkt.withUnsafeBufferPointer { buf in
            sendto(
              sockfd, buf.baseAddress, pkt.count, 0, sa,
              socklen_t(MemoryLayout<sockaddr_in6>.size))
          }
        }
      }
      guard sent == pkt.count else {
        perror("sendto")
        exit(1)
      }

      var tv = timeval(tv_sec: 1, tv_usec: 0)
      _ = setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

      var recvBuf = [UInt8](repeating: 0, count: 1500)
      var fromAddr = sockaddr_storage()
      var iov = iovec()
      var msg = msghdr()
      var cbuf = [UInt8](repeating: 0, count: 64)

      let received = recvBuf.withUnsafeMutableBufferPointer { rb -> ssize_t in
        cbuf.withUnsafeMutableBufferPointer { cb -> ssize_t in
          withUnsafeMutablePointer(to: &fromAddr) { fp -> ssize_t in
            iov.iov_base = UnsafeMutableRawPointer(rb.baseAddress)
            iov.iov_len = rb.count
            return withUnsafeMutablePointer(to: &iov) { iovPtr in
              msg.msg_name = UnsafeMutableRawPointer(fp)
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

      if received < 0 {
        print("  \(ttl): * (timeout)")
        continue
      }

      let parsed = recvBuf.withUnsafeBytes { raw -> TestParsedPingMessage? in
        let slice = UnsafeRawBufferPointer(start: raw.baseAddress, count: Int(received))
        return __parseV6PingMessage(
          buffer: slice, hopLimit: nil, expectedIdentifier: identifier)
      }

      var sin6 = sockaddr_in6()
      withUnsafePointer(to: &fromAddr) { fp in
        fp.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
          sin6 = $0.pointee
        }
      }
      var sbuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
      _ = withUnsafePointer(to: &sin6.sin6_addr) { addrPtr in
        inet_ntop(AF_INET6, addrPtr, &sbuf, socklen_t(INET6_ADDRSTRLEN))
      }
      let src = sbuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }

      var done = false
      switch parsed {
      case .echoReply(let seq, _):
        print("  \(ttl): \(src)   (Echo Reply seq=\(seq) — DESTINATION)")
        done = true
      case .timeExceeded(let origSeq, _, _):
        print("  \(ttl): \(src)   (Time Exceeded, orig seq=\(origSeq))")
      case .destinationUnreachable(let origSeq, _, let code):
        print(
          "  \(ttl): \(src)   (Destination Unreachable, code=\(code), orig seq=\(origSeq))")
      case .none:
        print(
          "  \(ttl): \(src)   (received \(received) bytes but parser returned nil — likely id mismatch)"
        )
      }
      if done { break }
    }

    print("\nDone.")
  }
}
