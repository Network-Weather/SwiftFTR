import Foundation
import SystemConfiguration
import Testing

@testable import SwiftFTR

@Suite("Exact-interface HTTPS transport spike")
struct InterfaceBoundHTTPSProbeSpikeTests {
  @Test("Serializes SNI-related HTTP fields as canonical HTTP/1.1 bytes")
  func canonicalRequestBytesPreserveLogicalHostnameAndUserAgent() throws {
    let configuration = InterfaceBoundHTTPSProbeSpikeConfiguration(
      logicalHostname: "probe.example",
      port: 8_443,
      path: "/status?format=headers",
      interfaceName: "caller-selected-interface",
      endpoint: .ipv4Address("192.0.2.10"),
      userAgent: "NetworkWeather-TestSpike/7")

    let plan = try makeInterfaceBoundHTTPSRequestPlan(configuration: configuration)
    let expected =
      "GET /status?format=headers HTTP/1.1\r\n"
      + "Host: probe.example:8443\r\n"
      + "User-Agent: NetworkWeather-TestSpike/7\r\n"
      + "Accept: */*\r\n"
      + "Connection: close\r\n"
      + "\r\n"

    #expect(plan.serverName == "probe.example")
    #expect(plan.hostHeader == "probe.example:8443")
    #expect(plan.endpointHost == "192.0.2.10")
    #expect(plan.applicationProtocol == "http/1.1")
    #expect(plan.requestBytes == Data(expected.utf8))
    #expect(plan.requestBytes.first == Character("G").asciiValue)
    #expect(plan.requestBytes.suffix(4) == Data([13, 10, 13, 10]))

    for index in plan.requestBytes.indices where plan.requestBytes[index] == 10 {
      #expect(index > plan.requestBytes.startIndex)
      #expect(plan.requestBytes[plan.requestBytes.index(before: index)] == 13)
    }
  }

  @Test("Serializes the stable default User-Agent")
  func serializesDefaultUserAgent() throws {
    let plan = try makeInterfaceBoundHTTPSRequestPlan(
      configuration: InterfaceBoundHTTPSProbeSpikeConfiguration(
        logicalHostname: "probe.example",
        interfaceName: "caller-selected-interface"))
    let request = String(decoding: plan.requestBytes, as: UTF8.self)

    #expect(
      request.contains(
        "User-Agent: \(InterfaceBoundHTTPSProbeSpikeConfiguration.defaultUserAgent)\r\n"))
  }

  @Test("Rejects empty, control, and non-ASCII configurable User-Agent values")
  func rejectsUnsafeUserAgentBytes() {
    for userAgent in ["", "Probe\u{1}", "Probe\tAgent", "Pröbe"] {
      #expect {
        try makeInterfaceBoundHTTPSRequestPlan(
          configuration: InterfaceBoundHTTPSProbeSpikeConfiguration(
            logicalHostname: "probe.example",
            interfaceName: "caller-selected-interface",
            userAgent: userAgent))
      } throws: { error in
        error as? InterfaceBoundHTTPSProbeSpikeError
          == .invalidConfiguration("Invalid User-Agent")
      }
    }
  }

  @Test(
    "Keeps the logical hostname independent from an explicit endpoint family",
    arguments: ExplicitEndpointCase.allCases
  )
  func explicitEndpointKeepsLogicalHostname(endpointCase: ExplicitEndpointCase) throws {
    let plan = try makeInterfaceBoundHTTPSRequestPlan(
      configuration: InterfaceBoundHTTPSProbeSpikeConfiguration(
        logicalHostname: "one.one.one.one",
        interfaceName: "caller-selected-interface",
        endpoint: endpointCase.endpoint))

    #expect(plan.serverName == "one.one.one.one")
    #expect(plan.hostHeader == "one.one.one.one")
    #expect(plan.endpointHost == endpointCase.address)
    #expect(plan.endpoint == endpointCase.endpoint)
  }

  @Test("Rejects an endpoint whose declared family does not match its address")
  func rejectsEndpointFamilyMismatch() {
    #expect {
      try makeInterfaceBoundHTTPSRequestPlan(
        configuration: InterfaceBoundHTTPSProbeSpikeConfiguration(
          logicalHostname: "probe.example",
          interfaceName: "caller-selected-interface",
          endpoint: .ipv6Address("192.0.2.10")))
    } throws: { error in
      error as? InterfaceBoundHTTPSProbeSpikeError == .endpointFamilyMismatch
    }
  }

  @Test(
    "Parses a complete response header across arbitrary fragmentation",
    arguments: [1, 2, 3, 7, 16, 4_096]
  )
  func parsesFragmentedResponseHeaders(chunkSize: Int) throws {
    let wireBytes = Data(
      "HTTP/1.1 204 No Content\r\nServer: fixture\r\nX-Test: fragmented\r\n\r\nbody".utf8)
    let expectedHeaders = Data(
      "HTTP/1.1 204 No Content\r\nServer: fixture\r\nX-Test: fragmented\r\n\r\n".utf8)
    var accumulator = InterfaceBoundHTTPSResponseHeaderAccumulator(maximumBytes: 1_024)
    var parsed: (statusCode: Int, headers: Data)?

    var offset = 0
    while offset < wireBytes.count, parsed == nil {
      let end = min(offset + chunkSize, wireBytes.count)
      parsed = try accumulator.append(wireBytes.subdata(in: offset..<end))
      offset = end
    }

    let response = try #require(parsed)
    #expect(response.statusCode == 204)
    #expect(response.headers == expectedHeaders)
  }

  @Test("Accepts a complete header exactly at the configured bound")
  func acceptsHeadersAtExactBound() throws {
    let headers = Data("HTTP/1.1 200 OK\r\nX-Boundary: exact\r\n\r\n".utf8)
    var accumulator = InterfaceBoundHTTPSResponseHeaderAccumulator(
      maximumBytes: headers.count)

    let appended = try accumulator.append(headers)
    let parsed = try #require(appended)
    #expect(parsed.statusCode == 200)
    #expect(parsed.headers == headers)
  }

  @Test("Rejects response headers that do not terminate within the configured bound")
  func rejectsOversizedResponseHeaders() {
    var accumulator = InterfaceBoundHTTPSResponseHeaderAccumulator(maximumBytes: 32)

    #expect {
      try accumulator.append(Data(repeating: 65, count: 32))
    } throws: { error in
      error as? InterfaceBoundHTTPSProbeSpikeError == .responseHeadersTooLarge(32)
    }
  }

  @Test(
    "Rejects malformed HTTP status lines",
    arguments: MalformedStatusLineCase.allCases
  )
  func rejectsMalformedStatusLines(testCase: MalformedStatusLineCase) {
    var accumulator = InterfaceBoundHTTPSResponseHeaderAccumulator(maximumBytes: 256)

    #expect {
      try accumulator.append(Data("\(testCase.statusLine)\r\nHeader: value\r\n\r\n".utf8))
    } throws: { error in
      error as? InterfaceBoundHTTPSProbeSpikeError == .malformedStatusLine
    }
  }

  @Test("Fails when the exact caller-supplied interface is absent", .timeLimit(.minutes(1)))
  func missingExactInterfaceFails() async {
    let missingName = "swiftftr-missing-\(UUID().uuidString)"

    await #expect {
      try await resolveInterfaceBoundHTTPSInterface(named: missingName)
    } throws: { error in
      error as? InterfaceBoundHTTPSProbeSpikeError == .interfaceNotAvailable(missingName)
    }
  }

  @Test(
    "Resolves a dynamically discovered loopback interface by exact name",
    .timeLimit(.minutes(1)),
    arguments: LoopbackAddressFamily.allCases
  )
  func resolvesDynamicLoopbackInterface(family: LoopbackAddressFamily) async throws {
    let snapshot = await NetworkInterfaceDiscovery().discover()
    guard
      let interface = snapshot.interfaces.first(where: { candidate in
        candidate.isUp
          && family.addresses(on: candidate).contains(where: { address in
            ipAddressScope(of: address) == .loopback
          })
      })
    else {
      print("Skipping: no active \(family.testDescription) loopback address")
      return
    }

    let resolved = try await resolveInterfaceBoundHTTPSInterface(named: interface.name)
    #expect(resolved.name == interface.name)
  }

  @Test(
    "Caller cancellation cancels the in-flight transport exactly once",
    .timeLimit(.minutes(1))
  )
  func callerCancellationCancelsTransportExactlyOnce() async throws {
    let recorder = SuspendedHTTPSExecution()
    let configuration = testConfiguration(timeout: 30)
    let operation = Task {
      try await interfaceBoundHTTPSProbeSpike(
        configuration: configuration,
        dependencies: dependencies(recorder: recorder))
    }
    await recorder.waitUntilStarted()

    operation.cancel()

    await #expect(throws: CancellationError.self) {
      try await operation.value
    }
    await recorder.waitUntilCancelled()
    #expect(await recorder.cancellationCount == 1)
  }

  @Test(
    "Timeout cancels the in-flight transport exactly once",
    .timeLimit(.minutes(1))
  )
  func timeoutCancelsTransportExactlyOnce() async throws {
    let recorder = SuspendedHTTPSExecution()
    var testDependencies = dependencies(recorder: recorder)
    testDependencies.sleep = { _ in }

    await #expect {
      try await interfaceBoundHTTPSProbeSpike(
        configuration: testConfiguration(timeout: 30),
        dependencies: testDependencies)
    } throws: { error in
      error as? InterfaceBoundHTTPSProbeSpikeError == .timedOut
    }
    await recorder.waitUntilCancelled()
    #expect(await recorder.cancellationCount == 1)
  }

  @Test(
    "A terminal cancellation check prevents a late response from becoming success",
    .timeLimit(.minutes(1))
  )
  func lateCancellationAfterResponseIsNotSwallowed() async {
    let configuration = testConfiguration(timeout: 30)
    let joinObservation = ChildJoinObservation()
    let response = InterfaceBoundHTTPSProbeSpikeResponse(
      statusCode: 200,
      responseHeaders: Data("HTTP/1.1 200 OK\r\n\r\n".utf8),
      negotiatedProtocol: "http/1.1",
      interfaceName: configuration.interfaceName,
      endpointHost: "192.0.2.10")
    let testDependencies = InterfaceBoundHTTPSProbeSpikeDependencies(
      resolveInterface: { name in .testing(name: name) },
      execute: { _, _ in response },
      sleep: { duration in
        do {
          try await ContinuousClock().sleep(for: duration)
        } catch {
          joinObservation.recordChildCancellation()
          throw error
        }
      },
      checkCancellation: {
        joinObservation.recordTerminalCheck()
        throw CancellationError()
      })

    await #expect(throws: CancellationError.self) {
      try await interfaceBoundHTTPSProbeSpike(
        configuration: configuration,
        dependencies: testDependencies)
    }
    #expect(joinObservation.terminalCheckObservedJoinedChild)
  }

  @Test(
    "Live SNI and trust use a logical host with explicit IPv4 and IPv6 endpoints",
    .enabled(if: ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] == nil),
    .timeLimit(.minutes(1)),
    arguments: LiveEndpointCase.allCases
  )
  func liveExactInterfaceTLS(endpointCase: LiveEndpointCase) async throws {
    guard let interfaceName = liveInterfaceName(for: endpointCase) else {
      print(
        "Skipping: no caller-selected or OS-reported \(endpointCase.testDescription) interface")
      return
    }
    guard
      let resolved = try? resolveHost(
        host: "example.com",
        prefer: endpointCase.preferredFamily)
    else {
      print("Skipping: example.com has no usable \(endpointCase.testDescription) endpoint")
      return
    }
    let explicitEndpoint = endpointCase.endpoint(address: resolved.canonical)

    let response = try await NetworkTestGate.shared.withPermit {
      try await interfaceBoundHTTPSProbeSpike(
        configuration: InterfaceBoundHTTPSProbeSpikeConfiguration(
          logicalHostname: "example.com",
          path: "/",
          interfaceName: interfaceName,
          endpoint: explicitEndpoint,
          timeout: 10,
          userAgent: "SwiftFTR-LiveHTTPS-Spike/0.1"))
    }

    #expect((100...599).contains(response.statusCode))
    #expect(response.negotiatedProtocol == "http/1.1")
    #expect(response.interfaceName == interfaceName)
    #expect(response.endpointHost == resolved.canonical)
    #expect(response.endpointHost != "example.com")
    #expect(response.responseHeaders.suffix(4) == Data([13, 10, 13, 10]))
  }

  @Test(
    "Live TLS rejects a certificate for the wrong logical hostname",
    .enabled(if: ProcessInfo.processInfo.environment["SKIP_NETWORK_TESTS"] == nil),
    .timeLimit(.minutes(1))
  )
  func liveTLSRejectsWrongLogicalHostname() async throws {
    guard let interfaceName = liveInterfaceName(for: .ipv4) else {
      print("Skipping: no caller-selected or OS-reported IPv4 interface")
      return
    }
    guard let resolved = try? resolveHost(host: "example.com", prefer: .v4) else {
      print("Skipping: example.com has no usable IPv4 endpoint")
      return
    }
    let endpoint = InterfaceBoundHTTPSEndpoint.ipv4Address(resolved.canonical)

    let goodResponse = try await NetworkTestGate.shared.withPermit {
      try await interfaceBoundHTTPSProbeSpike(
        configuration: InterfaceBoundHTTPSProbeSpikeConfiguration(
          logicalHostname: "example.com",
          interfaceName: interfaceName,
          endpoint: endpoint,
          timeout: 10))
    }
    #expect((100...599).contains(goodResponse.statusCode))

    await #expect {
      try await NetworkTestGate.shared.withPermit {
        try await interfaceBoundHTTPSProbeSpike(
          configuration: InterfaceBoundHTTPSProbeSpikeConfiguration(
            logicalHostname: "wrong-logical-host.invalid",
            interfaceName: interfaceName,
            endpoint: endpoint,
            timeout: 10))
      }
    } throws: { error in
      guard let spikeError = error as? InterfaceBoundHTTPSProbeSpikeError else {
        return false
      }
      if case .tlsFailed = spikeError {
        return true
      }
      return false
    }
  }

  private func testConfiguration(timeout: TimeInterval)
    -> InterfaceBoundHTTPSProbeSpikeConfiguration
  {
    InterfaceBoundHTTPSProbeSpikeConfiguration(
      logicalHostname: "probe.example",
      interfaceName: "caller-selected-interface",
      endpoint: .ipv4Address("192.0.2.10"),
      timeout: timeout)
  }

  private func dependencies(recorder: SuspendedHTTPSExecution)
    -> InterfaceBoundHTTPSProbeSpikeDependencies
  {
    InterfaceBoundHTTPSProbeSpikeDependencies(
      resolveInterface: { name in .testing(name: name) },
      execute: { _, _ in try await recorder.execute() },
      sleep: { duration in try await ContinuousClock().sleep(for: duration) },
      checkCancellation: { try Task.checkCancellation() })
  }

  /// `SWIFTFTR_HTTPS_SPIKE_INTERFACE` lets a live rehearsal use the exact interface selected by
  /// its operator. With no override, the smoke test uses the OS-reported primary for each family.
  private func liveInterfaceName(for endpointCase: LiveEndpointCase) -> String? {
    if let callerSelection = ProcessInfo.processInfo.environment[
      "SWIFTFTR_HTTPS_SPIKE_INTERFACE"],
      !callerSelection.isEmpty
    {
      return callerSelection
    }
    guard
      let value = SCDynamicStoreCopyValue(nil, endpointCase.dynamicStoreKey as CFString),
      let dictionary = value as? [String: Any]
    else {
      return nil
    }
    return dictionary[kSCDynamicStorePropNetPrimaryInterface as String] as? String
  }
}

enum ExplicitEndpointCase: CaseIterable, Sendable, CustomTestStringConvertible {
  case ipv4
  case ipv6

  var endpoint: InterfaceBoundHTTPSEndpoint {
    switch self {
    case .ipv4: .ipv4Address(address)
    case .ipv6: .ipv6Address(address)
    }
  }

  var address: String {
    switch self {
    case .ipv4: "192.0.2.10"
    case .ipv6: "2001:db8::10"
    }
  }

  var testDescription: String {
    switch self {
    case .ipv4: "explicit IPv4 endpoint"
    case .ipv6: "explicit IPv6 endpoint"
    }
  }
}

enum MalformedStatusLineCase: CaseIterable, Sendable, CustomTestStringConvertible {
  case wrongProtocol
  case missingStatus
  case nonnumericStatus
  case statusIsNotExactlyThreeDigits
  case outOfRangeStatus

  var statusLine: String {
    switch self {
    case .wrongProtocol: "NOT-HTTP 200 OK"
    case .missingStatus: "HTTP/1.1"
    case .nonnumericStatus: "HTTP/1.1 two-hundred OK"
    case .statusIsNotExactlyThreeDigits: "HTTP/1.1 0200 Too Many Digits"
    case .outOfRangeStatus: "HTTP/1.1 700 Impossible"
    }
  }

  var testDescription: String { statusLine }
}

enum LoopbackAddressFamily: CaseIterable, Sendable, CustomTestStringConvertible {
  case ipv4
  case ipv6

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

enum LiveEndpointCase: CaseIterable, Sendable, CustomTestStringConvertible {
  case ipv4
  case ipv6

  func endpoint(address: String) -> InterfaceBoundHTTPSEndpoint {
    switch self {
    case .ipv4: return .ipv4Address(address)
    case .ipv6: return .ipv6Address(address)
    }
  }

  var preferredFamily: PreferredFamily {
    switch self {
    case .ipv4: .v4
    case .ipv6: .v6
    }
  }

  var dynamicStoreKey: String {
    switch self {
    case .ipv4: "State:/Network/Global/IPv4"
    case .ipv6: "State:/Network/Global/IPv6"
    }
  }

  var testDescription: String {
    switch self {
    case .ipv4: "IPv4"
    case .ipv6: "IPv6"
    }
  }
}

private final class ChildJoinObservation: @unchecked Sendable {
  private let lock = NSLock()
  private var childCancellationWasObserved = false
  private var terminalCheckSawJoinedChild = false

  var terminalCheckObservedJoinedChild: Bool {
    lock.lock()
    defer { lock.unlock() }
    return terminalCheckSawJoinedChild
  }

  func recordChildCancellation() {
    lock.lock()
    childCancellationWasObserved = true
    lock.unlock()
  }

  func recordTerminalCheck() {
    lock.lock()
    terminalCheckSawJoinedChild = childCancellationWasObserved
    lock.unlock()
  }
}

private actor SuspendedHTTPSExecution {
  private(set) var cancellationCount = 0
  private var isStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []

  func execute() async throws -> InterfaceBoundHTTPSProbeSpikeResponse {
    isStarted = true
    let waiters = startWaiters
    startWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }

    return try await withTaskCancellationHandler {
      try await Task.sleep(for: .seconds(60))
      return InterfaceBoundHTTPSProbeSpikeResponse(
        statusCode: 200,
        responseHeaders: Data("HTTP/1.1 200 OK\r\n\r\n".utf8),
        negotiatedProtocol: "http/1.1",
        interfaceName: "caller-selected-interface",
        endpointHost: "192.0.2.10")
    } onCancel: {
      Task { await self.recordCancellation() }
    }
  }

  func waitUntilStarted() async {
    guard !isStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func waitUntilCancelled() async {
    guard cancellationCount == 0 else { return }
    await withCheckedContinuation { continuation in
      cancellationWaiters.append(continuation)
    }
  }

  private func recordCancellation() {
    cancellationCount += 1
    let waiters = cancellationWaiters
    cancellationWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
  }
}
