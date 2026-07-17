import Foundation

#if canImport(Darwin)
  import Darwin
#endif

enum ICMPv4Type: UInt8 {
  case echoReply = 0
  case destinationUnreachable = 3
  case sourceQuench = 4  // deprecated
  case redirect = 5
  case echoRequest = 8
  case timeExceeded = 11
  case parameterProblem = 12
}

struct ICMPv4Header {
  var type: UInt8
  var code: UInt8
  var checksum: UInt16
  var identifier: UInt16
  var sequence: UInt16

  init(type: ICMPv4Type, code: UInt8 = 0, identifier: UInt16, sequence: UInt16) {
    self.type = type.rawValue
    self.code = code
    self.checksum = 0
    self.identifier = identifier.bigEndian
    self.sequence = sequence.bigEndian
  }
}

extension ICMPv4Header {
  static var size: Int { MemoryLayout<ICMPv4Header>.size }
}

// Internet checksum (RFC 1071)
@inline(__always)
func inetChecksum(data: UnsafeRawBufferPointer) -> UInt16 {
  var sum: UInt32 = 0
  var idx = 0
  let count = data.count
  let base = data.bindMemory(to: UInt8.self).baseAddress!

  while idx + 1 < count {
    let word = (UInt16(base[idx]) << 8) | UInt16(base[idx + 1])
    sum &+= UInt32(word)
    idx += 2
  }
  if idx < count {
    let word = UInt16(base[idx]) << 8
    sum &+= UInt32(word)
  }
  while (sum >> 16) != 0 {
    sum = (sum & 0xFFFF) &+ (sum >> 16)
  }
  return ~UInt16(sum & 0xFFFF)
}

@inline(__always)
func makeICMPEchoRequest(identifier: UInt16, sequence: UInt16, payloadSize: Int) -> [UInt8] {
  precondition(payloadSize >= 0)
  var header = ICMPv4Header(type: .echoRequest, identifier: identifier, sequence: sequence)
  var packet = [UInt8](repeating: 0, count: ICMPv4Header.size + payloadSize)

  withUnsafeMutableBytes(of: &header) { hdr in
    packet.withUnsafeMutableBytes { pkt in
      pkt.copyBytes(from: hdr)
    }
  }

  // Fill payload with a simple pattern and timestamp prefix
  let payloadIndex = ICMPv4Header.size
  if payloadSize > 0 {
    var pattern: UInt8 = 0x61
    for i in 0..<payloadSize {  // a,b,c,...
      packet[payloadIndex + i] = pattern
      pattern = pattern == 0x7A ? 0x61 : pattern + 1
    }
  }

  // compute checksum over entire packet
  packet.withUnsafeMutableBytes { mptr in
    // checksum field must be zeroed first
    mptr[2] = 0
    mptr[3] = 0
    let cksum = inetChecksum(data: UnsafeRawBufferPointer(mptr))
    mptr[2] = UInt8(cksum >> 8)
    mptr[3] = UInt8(cksum & 0xFF)
  }
  return packet
}

struct ParsedICMP {
  enum Kind {
    case echoReply(id: UInt16, seq: UInt16)
    case timeExceeded(originalID: UInt16?, originalSeq: UInt16?)
    case destinationUnreachable(originalID: UInt16?, originalSeq: UInt16?)
    case other(type: UInt8, code: UInt8)
  }
  let kind: Kind
  let sourceAddress: String
}

// Parses ICMP message from a datagram buffer. On macOS ICMP SOCK_DGRAM usually omits
// the outer IP header, but we detect it either way.
func parseICMPv4Message(buffer: UnsafeRawBufferPointer, from saStorage: sockaddr_storage)
  -> ParsedICMP?
{
  let addrStr: String = {
    var storage = saStorage
    if Int32(storage.ss_family) == AF_INET {
      return withUnsafePointer(to: &storage) { ptr -> String in
        ptr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sinPtr in
          var sin = sinPtr.pointee
          var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
          _ = inet_ntop(AF_INET, &sin.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
          return buf.withUnsafeBufferPointer { ptr in
            String(cString: ptr.baseAddress!)
          }
        }
      }
    }
    return "unsupported"
  }()

  if buffer.count == 0 { return nil }
  let bytes = buffer.bindMemory(to: UInt8.self)
  let first = bytes[0]
  var icmpOffset = 0
  // Detect IPv4 header
  if (first >> 4) == 4 {
    let ihl = Int(first & 0x0F) * 4
    guard ihl >= 20, ihl <= buffer.count, bytes[9] == UInt8(IPPROTO_ICMP) else {
      return nil
    }
    icmpOffset = ihl
  }
  if buffer.count - icmpOffset < 8 { return nil }
  let type = bytes[icmpOffset]
  let code = bytes[icmpOffset + 1]

  func read16(_ off: Int) -> UInt16 {
    let hi = UInt16(bytes[off])
    let lo = UInt16(bytes[off + 1])
    return (hi << 8) | lo
  }

  switch type {
  case ICMPv4Type.echoReply.rawValue:
    if code == 0, buffer.count - icmpOffset >= 8 {
      let id = read16(icmpOffset + 4)
      let seq = read16(icmpOffset + 6)
      return ParsedICMP(kind: .echoReply(id: id, seq: seq), sourceAddress: addrStr)
    }
  case ICMPv4Type.timeExceeded.rawValue, ICMPv4Type.destinationUnreachable.rawValue:
    // embedded IP header + 8 bytes should follow; try to dig out original ICMP id/seq
    let embedStart = icmpOffset + 8
    guard buffer.count - embedStart >= 28 else {  // 20 (IP) + 8 (ICMP)
      return ParsedICMP(
        kind: (type == ICMPv4Type.timeExceeded.rawValue)
          ? .timeExceeded(originalID: nil, originalSeq: nil)
          : .destinationUnreachable(originalID: nil, originalSeq: nil),
        sourceAddress: addrStr)
    }
    let ipFirst = bytes[embedStart]
    if (ipFirst >> 4) == 4 {
      let ihl = Int(ipFirst & 0x0F) * 4
      guard ihl >= 20, bytes[embedStart + 9] == UInt8(IPPROTO_ICMP) else {
        return ParsedICMP(
          kind: (type == ICMPv4Type.timeExceeded.rawValue)
            ? .timeExceeded(originalID: nil, originalSeq: nil)
            : .destinationUnreachable(originalID: nil, originalSeq: nil),
          sourceAddress: addrStr)
      }
      let innerICMP = embedStart + ihl
      if buffer.count - innerICMP >= 8 {
        let innerType = bytes[innerICMP]
        if innerType == ICMPv4Type.echoRequest.rawValue, bytes[innerICMP + 1] == 0 {
          let id = read16(innerICMP + 4)
          let seq = read16(innerICMP + 6)
          if type == ICMPv4Type.timeExceeded.rawValue {
            return ParsedICMP(
              kind: .timeExceeded(originalID: id, originalSeq: seq), sourceAddress: addrStr)
          } else {
            return ParsedICMP(
              kind: .destinationUnreachable(originalID: id, originalSeq: seq),
              sourceAddress: addrStr)
          }
        }
      }
    }
    return ParsedICMP(
      kind: (type == ICMPv4Type.timeExceeded.rawValue)
        ? .timeExceeded(originalID: nil, originalSeq: nil)
        : .destinationUnreachable(originalID: nil, originalSeq: nil),
      sourceAddress: addrStr)
  default:
    return ParsedICMP(kind: .other(type: type, code: code), sourceAddress: addrStr)
  }
  return nil
}

// MARK: - ICMPv6 (RFC 4443)

enum ICMPv6Type: UInt8 {
  case destinationUnreachable = 1
  case packetTooBig = 2
  case timeExceeded = 3
  case parameterProblem = 4
  case echoRequest = 128
  case echoReply = 129
}

/// Builds an ICMPv6 Echo Request. The Darwin kernel computes the ICMPv6 checksum on
/// SOCK_DGRAM IPPROTO_ICMPV6 sockets because it requires the IPv6 pseudo-header
/// (src/dst), which userspace does not know. We leave the checksum field zero.
///
/// Empirically verified with `icmpv6probe` (see Tests/TestSupport/icmpv6probe/):
/// kernel rewrites checksum, preserves identifier and sequence end-to-end.
@inline(__always)
func makeICMPv6EchoRequest(identifier: UInt16, sequence: UInt16, payloadSize: Int) -> [UInt8] {
  precondition(payloadSize >= 0)
  var packet = [UInt8](repeating: 0, count: 8 + payloadSize)
  packet[0] = ICMPv6Type.echoRequest.rawValue
  packet[1] = 0  // code
  // bytes 2-3 = checksum, left zero (kernel fills)
  packet[4] = UInt8(identifier >> 8)
  packet[5] = UInt8(identifier & 0xFF)
  packet[6] = UInt8(sequence >> 8)
  packet[7] = UInt8(sequence & 0xFF)
  if payloadSize > 0 {
    var pattern: UInt8 = 0x61  // 'a'
    for i in 0..<payloadSize {
      packet[8 + i] = pattern
      pattern = pattern == 0x7A ? 0x61 : pattern + 1
    }
  }
  return packet
}

/// Parses an ICMPv6 datagram delivered via SOCK_DGRAM IPPROTO_ICMPV6.
///
/// Darwin's behavior (confirmed empirically with the icmpv6probe spike):
/// - Outer IPv6 header is stripped by the kernel — buffer starts at ICMPv6 type byte.
/// - Identifier is preserved (no kernel rewrite, unlike some Linux configurations).
/// - Hop limit arrives out-of-band via `cmsg IPPROTO_IPV6/IPV6_HOPLIMIT` (caller
///   reads from recvmsg ancillary data and passes it here as `hopLimit:`).
/// - Source address is the IPv6 address in `saStorage` (sockaddr_in6), formatted via
///   `ipv6String` which preserves `%<ifname>` zone suffix for link-local addresses
///   (the canonical-form contract NWX depends on for dictionary keys).
func parseICMPv6Message(
  buffer: UnsafeRawBufferPointer, hopLimit: Int?, from saStorage: sockaddr_storage
) -> ParsedICMP? {
  let addrStr: String = {
    var storage = saStorage
    if Int32(storage.ss_family) == AF_INET6 {
      return withUnsafePointer(to: &storage) { ptr -> String in
        ptr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sinPtr in
          let sin = sinPtr.pointee
          return ipv6String(sin.sin6_addr, scopeID: sin.sin6_scope_id)
        }
      }
    }
    return "unsupported"
  }()
  _ = hopLimit  // currently unused at parse time; passed through by the caller

  guard buffer.count >= 8 else { return nil }
  let bytes = buffer.bindMemory(to: UInt8.self)
  let type = bytes[0]
  let code = bytes[1]

  @inline(__always) func read16(_ off: Int) -> UInt16 {
    (UInt16(bytes[off]) << 8) | UInt16(bytes[off + 1])
  }

  switch type {
  case ICMPv6Type.echoReply.rawValue:
    guard code == 0 else { return nil }
    let id = read16(4)
    let seq = read16(6)
    return ParsedICMP(kind: .echoReply(id: id, seq: seq), sourceAddress: addrStr)

  case ICMPv6Type.timeExceeded.rawValue, ICMPv6Type.destinationUnreachable.rawValue:
    // After the 8-byte ICMPv6 error header, the original packet is embedded.
    // For us, the original is an IPv6 header (fixed 40 bytes — no IHL like v4) +
    // ICMPv6 Echo Request (8 bytes). Total minimum embedded = 48.
    let embedStart = 8
    guard buffer.count - embedStart >= 48 else {
      return ParsedICMP(
        kind: (type == ICMPv6Type.timeExceeded.rawValue)
          ? .timeExceeded(originalID: nil, originalSeq: nil)
          : .destinationUnreachable(originalID: nil, originalSeq: nil),
        sourceAddress: addrStr)
    }
    let ipFirst = bytes[embedStart]
    guard (ipFirst >> 4) == 6 else {
      // Not a v6 header where we expected one; emit unknown-id case.
      return ParsedICMP(
        kind: (type == ICMPv6Type.timeExceeded.rawValue)
          ? .timeExceeded(originalID: nil, originalSeq: nil)
          : .destinationUnreachable(originalID: nil, originalSeq: nil),
        sourceAddress: addrStr)
    }
    guard bytes[embedStart + 6] == UInt8(IPPROTO_ICMPV6) else {
      return ParsedICMP(
        kind: (type == ICMPv6Type.timeExceeded.rawValue)
          ? .timeExceeded(originalID: nil, originalSeq: nil)
          : .destinationUnreachable(originalID: nil, originalSeq: nil),
        sourceAddress: addrStr)
    }
    // Next Header at embedStart+6 should be IPPROTO_ICMPV6 (58) for the embedded
    // ICMPv6 echo request we sent. If it's an extension header chain, we don't
    // currently walk it — stick to the common case (no extension headers).
    let innerICMP = embedStart + 40  // fixed v6 header length
    guard buffer.count - innerICMP >= 8 else {
      return ParsedICMP(
        kind: (type == ICMPv6Type.timeExceeded.rawValue)
          ? .timeExceeded(originalID: nil, originalSeq: nil)
          : .destinationUnreachable(originalID: nil, originalSeq: nil),
        sourceAddress: addrStr)
    }
    let innerType = bytes[innerICMP]
    if innerType == ICMPv6Type.echoRequest.rawValue, bytes[innerICMP + 1] == 0 {
      let id = read16(innerICMP + 4)
      let seq = read16(innerICMP + 6)
      if type == ICMPv6Type.timeExceeded.rawValue {
        return ParsedICMP(
          kind: .timeExceeded(originalID: id, originalSeq: seq), sourceAddress: addrStr)
      } else {
        return ParsedICMP(
          kind: .destinationUnreachable(originalID: id, originalSeq: seq), sourceAddress: addrStr)
      }
    }
    return ParsedICMP(
      kind: (type == ICMPv6Type.timeExceeded.rawValue)
        ? .timeExceeded(originalID: nil, originalSeq: nil)
        : .destinationUnreachable(originalID: nil, originalSeq: nil),
      sourceAddress: addrStr)

  default:
    return ParsedICMP(kind: .other(type: type, code: code), sourceAddress: addrStr)
  }
}

// MARK: - Test/Fuzz SPI

// SPI: expose a tiny wrapper for fuzzing/external validation without making internals public.
// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Fuzz)
public func __fuzz_parseICMP(buffer: UnsafeRawBufferPointer, from saStorage: sockaddr_storage)
  -> Bool
{
  return parseICMPv4Message(buffer: buffer, from: saStorage) != nil
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Fuzz)
public func __fuzz_parseICMPv6(buffer: UnsafeRawBufferPointer, from saStorage: sockaddr_storage)
  -> Bool
{
  return parseICMPv6Message(buffer: buffer, hopLimit: nil, from: saStorage) != nil
}

@_spi(Test)
public struct TestParsedICMP: Sendable {
  public enum Kind: Sendable {
    case echoReply(id: UInt16, seq: UInt16)
    case timeExceeded(id: UInt16?, seq: UInt16?)
    case destinationUnreachable(id: UInt16?, seq: UInt16?)
    case other(type: UInt8, code: UInt8)
  }
  public let kind: Kind
  public let source: String
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __parseICMPMessage(buffer: UnsafeRawBufferPointer, from saStorage: sockaddr_storage)
  -> TestParsedICMP?
{
  guard let p = parseICMPv4Message(buffer: buffer, from: saStorage) else { return nil }
  return _toTestParsedICMP(p)
}

// swift-format-ignore: AlwaysUseLowerCamelCase
@_spi(Test)
public func __parseICMPv6Message(
  buffer: UnsafeRawBufferPointer, hopLimit: Int?, from saStorage: sockaddr_storage
) -> TestParsedICMP? {
  guard let p = parseICMPv6Message(buffer: buffer, hopLimit: hopLimit, from: saStorage) else {
    return nil
  }
  return _toTestParsedICMP(p)
}

@inline(__always)
private func _toTestParsedICMP(_ p: ParsedICMP) -> TestParsedICMP {
  switch p.kind {
  case .echoReply(let id, let seq):
    return TestParsedICMP(kind: .echoReply(id: id, seq: seq), source: p.sourceAddress)
  case .timeExceeded(let oid, let oseq):
    return TestParsedICMP(kind: .timeExceeded(id: oid, seq: oseq), source: p.sourceAddress)
  case .destinationUnreachable(let oid, let oseq):
    return TestParsedICMP(
      kind: .destinationUnreachable(id: oid, seq: oseq), source: p.sourceAddress)
  case .other(let t, let c):
    return TestParsedICMP(kind: .other(type: t, code: c), source: p.sourceAddress)
  }
}
