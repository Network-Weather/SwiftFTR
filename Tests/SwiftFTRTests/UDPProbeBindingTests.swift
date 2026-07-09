import Dispatch
import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin

  @Suite("UDP probe routing and lifecycle")
  struct UDPProbeBindingTests {
    @Test("Routes empty datagrams through the requested interface and source IP")
    func emptyDatagramPreservesPayloadAndRoute() async throws {
      let server = try LoopbackUDPServer(reply: Data())
      var datagrams = server.datagrams.makeAsyncIterator()

      let probe = Task {
        try await udpProbe(
          host: "127.0.0.1",
          port: server.port,
          timeout: 2,
          payload: Data(),
          interface: "lo0",
          sourceIP: "127.0.0.1"
        )
      }

      let datagram = try #require(await datagrams.next())
      let result = try await probe.value

      #expect(datagram.isEmpty)
      #expect(result.isReachable)
      #expect(result.responseType == "udp_reply")
      #expect(result.error == nil)
    }

    @Test("Reports an unknown interface in the probe result")
    func invalidInterfaceReturnsClearError() async throws {
      let result = try await udpProbe(
        config: UDPProbeConfig(
          host: "127.0.0.1",
          port: 9,
          timeout: 1,
          interface: "swiftftr-invalid-interface"
        )
      )

      #expect(!result.isReachable)
      #expect(result.responseType == nil)
      #expect(result.error == "Interface 'swiftftr-invalid-interface' not found")
    }

    @Test("Reports a source address family mismatch in the probe result")
    func sourceAddressFamilyMismatchReturnsClearError() async throws {
      let result = try await udpProbe(
        config: UDPProbeConfig(
          host: "127.0.0.1",
          port: 9,
          timeout: 1,
          sourceIP: "::1",
          preferredFamily: .v4
        )
      )

      #expect(!result.isReachable)
      #expect(result.responseType == nil)
      #expect(result.error == "Invalid source IPv4 address '::1'")
    }

    @Test("Cancellation closes a waiting probe without waiting for its timeout")
    func cancellationFinishesPromptly() async throws {
      let server = try LoopbackUDPServer(reply: nil)
      var datagrams = server.datagrams.makeAsyncIterator()
      let probe = Task {
        try await udpProbe(
          config: UDPProbeConfig(
            host: "127.0.0.1",
            port: server.port,
            timeout: 30,
            interface: "lo0",
            sourceIP: "127.0.0.1"
          )
        )
      }

      _ = try #require(await datagrams.next())
      let start = ContinuousClock.now
      probe.cancel()

      await #expect(throws: CancellationError.self) {
        try await probe.value
      }
      #expect(ContinuousClock.now - start < .seconds(1))
    }
  }

  private final class LoopbackUDPServer: @unchecked Sendable {
    let datagrams: AsyncStream<Data>
    let port: Int

    private let source: DispatchSourceRead

    init(reply: Data?) throws {
      let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
      guard socketFD >= 0 else {
        throw LoopbackUDPServerError.posix(errno)
      }

      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = 0
      guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
        close(socketFD)
        throw LoopbackUDPServerError.posix(EINVAL)
      }

      let bindResult = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
          Darwin.bind(
            socketFD,
            socketAddress,
            socklen_t(MemoryLayout<sockaddr_in>.size)
          )
        }
      }
      guard bindResult == 0 else {
        let error = errno
        close(socketFD)
        throw LoopbackUDPServerError.posix(error)
      }

      var boundAddress = sockaddr_in()
      var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
      let addressResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
          getsockname(socketFD, socketAddress, &boundAddressLength)
        }
      }
      guard addressResult == 0 else {
        let error = errno
        close(socketFD)
        throw LoopbackUDPServerError.posix(error)
      }

      let (datagrams, continuation) = AsyncStream<Data>.makeStream()
      let source = DispatchSource.makeReadSource(
        fileDescriptor: socketFD,
        queue: DispatchQueue(label: "com.swiftftr.tests.udp-loopback")
      )
      source.setEventHandler {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        var peer = sockaddr_storage()
        var peerLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let byteCount = buffer.withUnsafeMutableBytes { bytes in
          withUnsafeMutablePointer(to: &peer) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
              recvfrom(
                socketFD,
                bytes.baseAddress,
                bytes.count,
                0,
                socketAddress,
                &peerLength
              )
            }
          }
        }
        guard byteCount >= 0 else { return }

        continuation.yield(Data(buffer.prefix(Int(byteCount))))

        if let reply {
          reply.withUnsafeBytes { bytes in
            withUnsafePointer(to: &peer) { pointer in
              pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                _ = sendto(
                  socketFD,
                  bytes.baseAddress,
                  bytes.count,
                  0,
                  socketAddress,
                  peerLength
                )
              }
            }
          }
        }
      }
      source.setCancelHandler {
        close(socketFD)
        continuation.finish()
      }
      source.activate()

      self.datagrams = datagrams
      self.port = Int(UInt16(bigEndian: boundAddress.sin_port))
      self.source = source
    }

    deinit {
      source.cancel()
    }
  }

  private enum LoopbackUDPServerError: Error {
    case posix(Int32)
  }
#endif
