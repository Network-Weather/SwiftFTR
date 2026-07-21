import Dispatch
import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin

  @Suite("UDP probe routing and lifecycle")
  struct UDPProbeBindingTests {
    @Test(
      "Routes empty datagrams through the requested interface and source IP",
      .timeLimit(.minutes(1)),
      arguments: LoopbackFamily.allCases
    )
    func emptyDatagramPreservesPayloadAndRoute(family: LoopbackFamily) async throws {
      let route = try await discoverLoopbackRoute(for: family)
      let server = try LoopbackUDPServer(route: route, reply: Data())
      var datagrams = server.datagrams.makeAsyncIterator()

      let result = try await udpProbe(
        config: UDPProbeConfig(
          host: route.address,
          port: server.port,
          timeout: 2,
          payload: Data(),
          interface: route.interfaceName,
          sourceIP: route.address,
          preferredFamily: family.preferredFamily
        )
      )

      try #require(
        result.responseType == "udp_reply",
        "Probe ended before the loopback server returned a UDP reply: \(result.error ?? "no error")"
      )
      let datagram = try #require(await datagrams.next())

      #expect(datagram.isEmpty)
      #expect(result.isReachable)
      #expect(result.resolvedIP == route.address)
      #expect(result.error == nil)
    }

    @Test("Reports an unknown interface in the probe result")
    func invalidInterfaceReturnsClearError() async throws {
      let invalidInterface = String(repeating: "x", count: Int(IFNAMSIZ) + 1)
      let result = try await udpProbe(
        config: UDPProbeConfig(
          host: "127.0.0.1",
          port: 9,
          timeout: 1,
          interface: invalidInterface
        )
      )

      #expect(!result.isReachable)
      #expect(result.responseType == nil)
      #expect(result.error == "Interface '\(invalidInterface)' not found")
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

    @Test(
      "Cancellation closes a waiting probe without waiting for its timeout",
      .timeLimit(.minutes(1))
    )
    func cancellationFinishesPromptly() async throws {
      let route = try await discoverLoopbackRoute(for: .ipv4)
      let server = try LoopbackUDPServer(route: route, reply: nil)
      let probe = Task {
        try await udpProbe(
          config: UDPProbeConfig(
            host: route.address,
            port: server.port,
            timeout: 30,
            interface: route.interfaceName,
            sourceIP: route.address,
            preferredFamily: .v4
          )
        )
      }

      let (_, start) = try await cancelProbeAfterFirstDatagram(
        from: server.datagrams,
        probe: probe
      )

      await #expect(throws: CancellationError.self) {
        try await probe.value
      }
      #expect(ContinuousClock.now - start < .seconds(1))
    }
  }

  private enum ProbeStartEvent: Sendable {
    case datagram(Data?)
    case probeCompleted
    case timedOut
    case cancelled
  }

  private enum ProbeStartError: Error {
    case datagramStreamEnded
    case probeCompletedBeforeDatagram
    case timedOut
  }

  private func cancelProbeAfterFirstDatagram(
    from datagrams: AsyncStream<Data>,
    probe: Task<UDPProbeResult, Error>
  ) async throws -> (Data, ContinuousClock.Instant) {
    try await withThrowingTaskGroup(of: ProbeStartEvent.self) { group in
      defer {
        probe.cancel()
        group.cancelAll()
      }

      group.addTask {
        var iterator = datagrams.makeAsyncIterator()
        return .datagram(await iterator.next())
      }
      group.addTask {
        _ = try? await probe.value
        return .probeCompleted
      }
      group.addTask {
        do {
          try await Task.sleep(for: .seconds(1))
          return .timedOut
        } catch {
          return .cancelled
        }
      }

      guard let event = try await group.next() else {
        throw ProbeStartError.datagramStreamEnded
      }
      switch event {
      case .datagram(let datagram):
        guard let datagram else {
          throw ProbeStartError.datagramStreamEnded
        }
        return (datagram, ContinuousClock.now)
      case .probeCompleted:
        throw ProbeStartError.probeCompletedBeforeDatagram
      case .timedOut, .cancelled:
        throw ProbeStartError.timedOut
      }
    }
  }

  enum LoopbackFamily: CaseIterable, Sendable, CustomTestStringConvertible {
    case ipv4
    case ipv6

    var preferredFamily: PreferredFamily {
      switch self {
      case .ipv4: .v4
      case .ipv6: .v6
      }
    }

    var socketFamily: Int32 {
      switch self {
      case .ipv4: AF_INET
      case .ipv6: AF_INET6
      }
    }

    func addresses(on interface: NetworkInterface) -> [String] {
      switch self {
      case .ipv4: interface.ipv4Addresses
      case .ipv6: interface.ipv6Addresses
      }
    }

    var testDescription: String {
      switch self {
      case .ipv4: "IPv4"
      case .ipv6: "IPv6"
      }
    }
  }

  private struct LoopbackRoute: Sendable {
    let family: LoopbackFamily
    let interfaceName: String
    let address: String
  }

  private func discoverLoopbackRoute(for family: LoopbackFamily) async throws -> LoopbackRoute {
    let snapshot = await NetworkInterfaceDiscovery().discover()
    let route = snapshot.interfaces.lazy.compactMap { interface -> LoopbackRoute? in
      guard
        interface.isUp,
        let address = family.addresses(on: interface).first(where: {
          ipAddressScope(of: $0) == .loopback
        })
      else {
        return nil
      }

      return LoopbackRoute(
        family: family,
        interfaceName: interface.name,
        address: address
      )
    }.first

    return try #require(route, "No active \(family.testDescription) loopback route was discovered")
  }

  private final class LoopbackUDPServer: @unchecked Sendable {
    let datagrams: AsyncStream<Data>
    let port: Int

    private let source: DispatchSourceRead

    init(route: LoopbackRoute, reply: Data?) throws {
      let socketFD = socket(route.family.socketFamily, SOCK_DGRAM, IPPROTO_UDP)
      guard socketFD >= 0 else {
        throw LoopbackUDPServerError.posix(errno)
      }

      let boundPort: Int
      do {
        boundPort = try Self.bind(socketFD, to: route)
      } catch {
        close(socketFD)
        throw error
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
      self.port = boundPort
      self.source = source
    }

    private static func bind(_ socketFD: Int32, to route: LoopbackRoute) throws -> Int {
      switch route.family {
      case .ipv4:
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, route.address, &address.sin_addr) == 1 else {
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
          throw LoopbackUDPServerError.posix(errno)
        }

        var boundAddress = sockaddr_in()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let addressResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            getsockname(socketFD, socketAddress, &boundAddressLength)
          }
        }
        guard addressResult == 0 else {
          throw LoopbackUDPServerError.posix(errno)
        }
        return Int(UInt16(bigEndian: boundAddress.sin_port))

      case .ipv6:
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = 0
        guard inet_pton(AF_INET6, route.address, &address.sin6_addr) == 1 else {
          throw LoopbackUDPServerError.posix(EINVAL)
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            Darwin.bind(
              socketFD,
              socketAddress,
              socklen_t(MemoryLayout<sockaddr_in6>.size)
            )
          }
        }
        guard bindResult == 0 else {
          throw LoopbackUDPServerError.posix(errno)
        }

        var boundAddress = sockaddr_in6()
        var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let addressResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
            getsockname(socketFD, socketAddress, &boundAddressLength)
          }
        }
        guard addressResult == 0 else {
          throw LoopbackUDPServerError.posix(errno)
        }
        return Int(UInt16(bigEndian: boundAddress.sin6_port))
      }
    }

    deinit {
      source.cancel()
    }
  }

  private enum LoopbackUDPServerError: Error {
    case posix(Int32)
  }
#endif
