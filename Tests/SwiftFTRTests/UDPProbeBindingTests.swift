import Dispatch
import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin

  /// How long a probe may take to send its first datagram, or to return once cancelled. Probes
  /// that must be cancelled have timeouts that outlast it.
  private let cancellationWatchdog: TimeInterval = 20

  @Suite("UDP probe routing and lifecycle")
  struct UDPProbeBindingTests {
    @Test(
      "Routes empty datagrams through the requested interface and source IP",
      .timeLimit(.minutes(1)),
      arguments: LoopbackFamily.allCases
    )
    func emptyDatagramPreservesPayloadAndRoute(family: LoopbackFamily) async throws {
      let route = try await discoverLoopbackRoute(for: family)
      // Takes only an empty datagram, so a reply proves the probe sent its payload as empty.
      let server = try LoopbackUDPServer(route: route, reply: Data(), accepts: .payload([]))
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

    @Test(
      "The loopback server yields and answers only the probe's datagram, after strays queued ahead",
      .timeLimit(.minutes(1)))
    func serverIgnoresStrays() async throws {
      let route = try await discoverLoopbackRoute(for: .ipv4)
      try #require(route.address == "127.0.0.1", "route address \(route.address)")
      let payload = Data("stray-proof".utf8)
      let server = try LoopbackUDPServer(
        route: route, reply: Data("ok".utf8), accepts: .payload(Array(payload)),
        startReading: false)
      #expect(Strays.send(to: UInt16(server.port)))
      try #require(
        await eventually(within: 10) { server.queued >= 2 }, "queued: \(server.queued)")
      server.start()
      var datagrams = server.datagrams.makeAsyncIterator()

      let result = try await udpProbe(
        config: UDPProbeConfig(
          host: route.address, port: server.port, timeout: 10, payload: payload,
          preferredFamily: .v4))
      // A probe that got no reply leaves nothing to read, so the wait below would last until the
      // time limit.
      try #require(result.responseType == "udp_reply", "\(result.error ?? "no error")")
      #expect(await datagrams.next() == payload, "the first datagram yielded was not the probe's")
      #expect(server.ignored.value >= 2, "ignored: \(server.ignored.value)")
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
      let payload = Data("cancel-probe".utf8)
      let server = try LoopbackUDPServer(
        route: route, reply: nil, accepts: .payload(Array(payload)))
      let probe = Task {
        try await udpProbe(
          config: UDPProbeConfig(
            host: route.address,
            port: server.port,
            timeout: 3 * cancellationWatchdog,
            payload: payload,
            interface: route.interfaceName,
            sourceIP: route.address,
            preferredFamily: .v4
          )
        )
      }

      // The server never replies and the timeout outlasts the watchdog, so a probe that returns
      // was ended by its cancellation. The watchdog covers the wait for the first datagram too,
      // since that wait also ends only when the probe does.
      let datagrams = server.datagrams
      let (outcome, _) = try await measure(within: cancellationWatchdog) {
        _ = try await cancelProbeAfterFirstDatagram(from: datagrams, probe: probe)
        return await probe.result
      }
      #expect(throws: CancellationError.self) { try outcome.get() }
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
          try await Task.sleep(for: .seconds(cancellationWatchdog))
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

  /// A loopback UDP server that yields, and answers with `reply`, each datagram its filter
  /// accepts; every other one is a stray (``DatagramFilter``), counted in ``ignored``.
  private final class LoopbackUDPServer: @unchecked Sendable {
    let datagrams: AsyncStream<Data>
    let port: Int
    let ignored: FaultCounter

    private let source: DispatchSourceRead
    private let socketFD: Int32

    /// - Parameter startReading: when false, nothing is read until ``start()``, so a test can
    ///   queue datagrams ahead of the probe's.
    init(
      route: LoopbackRoute, reply: Data?, accepts filter: DatagramFilter, startReading: Bool = true
    )
      throws
    {
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

      let ignored = FaultCounter()
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
        let datagram = Array(buffer.prefix(Int(byteCount)))
        guard filter.accepts(datagram) else {
          ignored.increment()
          return
        }

        continuation.yield(Data(datagram))

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
      if startReading { source.activate() }

      self.datagrams = datagrams
      self.port = boundPort
      self.source = source
      self.socketFD = socketFD
      self.ignored = ignored
    }

    /// Starts reading, for a server made with `startReading: false`.
    func start() { source.activate() }

    /// Datagrams waiting on the socket (`SO_NUMRCVPKT`); valid until the server is released.
    var queued: Int32 { queuedDatagrams(socketFD) }

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
      // An inactive source must be activated before it is released; activating an active one
      // does nothing.
      source.activate()
      source.cancel()
    }
  }

  private enum LoopbackUDPServerError: Error {
    case posix(Int32)
  }
#endif
