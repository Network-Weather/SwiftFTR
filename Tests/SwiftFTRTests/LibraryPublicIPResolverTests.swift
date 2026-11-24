import Foundation
import Testing

@testable import SwiftFTR

#if canImport(Darwin)
  import Darwin
#endif

/// The library's own public-IP resolver: STUN only, every socket bound before anything is sent,
/// and `getPublicIPs` and `discoverPublicIPWithHostname()` asking it.
///
/// STUN servers are loopback fixtures, named by address through `TestSeams.stunServers` or by a
/// name that `TestSeams.resolveSTUNServer` maps to a fixture without a lookup. Nothing here sends
/// a packet off the host. Every call runs under ``watchdog`` and every timeout that could end it on
/// the wrong path is set well past it.
// Serialized: `queuedSweepsHoldFewSockets` counts this process's lo0-bound UDP sockets.
@Suite("Library public-IP resolver", .serialized)
struct LibraryPublicIPResolverTests {
  static let watchdog: TimeInterval = 20
  static let longSTUNTimeout: TimeInterval = 60

  static func host(_ family: Int32) -> String { family == AF_INET6 ? "::1" : "127.0.0.1" }

  /// STUN servers by `names`, each on port 3478, for both families.
  static func named(_ names: [String]) -> TestSeams.STUNServers {
    { _ in names.map { ($0, 3478) } }
  }

  static func ipFamily(_ family: Int32) -> IPAddressFamily { family == AF_INET6 ? .v6 : .v4 }

  /// A STUN responder that maps every request to `ip`.
  static func answering(_ family: Int32, ip: [UInt8]) throws -> LoopbackUDPResponder {
    try LoopbackUDPResponder(family: family, accepts: .stunBindingRequest) { request in
      AsyncPublicIPDiscoveryTests.stunSuccess(for: request, ip: ip).map { ($0, 0) }
    }
  }

  static let mapped4: [UInt8] = [198, 51, 100, 9]
  static let mapped6: [UInt8] = [0x20, 0x01, 0x0D, 0xB8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x09]

  /// Name lookups the sweep made, each answered from `table` (a name to a loopback port).
  final class NameLookups: @unchecked Sendable {
    let calls = FaultCounter()
    private let table: [String: UInt16]

    init(_ table: [String: UInt16]) { self.table = table }

    var seam: TestSeams.ResolveSTUNServer {
      { host, _, family in
        self.calls.increment()
        return self.table[host].map { loopbackAddress(family: family, port: $0) }.map {
          (server: $0.0, serverLen: $0.1)
        }
      }
    }
  }

  /// Every STUN request the sweep sent, with the interface its socket was bound to at the send.
  /// The request goes out unchanged.
  final class STUNSends: @unchecked Sendable {
    private let lock = NSLock()
    private var indices: [UInt32] = []

    var boundInterfaces: [UInt32] { lock.withLock { indices } }

    func seam(family: Int32) -> TestSeams.SendDatagram {
      { fd, bytes in
        var index: UInt32 = 0
        var length = socklen_t(MemoryLayout<UInt32>.size)
        let level = family == AF_INET6 ? IPPROTO_IPV6 : IPPROTO_IP
        let option = family == AF_INET6 ? IPV6_BOUND_IF : IP_BOUND_IF
        if getsockopt(fd, level, option, &index, &length) != 0 { index = 0 }
        self.lock.withLock { self.indices.append(index) }
        return Darwin.send(fd, bytes.baseAddress, bytes.count, 0)
      }
    }
  }

  /// The requests a discovery substitute was handed.
  final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [PublicIPRequest] = []
    func append(_ request: PublicIPRequest) { lock.withLock { requests.append(request) } }
    var all: [PublicIPRequest] { lock.withLock { requests } }
  }

  static func ask(
    _ family: IPAddressFamily, interface: String?, sourceIP: String?
  ) async throws -> PublicIPObservation? {
    let request = PublicIPRequest(
      family: family, interface: interface, sourceIP: sourceIP,
      deadline: .now + .seconds(3 * watchdog))
    return try await measure(within: watchdog) {
      try await LibraryPublicIPResolver(stunTimeout: longSTUNTimeout, enableLogging: false)
        .publicIP(for: request)
    }.0
  }

  // MARK: Bound before anything is sent

  @Test(
    "On a bound request every STUN socket is bound to the interface before it sends",
    arguments: [AF_INET, AF_INET6])
  func everySocketBoundBeforeSend(family: Int32) async throws {
    // The first server refuses at once, so both sockets send; the second answers.
    let refusing = try RefusingUDPPort(family: family)
    let answer = try Self.answering(family, ip: family == AF_INET6 ? Self.mapped6 : Self.mapped4)
    defer { answer.stop() }
    let lookups = NameLookups(["stun-a.test": refusing.port, "stun-b.test": answer.port])
    let sends = STUNSends()
    let lo0 = if_nametoindex("lo0")
    try #require(lo0 != 0)

    let found = try await TestSeams.$stunServers.withValue(
      Self.named(["stun-a.test", "stun-b.test"])
    ) {
      try await TestSeams.$resolveSTUNServer.withValue(lookups.seam) {
        try await TestSeams.$sendSTUNRequest.withValue(sends.seam(family: family)) {
          try await Self.ask(Self.ipFamily(family), interface: "lo0", sourceIP: Self.host(family))
        }
      }
    }

    #expect(found?.address == (family == AF_INET6 ? "2001:db8::9" : "198.51.100.9"))
    #expect(found?.source == .stun)
    #expect(lookups.calls.value == 2)
    #expect(sends.boundInterfaces == [lo0, lo0], "sent from a socket not bound to lo0")
  }

  /// A binding the host cannot make, and the error the sweep reports for it.
  struct FailedBind: CustomTestStringConvertible, Sendable {
    let why: String
    var interface: String? = nil
    var sourceIP: String? = nil
    var testDescription: String { why }
  }

  static let failedBinds: [FailedBind] = [
    FailedBind(why: "missing interface", interface: "swiftftr-none0"),
    FailedBind(why: "source this host does not have", sourceIP: "192.0.2.77"),
  ]

  @Test(
    "A bind that fails sends nothing, not even the server-name lookups",
    arguments: failedBinds)
  func failedBindSendsNothing(bind: FailedBind) async throws {
    let answer = try Self.answering(AF_INET, ip: Self.mapped4)
    defer { answer.stop() }
    let lookups = NameLookups(["stun-a.test": answer.port, "stun-b.test": answer.port])
    let sends = STUNSends()

    let outcome = await TestSeams.$stunServers.withValue(
      Self.named(["stun-a.test", "stun-b.test"])
    ) {
      await TestSeams.$resolveSTUNServer.withValue(lookups.seam) {
        await TestSeams.$sendSTUNRequest.withValue(sends.seam(family: AF_INET)) {
          do {
            return Result<PublicIPObservation?, Error>.success(
              try await Self.ask(.v4, interface: bind.interface, sourceIP: bind.sourceIP))
          } catch {
            return .failure(error)
          }
        }
      }
    }

    #expect(throws: STUNError.self) { try outcome.get() }
    #expect(lookups.calls.value == 0, "a server name was looked up although the bind failed")
    #expect(sends.boundInterfaces.isEmpty, "a request was sent although the bind failed")
    #expect(answer.requests.value == 0)
  }

  @Test("A source address of the other family, or none at all, sends nothing")
  func sourceOfOtherFamilySendsNothing() async throws {
    let lookups = NameLookups([:])
    let sends = STUNSends()
    for (family, source) in [
      (IPAddressFamily.v6, "127.0.0.1"), (.v4, "::1"), (.v4, "not-an-ip"),
    ] {
      let found = try await TestSeams.$stunServers.withValue(Self.named(["stun-a.test"])) {
        try await TestSeams.$resolveSTUNServer.withValue(lookups.seam) {
          try await TestSeams.$sendSTUNRequest.withValue(sends.seam(family: family.socketFamily)) {
            try await Self.ask(family, interface: nil, sourceIP: source)
          }
        }
      }
      #expect(found == nil, "\(family) from \(source)")
    }
    #expect(lookups.calls.value == 0)
    #expect(sends.boundInterfaces.isEmpty)
  }

  // MARK: STUN only

  @Test("When STUN fails on a bound tracer, no other discovery query is sent")
  func nothingAfterSTUNFails() async throws {
    // Both servers refuse, so STUN fails at once with a definite error. The DNS transport's send
    // is replaced by one that counts and sends nothing, so a query can never leave the host.
    let first = try RefusingUDPPort()
    let second = try RefusingUDPPort()
    let sends = STUNSends()
    let dnsSends = FaultCounter()
    let noDNS: TestSeams.SendDatagram = { _, _ in
      dnsSends.increment()
      Darwin.errno = ENETUNREACH
      return -1
    }

    let outcome = await TestSeams.$stunServers.withValue(
      AsyncPublicIPDiscoveryTests.servers(v4: [
        ("127.0.0.1", first.port), ("127.0.0.1", second.port),
      ])
    ) {
      await TestSeams.$sendSTUNRequest.withValue(sends.seam(family: AF_INET)) {
        await TestSeams.$sendDatagram.withValue(noDNS) {
          do {
            return Result<PublicIPObservation?, Error>.success(
              try await Self.ask(.v4, interface: "lo0", sourceIP: "127.0.0.1"))
          } catch {
            return .failure(error)
          }
        }
      }
    }

    #expect(throws: STUNError.self) { try outcome.get() }
    #expect(sends.boundInterfaces.count == 2, "both STUN servers should have been tried")
    #expect(dnsSends.value == 0, "a DNS query was sent after STUN failed")
  }

  // MARK: getPublicIPs

  @Test("getPublicIPs with a source address runs only its family's sweep; a malformed one, none")
  func standaloneSourceSelectsFamily() async throws {
    let answer4 = try Self.answering(AF_INET, ip: Self.mapped4)
    let answer6 = try Self.answering(AF_INET6, ip: Self.mapped6)
    defer {
      answer4.stop()
      answer6.stop()
    }
    let servers = AsyncPublicIPDiscoveryTests.servers(
      v4: [("127.0.0.1", answer4.port)], v6: [("::1", answer6.port)])

    let cases: [(source: String, v4: String?, v6: String?)] = [
      ("127.0.0.1", "198.51.100.9", nil), ("::1", nil, "2001:db8::9"), ("not-an-ip", nil, nil),
      ("::1%", nil, nil), ("::1%swiftftr-none0", nil, nil),
    ]
    for (source, v4, v6) in cases {
      let (ips, _) = try await measure(within: Self.watchdog) {
        await TestSeams.$stunServers.withValue(servers) {
          await getPublicIPs(stunTimeout: Self.longSTUNTimeout, sourceIP: source)
        }
      }
      #expect(ips.v4 == v4, "source \(source)")
      #expect(ips.v6 == v6, "source \(source)")
    }
    // One request per family, each from the source of its own family; none unbound.
    #expect(await eventually(within: 10) { answer4.requests.value == 1 })
    #expect(await eventually(within: 10) { answer6.requests.value == 1 })
  }

  /// UDP sockets of this process bound to lo0's interface index, from its descriptor table.
  static func lo0UDPSockets() -> Int {
    let lo0 = if_nametoindex("lo0")
    return DescriptorSampler.openDescriptors().filter { descriptor in
      var info = socket_fdinfo()
      let size = Int32(MemoryLayout<socket_fdinfo>.size)
      guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET),
        proc_pidfdinfo(getpid(), descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) > 0,
        info.psi.soi_protocol == IPPROTO_UDP
      else { return false }
      var index: UInt32 = 0
      var length = socklen_t(MemoryLayout<UInt32>.size)
      let v6 = info.psi.soi_family == AF_INET6
      let found = getsockopt(
        descriptor.proc_fd, v6 ? IPPROTO_IPV6 : IPPROTO_IP, v6 ? IPV6_BOUND_IF : IP_BOUND_IF,
        &index, &length)
      return found == 0 && index == lo0
    }.count
  }

  @Test("Sweeps waiting for the executor hold no sockets beyond one sweep's per slot")
  func queuedSweepsHoldFewSockets() async throws {
    // Two slots, both held by name lookups stalled in the seam; sixteen calls of two sweeps each,
    // every sweep two named servers. At most two sweeps may hold their two sockets each.
    let executor = BlockingIOExecutor(maximumConcurrentOperations: 2, name: "test.pip-admit")
    let gate = StallGate()
    defer { gate.open() }
    let entered = FaultCounter()
    let stalled: TestSeams.ResolveSTUNServer = { _, _, _ in
      entered.increment()
      gate.wait(limit: 60)
      return nil
    }
    let before = Self.lo0UDPSockets()
    let calls = await TestSeams.$blockingIOExecutor.withValue(executor) {
      await TestSeams.$stunServers.withValue(Self.named(["stun-a.test", "stun-b.test"])) {
        await TestSeams.$resolveSTUNServer.withValue(stalled) {
          (0..<16).map { _ in Task { await getPublicIPs(interface: "lo0") } }
        }
      }
    }
    defer { for call in calls { call.cancel() } }
    #expect(await eventually(within: Self.watchdog) { entered.value == 2 })
    let most = TimeStamp()
    let grew = await eventually(within: 2) {
      let open = Self.lo0UDPSockets() - before
      most.set(TimeInterval(max(open, Int(most.value ?? 0))))
      return open > 4
    }
    #expect(!grew, "queued sweeps held \(Int(most.value ?? 0)) sockets")
    for call in calls { call.cancel() }
    gate.open()
    for call in calls { _ = try await measure(within: Self.watchdog) { await call.value } }
  }

  @Test("getPublicIPs cancelled before it starts asks nothing")
  func standaloneCancelledFirst() async throws {
    let requests = RequestLog()
    let discovery: TestSeams.DiscoverPublicIP = { request in
      requests.append(request)
      return STUNPublicIP(ip: "198.51.100.5")
    }
    let outcome = await TestSeams.$discoverPublicIP.withValue(discovery) {
      await PublicIPResolverTests.cancelledFirst { await getPublicIPs() }
    }
    let ips = try outcome.get()
    #expect(ips.v4 == nil && ips.v6 == nil)
    #expect(requests.all.isEmpty, "discovery ran for a call cancelled before it started")
  }

  @Test("getPublicIPs asks the library's resolver for each family, with its bindings")
  func standaloneAsksLibraryResolver() async throws {
    let requests = RequestLog()
    let discovery: TestSeams.DiscoverPublicIP = { request in
      requests.append(request)
      return STUNPublicIP(ip: request.family == .v6 ? "2001:db8::5" : "198.51.100.5")
    }
    // Refusing servers, should the call go around the resolver.
    let refusing4 = try RefusingUDPPort()
    let refusing6 = try RefusingUDPPort(family: AF_INET6)
    let servers = AsyncPublicIPDiscoveryTests.servers(
      v4: [("127.0.0.1", refusing4.port)], v6: [("::1", refusing6.port)])

    let (ips, _) = try await measure(within: Self.watchdog) {
      await TestSeams.$stunServers.withValue(servers) {
        await TestSeams.$discoverPublicIP.withValue(discovery) {
          await getPublicIPs(interface: "lo0")
        }
      }
    }
    #expect(ips.v4 == "198.51.100.5")
    #expect(ips.v6 == "2001:db8::5")
    let asked = requests.all
    #expect(Set(asked.map(\.family)) == [.v4, .v6])
    #expect(asked.allSatisfy { $0.interface == "lo0" && $0.sourceIP == nil })

    // A link-local source keeps its zone, and only its family is asked.
    let zoned = await TestSeams.$discoverPublicIP.withValue(discovery) {
      await getPublicIPs(sourceIP: "fe80::1%lo0")
    }
    #expect(zoned.v6 == "2001:db8::5" && zoned.v4 == nil)
    #expect(requests.all.last?.sourceIP == "fe80::1%lo0")
  }
}
