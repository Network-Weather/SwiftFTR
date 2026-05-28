// ICMPv6 wire-format spike.
//
// Validates Darwin's SOCK_DGRAM IPPROTO_ICMPV6 behavior before we depend on it
// in Ping.swift. Run with:
//
//     swift run icmpv6probe 2606:4700:4700::1111
//
// Prints: raw bytes received, whether an IPv6 header is present, ICMPv6 type/code,
// identifier as delivered, sequence, hop limit recovered from cmsg.

import Darwin
import Foundation

// Darwin socket constants not bridged into Swift via Darwin.
// IPV6_RECVHOPLIMIT = 37 (per netinet6/in6.h on macOS 26.5 SDK; same since 10.x).
// IPV6_HOPLIMIT (cmsg type for received hop limit) is one of two values depending on
// which RFC API is selected: 20 (RFC 2292, default) or 47 (RFC 3542). We accept
// either when scanning ancillary data. Naming mirrors the C macros.
// swift-format-ignore: AlwaysUseLowerCamelCase
private let IPV6_RECVHOPLIMIT_OPT: Int32 = 37
// swift-format-ignore: AlwaysUseLowerCamelCase
private let IPV6_HOPLIMIT_CMSG_2292: Int32 = 20
// swift-format-ignore: AlwaysUseLowerCamelCase
private let IPV6_HOPLIMIT_CMSG_3542: Int32 = 47

@main
struct ICMPv6Probe {
  static func main() {
    let args = CommandLine.arguments
    guard args.count >= 2 else {
      fputs("usage: \(args[0]) <ipv6-target>\n", stderr)
      exit(2)
    }
    let target = args[1]

    // 1. Open SOCK_DGRAM ICMPv6 socket. No root required on Darwin.
    let sockfd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6)
    guard sockfd >= 0 else {
      perror("socket")
      exit(1)
    }
    defer { close(sockfd) }

    // 2. Ask the kernel to deliver hop limit as ancillary data on recvmsg.
    var on: Int32 = 1
    if setsockopt(
      sockfd, IPPROTO_IPV6, IPV6_RECVHOPLIMIT_OPT, &on, socklen_t(MemoryLayout<Int32>.size)) < 0
    {
      perror("setsockopt IPV6_RECVHOPLIMIT")
    }

    // 3. Set outgoing hop limit so we don't depend on the kernel default.
    var hops: Int32 = 64
    if setsockopt(
      sockfd, IPPROTO_IPV6, IPV6_UNICAST_HOPS, &hops, socklen_t(MemoryLayout<Int32>.size)) < 0
    {
      perror("setsockopt IPV6_UNICAST_HOPS")
    }

    // 4. Resolve destination into sockaddr_in6.
    var dest = sockaddr_in6()
    dest.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
    dest.sin6_family = sa_family_t(AF_INET6)
    dest.sin6_port = 0
    if inet_pton(AF_INET6, target, &dest.sin6_addr) != 1 {
      // Not a numeric address; try getaddrinfo.
      var hints = addrinfo()
      hints.ai_family = AF_INET6
      hints.ai_socktype = SOCK_DGRAM
      hints.ai_protocol = IPPROTO_ICMPV6
      var res: UnsafeMutablePointer<addrinfo>?
      guard getaddrinfo(target, nil, &hints, &res) == 0, let r = res else {
        fputs("could not resolve \(target) as IPv6\n", stderr)
        exit(1)
      }
      defer { freeaddrinfo(res) }
      memcpy(&dest, r.pointee.ai_addr, MemoryLayout<sockaddr_in6>.size)
    }

    // 5. Build ICMPv6 Echo Request. Type=128, code=0. Checksum left zero — kernel
    //    must fill it because the ICMPv6 checksum includes the IPv6 pseudo-header
    //    (src/dst) which userspace doesn't know on a SOCK_DGRAM socket.
    let identifier: UInt16 = 0x4243
    let sequence: UInt16 = 0x0001
    let payloadBytes = 32
    var pkt = [UInt8](repeating: 0, count: 8 + payloadBytes)
    pkt[0] = 128  // echoRequest
    pkt[1] = 0  // code
    pkt[2] = 0
    pkt[3] = 0  // checksum (kernel fills)
    pkt[4] = UInt8(identifier >> 8)
    pkt[5] = UInt8(identifier & 0xFF)
    pkt[6] = UInt8(sequence >> 8)
    pkt[7] = UInt8(sequence & 0xFF)
    for i in 0..<payloadBytes { pkt[8 + i] = 0x61 + UInt8(i % 26) }

    let sent = withUnsafePointer(to: &dest) { dptr -> ssize_t in
      dptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
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
    print(
      "sent \(sent) bytes (ICMPv6 Echo Request, id=0x\(String(identifier, radix: 16)) seq=\(sequence))"
    )

    // 6. recvmsg with ancillary buffer for IPV6_HOPLIMIT.
    var recvBuf = [UInt8](repeating: 0, count: 1500)
    var fromAddr = sockaddr_in6()
    var iov = iovec()
    var msg = msghdr()
    // CMSG_SPACE(int) on Darwin = __DARWIN_ALIGN32(sizeof(cmsghdr)) + __DARWIN_ALIGN32(sizeof(int))
    // = 16 + 4 = 20. Allocate 64 for headroom in case the kernel emits more than one cmsg.
    var cbuf = [UInt8](repeating: 0, count: 64)

    // Wait up to 2 seconds for a reply.
    var tv = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    let received = recvBuf.withUnsafeMutableBufferPointer { rb -> ssize_t in
      cbuf.withUnsafeMutableBufferPointer { cb -> ssize_t in
        withUnsafeMutablePointer(to: &fromAddr) { faPtr -> ssize_t in
          iov.iov_base = UnsafeMutableRawPointer(rb.baseAddress)
          iov.iov_len = rb.count
          return withUnsafeMutablePointer(to: &iov) { iovPtr in
            msg.msg_name = UnsafeMutableRawPointer(faPtr)
            msg.msg_namelen = socklen_t(MemoryLayout<sockaddr_in6>.size)
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
      perror("recvmsg")
      exit(1)
    }
    print("recvmsg returned \(received) bytes")

    // 7. Inspect the payload. Does it start with an IPv6 header (first byte 0x6X)?
    if received >= 1 {
      let leadHi = recvBuf[0] >> 4
      print(
        "  first byte 0x\(String(format: "%02x", recvBuf[0])) "
          + "(version nibble = \(leadHi) — IPv6 header would be 6, kernel stripped if not)")
    }
    if received >= 8 {
      // Assume kernel stripped IPv6 header so ICMPv6 header starts at offset 0.
      let type = recvBuf[0]
      let code = recvBuf[1]
      let id = (UInt16(recvBuf[4]) << 8) | UInt16(recvBuf[5])
      let seq = (UInt16(recvBuf[6]) << 8) | UInt16(recvBuf[7])
      let typeName: String
      switch type {
      case 129: typeName = "EchoReply"
      case 1: typeName = "DestinationUnreachable"
      case 3: typeName = "TimeExceeded"
      case 128: typeName = "EchoRequest(?)"
      default: typeName = "type=\(type)"
      }
      print(
        "  ICMPv6: type=\(type) (\(typeName)) code=\(code) id=0x\(String(id, radix: 16)) seq=\(seq)"
      )
      print(
        "  identifier match: \(id == identifier ? "YES (kernel preserved app id)" : "NO (kernel rewrote: app sent 0x\(String(identifier, radix: 16)), got 0x\(String(id, radix: 16)))")"
      )
    }

    // 8. Walk cmsg for hop limit. The CMSG_* macros aren't bridged to Swift, so
    //    we do the pointer arithmetic explicitly: each cmsghdr is followed by its
    //    data starting at an offset of sizeof(cmsghdr) rounded up to a 4-byte
    //    boundary (per __DARWIN_ALIGN32). The next cmsg starts cmsg_len bytes
    //    after the current one, also aligned. See <sys/socket.h>.
    var maybeHop: Int32?
    if msg.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size),
      let controlBase = msg.msg_control
    {
      let alignedHeader = (MemoryLayout<cmsghdr>.size + 3) & ~3
      let end = controlBase.advanced(by: Int(msg.msg_controllen))
      var cursor = controlBase
      while cursor.advanced(by: MemoryLayout<cmsghdr>.size) <= end {
        let hdr = cursor.assumingMemoryBound(to: cmsghdr.self).pointee
        if hdr.cmsg_level == IPPROTO_IPV6
          && (hdr.cmsg_type == IPV6_HOPLIMIT_CMSG_2292
            || hdr.cmsg_type == IPV6_HOPLIMIT_CMSG_3542)
          && Int(hdr.cmsg_len) >= alignedHeader + MemoryLayout<Int32>.size
        {
          let dataPtr = cursor.advanced(by: alignedHeader).assumingMemoryBound(to: Int32.self)
          maybeHop = dataPtr.pointee
          break
        }
        let advance = (Int(hdr.cmsg_len) + 3) & ~3
        guard advance > 0 else { break }
        cursor = cursor.advanced(by: advance)
      }
    }
    if let hop = maybeHop {
      print("  hop limit (from cmsg IPV6_HOPLIMIT): \(hop)")
    } else {
      print("  hop limit: <not present in cmsg — IPV6_RECVHOPLIMIT may have failed>")
    }

    // 9. Source address.
    var sbuf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    _ = withUnsafePointer(to: &fromAddr.sin6_addr) { ap in
      inet_ntop(AF_INET6, ap, &sbuf, socklen_t(INET6_ADDRSTRLEN))
    }
    let src = sbuf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    print("  source: \(src)")
  }
}
