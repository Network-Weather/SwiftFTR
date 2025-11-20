import Foundation
import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

@main
struct ResourceBenchmark {
  static func main() async throws {
    print("🔥 Debugging ICMP IDs...")
    // Create a socket manually to test ID behavior
    let sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard sockfd >= 0 else { fatalError("Socket creation failed") }

    // Set non-blocking
    let flags = fcntl(sockfd, F_GETFL, 0)
    _ = fcntl(sockfd, F_SETFL, flags | O_NONBLOCK)

    // Bind to something? Not strictly needed for sending, but maybe?
    // SwiftFTR doesn't bind by default unless interface specified.

    // Send a ping with ID = 12345, Seq = 1
    let id: UInt16 = 12345
    let seq: UInt16 = 1
    var header = ICMPHeader(
      type: 8, code: 0, checksum: 0, identifier: id.bigEndian, sequence: seq.bigEndian)
    var packet = [UInt8](repeating: 0, count: 8 + 56)  // 64 bytes
    withUnsafeMutableBytes(of: &header) { hdr in
      packet.withUnsafeMutableBytes { $0.copyBytes(from: hdr) }
    }
    // Checksum
    packet.withUnsafeMutableBytes { mptr in
      mptr[2] = 0
      mptr[3] = 0
      let cksum = calculateChecksum(data: UnsafeRawBufferPointer(mptr))
      mptr[2] = UInt8(cksum >> 8)
      mptr[3] = UInt8(cksum & 0xFF)
    }

    var dest = sockaddr_in()
    dest.sin_family = sa_family_t(AF_INET)
    inet_pton(AF_INET, "1.1.1.1", &dest.sin_addr)

    let sent = withUnsafePointer(to: &dest) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
        sendto(sockfd, packet, packet.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    print("Sent bytes: \(sent)")

    // Wait for reply
    var buffer = [UInt8](repeating: 0, count: 1500)
    let start = Date()
    while Date().timeIntervalSince(start) < 2.0 {
      var from = sockaddr_in()
      var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      let received = withUnsafeMutablePointer(to: &from) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
          recvfrom(sockfd, &buffer, buffer.count, 0, sa, &fromLen)
        }
      }

      if received > 0 {
        print("Received \(received) bytes")
        // Parse ID from offset
        // IP header? Check first byte
        let first = buffer[0]
        var offset = 0
        if (first >> 4) == 4 {
          offset = Int(first & 0x0F) * 4
          print("IP Header detected, size: \(offset)")
        }

        if received - offset >= 8 {
          let type = buffer[offset]
          let code = buffer[offset + 1]
          let recvId = (UInt16(buffer[offset + 4]) << 8) | UInt16(buffer[offset + 5])
          let recvSeq = (UInt16(buffer[offset + 6]) << 8) | UInt16(buffer[offset + 7])
          print("Type: \(type), Code: \(code), ID: \(recvId), Seq: \(recvSeq)")

          if recvId == id {
            print("✅ ID MATCHES!")
          } else {
            print("❌ ID MISMATCH! Sent: \(id), Received: \(recvId)")
          }
        }
        break
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    close(sockfd)
  }

  struct ICMPHeader {
    var type: UInt8
    var code: UInt8
    var checksum: UInt16
    var identifier: UInt16
    var sequence: UInt16
  }

  static func calculateChecksum(data: UnsafeRawBufferPointer) -> UInt16 {
    var sum: UInt32 = 0
    var idx = 0
    while idx + 1 < data.count {
      sum &+= UInt32((UInt16(data[idx]) << 8) | UInt16(data[idx + 1]))
      idx += 2
    }
    if idx < data.count { sum &+= UInt32(UInt16(data[idx]) << 8) }
    while (sum >> 16) != 0 { sum = (sum & 0xFFFF) &+ (sum >> 16) }
    return ~UInt16(sum & 0xFFFF)
  }
}
