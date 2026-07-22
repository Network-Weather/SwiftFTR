import Dispatch
import Foundation
import Network
import Security

#if canImport(Darwin)
  import Darwin
#endif

// This is intentionally an internal spike. It is not wired into `HTTPProbe`, and it does not
// attempt to reproduce URLSession features such as redirects, authentication, cookies, or body
// delivery. Its only job is to establish whether Network.framework can perform a small HTTPS
// header probe on one exact caller-selected BSD interface.

enum InterfaceBoundHTTPSEndpoint: Sendable, Equatable {
  case logicalHostname
  case ipv4Address(String)
  case ipv6Address(String)
}

struct InterfaceBoundHTTPSProbeSpikeConfiguration: Sendable {
  static let defaultUserAgent = "SwiftFTR-InterfaceBoundHTTPS-Spike/0.1"

  let logicalHostname: String
  let port: UInt16
  let path: String
  let interfaceName: String
  let endpoint: InterfaceBoundHTTPSEndpoint
  let timeout: TimeInterval
  let userAgent: String
  let maximumResponseHeaderBytes: Int

  init(
    logicalHostname: String,
    port: UInt16 = 443,
    path: String = "/",
    interfaceName: String,
    endpoint: InterfaceBoundHTTPSEndpoint = .logicalHostname,
    timeout: TimeInterval = 5,
    userAgent: String = Self.defaultUserAgent,
    maximumResponseHeaderBytes: Int = 16 * 1_024
  ) {
    self.logicalHostname = logicalHostname
    self.port = port
    self.path = path
    self.interfaceName = interfaceName
    self.endpoint = endpoint
    self.timeout = timeout
    self.userAgent = userAgent
    self.maximumResponseHeaderBytes = maximumResponseHeaderBytes
  }
}

struct InterfaceBoundHTTPSProbeSpikeResponse: Sendable, Equatable {
  let statusCode: Int
  let responseHeaders: Data
  let negotiatedProtocol: String
  let interfaceName: String
  let endpointHost: String
}

enum InterfaceBoundHTTPSProbeSpikeError: Error, Sendable, Equatable {
  case invalidConfiguration(String)
  case interfaceNotAvailable(String)
  case endpointFamilyMismatch
  case timedOut
  case tlsFailed(OSStatus)
  case connectionFailed(String)
  case unexpectedNegotiatedProtocol(String?)
  case responseHeadersTooLarge(Int)
  case incompleteResponseHeaders
  case malformedStatusLine
}

struct InterfaceBoundHTTPSRequestPlan: Sendable, Equatable {
  static let requiredApplicationProtocol = "http/1.1"

  let serverName: String
  let hostHeader: String
  let endpointHost: String
  let endpoint: InterfaceBoundHTTPSEndpoint
  let interfaceName: String
  let port: UInt16
  let applicationProtocol: String
  let requestBytes: Data
  let maximumResponseHeaderBytes: Int
}

/// Immutable wrapper around an `NWInterface` obtained from an `NWPath` update.
///
/// Network.framework does not declare `NWInterface` as `Sendable`. The object is immutable from
/// this module's perspective, and the wrapper never exposes it outside this implementation.
struct InterfaceBoundHTTPSResolvedInterface: @unchecked Sendable {
  let name: String
  fileprivate let networkInterface: NWInterface?

  fileprivate init(_ networkInterface: NWInterface) {
    self.name = networkInterface.name
    self.networkInterface = networkInterface
  }

  static func testing(name: String) -> Self {
    Self(name: name, networkInterface: nil)
  }

  private init(name: String, networkInterface: NWInterface?) {
    self.name = name
    self.networkInterface = networkInterface
  }
}

struct InterfaceBoundHTTPSProbeSpikeDependencies: Sendable {
  var resolveInterface: @Sendable (String) async throws -> InterfaceBoundHTTPSResolvedInterface
  var execute:
    @Sendable (
      InterfaceBoundHTTPSRequestPlan, InterfaceBoundHTTPSResolvedInterface
    ) async throws -> InterfaceBoundHTTPSProbeSpikeResponse
  var sleep: @Sendable (Duration) async throws -> Void
  var checkCancellation: @Sendable () throws -> Void

  static let live = Self(
    resolveInterface: { name in
      try await resolveInterfaceBoundHTTPSInterface(named: name)
    },
    execute: { plan, interface in
      try await executeInterfaceBoundHTTPSRequest(plan: plan, interface: interface)
    },
    sleep: { duration in
      try await ContinuousClock().sleep(for: duration)
    },
    checkCancellation: {
      try Task.checkCancellation()
    })
}

/// Runs the opt-in, internal exact-interface HTTPS transport spike.
///
/// The caller supplies a BSD interface name. The implementation resolves that exact name to an
/// `NWInterface`, sets `NWParameters.requiredInterface`, uses `logicalHostname` for both TLS SNI
/// and the HTTP Host field, and stops after a bounded complete HTTP response-header block.
func interfaceBoundHTTPSProbeSpike(
  configuration: InterfaceBoundHTTPSProbeSpikeConfiguration,
  dependencies: InterfaceBoundHTTPSProbeSpikeDependencies = .live
) async throws -> InterfaceBoundHTTPSProbeSpikeResponse {
  let requestPlan = try makeInterfaceBoundHTTPSRequestPlan(configuration: configuration)

  let response = try await withThrowingTaskGroup(
    of: InterfaceBoundHTTPSProbeSpikeResponse.self
  ) { group in
    group.addTask {
      let interface = try await dependencies.resolveInterface(requestPlan.interfaceName)
      guard interface.name == requestPlan.interfaceName else {
        throw InterfaceBoundHTTPSProbeSpikeError.interfaceNotAvailable(
          requestPlan.interfaceName)
      }
      return try await dependencies.execute(requestPlan, interface)
    }
    group.addTask {
      try await dependencies.sleep(.seconds(configuration.timeout))
      try Task.checkCancellation()
      throw InterfaceBoundHTTPSProbeSpikeError.timedOut
    }

    defer { group.cancelAll() }
    guard let response = try await group.next() else {
      throw CancellationError()
    }
    return response
  }
  // Keep this after the task-group scope: leaving that scope joins cancelled children. A caller
  // cancellation during that join must not be converted into a successful response.
  try dependencies.checkCancellation()
  return response
}

func makeInterfaceBoundHTTPSRequestPlan(
  configuration: InterfaceBoundHTTPSProbeSpikeConfiguration
) throws -> InterfaceBoundHTTPSRequestPlan {
  guard configuration.port != 0 else {
    throw InterfaceBoundHTTPSProbeSpikeError.invalidConfiguration(
      "Port must be greater than zero")
  }
  guard configuration.timeout.isFinite, configuration.timeout > 0 else {
    throw InterfaceBoundHTTPSProbeSpikeError.invalidConfiguration(
      "Timeout must be finite and greater than zero")
  }
  guard configuration.maximumResponseHeaderBytes >= 16 else {
    throw InterfaceBoundHTTPSProbeSpikeError.invalidConfiguration(
      "Response-header limit must be at least 16 bytes")
  }
  guard isSafeHTTPFieldValue(configuration.userAgent), !configuration.userAgent.isEmpty else {
    throw InterfaceBoundHTTPSProbeSpikeError.invalidConfiguration("Invalid User-Agent")
  }
  guard
    isSafeHostname(configuration.logicalHostname),
    !configuration.logicalHostname.isEmpty
  else {
    throw InterfaceBoundHTTPSProbeSpikeError.invalidConfiguration("Invalid logical hostname")
  }
  guard
    !configuration.interfaceName.isEmpty,
    isSafeInterfaceName(configuration.interfaceName)
  else {
    throw InterfaceBoundHTTPSProbeSpikeError.invalidConfiguration("Invalid interface name")
  }
  guard configuration.path.hasPrefix("/"), isSafeHTTPRequestTarget(configuration.path) else {
    throw InterfaceBoundHTTPSProbeSpikeError.invalidConfiguration("Invalid request target")
  }

  let endpointHost: String
  switch configuration.endpoint {
  case .logicalHostname:
    endpointHost = configuration.logicalHostname
  case .ipv4Address(let address):
    guard detectAddressFamily(address) == AF_INET else {
      throw InterfaceBoundHTTPSProbeSpikeError.endpointFamilyMismatch
    }
    endpointHost = address
  case .ipv6Address(let address):
    guard detectAddressFamily(address) == AF_INET6 else {
      throw InterfaceBoundHTTPSProbeSpikeError.endpointFamilyMismatch
    }
    endpointHost = address
  }

  let hostHeader =
    configuration.port == 443
    ? configuration.logicalHostname
    : "\(configuration.logicalHostname):\(configuration.port)"
  // Assemble the wire representation explicitly. A multiline literal can silently put
  // indentation before the request line or normalize line endings.
  let request = [
    "GET \(configuration.path) HTTP/1.1",
    "Host: \(hostHeader)",
    "User-Agent: \(configuration.userAgent)",
    "Accept: */*",
    "Connection: close",
    "",
    "",
  ].joined(separator: "\r\n")

  guard let requestBytes = request.data(using: .ascii) else {
    throw InterfaceBoundHTTPSProbeSpikeError.invalidConfiguration(
      "Request headers must be ASCII")
  }

  return InterfaceBoundHTTPSRequestPlan(
    serverName: configuration.logicalHostname,
    hostHeader: hostHeader,
    endpointHost: endpointHost,
    endpoint: configuration.endpoint,
    interfaceName: configuration.interfaceName,
    port: configuration.port,
    applicationProtocol: InterfaceBoundHTTPSRequestPlan.requiredApplicationProtocol,
    requestBytes: requestBytes,
    maximumResponseHeaderBytes: configuration.maximumResponseHeaderBytes)
}

struct InterfaceBoundHTTPSResponseHeaderAccumulator: Sendable {
  private static let headerTerminator = Data([13, 10, 13, 10])

  private let maximumBytes: Int
  private var bytes = Data()

  init(maximumBytes: Int) {
    self.maximumBytes = maximumBytes
  }

  mutating func append(_ chunk: Data) throws -> (statusCode: Int, headers: Data)? {
    let remainingCapacity = maximumBytes - bytes.count
    if remainingCapacity > 0 {
      bytes.append(chunk.prefix(remainingCapacity))
    }

    if let terminatorRange = bytes.range(of: Self.headerTerminator) {
      let headers = Data(bytes[..<terminatorRange.upperBound])
      return (try Self.parseStatusCode(from: headers), headers)
    }

    guard chunk.count <= remainingCapacity, bytes.count < maximumBytes else {
      throw InterfaceBoundHTTPSProbeSpikeError.responseHeadersTooLarge(maximumBytes)
    }
    return nil
  }

  private static func parseStatusCode(from headers: Data) throws -> Int {
    guard
      let firstLineEnd = headers.range(of: Data([13, 10]))?.lowerBound,
      let statusLine = String(data: headers[..<firstLineEnd], encoding: .ascii)
    else {
      throw InterfaceBoundHTTPSProbeSpikeError.malformedStatusLine
    }

    let components = statusLine.split(separator: " ", omittingEmptySubsequences: true)
    guard
      components.count >= 2,
      components[0] == "HTTP/1.1" || components[0] == "HTTP/1.0",
      components[1].utf8.count == 3,
      components[1].utf8.allSatisfy({ (48...57).contains($0) }),
      let statusCode = Int(components[1]),
      (100...599).contains(statusCode)
    else {
      throw InterfaceBoundHTTPSProbeSpikeError.malformedStatusLine
    }
    return statusCode
  }
}

private func isSafeHostname(_ value: String) -> Bool {
  !value.utf8.contains { byte in
    byte <= 0x20 || byte == 0x7f || byte == 0x2f || byte == 0x5c || byte == 0x3a
  }
}

private func isSafeInterfaceName(_ value: String) -> Bool {
  !value.utf8.contains { $0 <= 0x20 || $0 == 0x7f }
}

private func isSafeHTTPRequestTarget(_ value: String) -> Bool {
  !value.utf8.contains { $0 <= 0x1f || $0 == 0x7f || $0 == 0x20 }
}

private func isSafeHTTPFieldValue(_ value: String) -> Bool {
  value.utf8.allSatisfy { (0x20...0x7e).contains($0) }
}

func resolveInterfaceBoundHTTPSInterface(named name: String) async throws
  -> InterfaceBoundHTTPSResolvedInterface
{
  let lookup = InterfaceBoundHTTPSInterfaceLookup(name: name)
  return try await lookup.resolve()
}

private func executeInterfaceBoundHTTPSRequest(
  plan: InterfaceBoundHTTPSRequestPlan,
  interface: InterfaceBoundHTTPSResolvedInterface
) async throws -> InterfaceBoundHTTPSProbeSpikeResponse {
  guard let networkInterface = interface.networkInterface else {
    throw InterfaceBoundHTTPSProbeSpikeError.interfaceNotAvailable(interface.name)
  }
  let operation = InterfaceBoundHTTPSNetworkOperation(
    plan: plan,
    interface: networkInterface)
  return try await operation.run()
}

/// Bridges the callback-only NWPathMonitor API. All mutable state is protected by `lock`.
private final class InterfaceBoundHTTPSInterfaceLookup: @unchecked Sendable {
  private let name: String
  private let monitors: [NWPathMonitor]
  private let callbackQueue = DispatchQueue(label: "com.swiftftr.https-spike.interface-lookup")
  private let lock = NSLock()
  private var continuation: CheckedContinuation<InterfaceBoundHTTPSResolvedInterface, any Error>?
  private var terminalResult: Result<InterfaceBoundHTTPSResolvedInterface, any Error>?
  private var monitorsWithInitialUpdate: Set<Int> = []

  init(name: String) {
    self.name = name
    // The generic path is a fast path for default-route interfaces, but it omits loopback on
    // macOS. Query each OS-defined interface type too, then accept only the exact BSD-name match.
    // The interface type is never inferred from a name or numeric suffix.
    self.monitors = [
      NWPathMonitor(),
      NWPathMonitor(requiredInterfaceType: .wifi),
      NWPathMonitor(requiredInterfaceType: .wiredEthernet),
      NWPathMonitor(requiredInterfaceType: .cellular),
      NWPathMonitor(requiredInterfaceType: .loopback),
      NWPathMonitor(requiredInterfaceType: .other),
    ]
  }

  func resolve() async throws -> InterfaceBoundHTTPSResolvedInterface {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        install(continuation)
      }
    } onCancel: {
      self.finish(.failure(CancellationError()))
    }
  }

  private func install(
    _ continuation: CheckedContinuation<InterfaceBoundHTTPSResolvedInterface, any Error>
  ) {
    lock.lock()
    if let terminalResult {
      lock.unlock()
      continuation.resume(with: terminalResult)
      return
    }
    self.continuation = continuation
    for (index, monitor) in monitors.enumerated() {
      monitor.pathUpdateHandler = { [weak self] path in
        self?.handle(path: path, monitorIndex: index)
      }
      monitor.start(queue: callbackQueue)
    }
    lock.unlock()
  }

  private func handle(path: NWPath, monitorIndex: Int) {
    if let interface = path.availableInterfaces.first(where: { $0.name == name }) {
      finish(.success(InterfaceBoundHTTPSResolvedInterface(interface)))
      return
    }

    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return
    }
    monitorsWithInitialUpdate.insert(monitorIndex)
    let allMonitorsReported = monitorsWithInitialUpdate.count == monitors.count
    lock.unlock()

    if allMonitorsReported {
      finish(.failure(InterfaceBoundHTTPSProbeSpikeError.interfaceNotAvailable(name)))
    }
  }

  private func finish(
    _ result: Result<InterfaceBoundHTTPSResolvedInterface, any Error>
  ) {
    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return
    }
    terminalResult = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()

    for monitor in monitors {
      monitor.pathUpdateHandler = nil
      monitor.cancel()
    }
    continuation?.resume(with: result)
  }
}

/// Bridges NWConnection callbacks. `finish` owns the exactly-once terminal transition, and all
/// mutable lifecycle/parser state is protected by `lock`.
private final class InterfaceBoundHTTPSNetworkOperation: @unchecked Sendable {
  private let plan: InterfaceBoundHTTPSRequestPlan
  private let connection: NWConnection
  private let callbackQueue = DispatchQueue(label: "com.swiftftr.https-spike.connection")
  private let lock = NSLock()
  private var accumulator: InterfaceBoundHTTPSResponseHeaderAccumulator
  private var continuation: CheckedContinuation<InterfaceBoundHTTPSProbeSpikeResponse, any Error>?
  private var terminalResult: Result<InterfaceBoundHTTPSProbeSpikeResponse, any Error>?
  private var hasSentRequest = false

  init(plan: InterfaceBoundHTTPSRequestPlan, interface: NWInterface) {
    self.plan = plan
    self.accumulator = InterfaceBoundHTTPSResponseHeaderAccumulator(
      maximumBytes: plan.maximumResponseHeaderBytes)

    let tlsOptions = NWProtocolTLS.Options()
    // The logical hostname remains independent of the optionally pinned IP endpoint. It drives
    // both SNI and default certificate hostname validation. No custom trust callback is installed.
    sec_protocol_options_set_tls_server_name(
      tlsOptions.securityProtocolOptions,
      plan.serverName)
    sec_protocol_options_add_tls_application_protocol(
      tlsOptions.securityProtocolOptions,
      plan.applicationProtocol)

    let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
    parameters.requiredInterface = interface

    self.connection = NWConnection(
      host: NWEndpoint.Host(plan.endpointHost),
      port: NWEndpoint.Port(rawValue: plan.port)!,
      using: parameters)
  }

  func run() async throws -> InterfaceBoundHTTPSProbeSpikeResponse {
    try Task.checkCancellation()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        install(continuation)
      }
    } onCancel: {
      self.finish(.failure(CancellationError()))
    }
  }

  private func install(
    _ continuation: CheckedContinuation<InterfaceBoundHTTPSProbeSpikeResponse, any Error>
  ) {
    lock.lock()
    if let terminalResult {
      lock.unlock()
      continuation.resume(with: terminalResult)
      return
    }
    self.continuation = continuation
    connection.stateUpdateHandler = { [weak self] state in
      self?.handle(state)
    }
    connection.start(queue: callbackQueue)
    lock.unlock()
  }

  private func handle(_ state: NWConnection.State) {
    switch state {
    case .ready:
      sendRequestAfterValidatingApplicationProtocol()
    case .waiting(let error), .failed(let error):
      finish(.failure(Self.probeError(for: error)))
    case .cancelled:
      finish(.failure(CancellationError()))
    default:
      break
    }
  }

  private func sendRequestAfterValidatingApplicationProtocol() {
    let negotiatedProtocol = negotiatedApplicationProtocol()
    // This spike intentionally rejects a missing ALPN result even though RFC-compatible HTTP/1.1
    // servers may omit ALPN. The stricter behavior keeps this experiment unambiguous; it is one
    // reason this is not yet a drop-in replacement for URLSession.
    guard negotiatedProtocol == plan.applicationProtocol else {
      finish(
        .failure(
          InterfaceBoundHTTPSProbeSpikeError.unexpectedNegotiatedProtocol(
            negotiatedProtocol)))
      return
    }

    lock.lock()
    guard terminalResult == nil, !hasSentRequest else {
      lock.unlock()
      return
    }
    hasSentRequest = true
    lock.unlock()

    connection.send(
      content: plan.requestBytes,
      completion: .contentProcessed { [weak self] error in
        guard let self else { return }
        if let error {
          self.finish(.failure(Self.probeError(for: error)))
        } else {
          self.receiveNextHeaderChunk()
        }
      })
  }

  private func receiveNextHeaderChunk() {
    lock.lock()
    let isFinished = terminalResult != nil
    lock.unlock()
    guard !isFinished else { return }

    connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) {
      [weak self] content, _, isComplete, error in
      guard let self else { return }
      if let error {
        self.finish(.failure(Self.probeError(for: error)))
        return
      }

      do {
        if let content, !content.isEmpty {
          lock.lock()
          let parsed: (statusCode: Int, headers: Data)?
          do {
            parsed = try accumulator.append(content)
            lock.unlock()
          } catch {
            lock.unlock()
            throw error
          }

          if let parsed {
            self.finish(
              .success(
                InterfaceBoundHTTPSProbeSpikeResponse(
                  statusCode: parsed.statusCode,
                  responseHeaders: parsed.headers,
                  negotiatedProtocol: self.plan.applicationProtocol,
                  interfaceName: self.plan.interfaceName,
                  endpointHost: self.plan.endpointHost)))
            return
          }
        }

        if isComplete {
          self.finish(
            .failure(InterfaceBoundHTTPSProbeSpikeError.incompleteResponseHeaders))
        } else {
          self.receiveNextHeaderChunk()
        }
      } catch {
        self.finish(.failure(error))
      }
    }
  }

  private func negotiatedApplicationProtocol() -> String? {
    guard
      let metadata = connection.metadata(definition: NWProtocolTLS.definition)
        as? NWProtocolTLS.Metadata,
      let protocolName = sec_protocol_metadata_get_negotiated_protocol(
        metadata.securityProtocolMetadata)
    else {
      return nil
    }
    return String(cString: protocolName)
  }

  private static func probeError(for error: NWError) -> InterfaceBoundHTTPSProbeSpikeError {
    if case .tls(let status) = error {
      return .tlsFailed(status)
    }
    return .connectionFailed(error.debugDescription)
  }

  private func finish(
    _ result: Result<InterfaceBoundHTTPSProbeSpikeResponse, any Error>
  ) {
    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return
    }
    terminalResult = result
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()

    connection.stateUpdateHandler = nil
    connection.cancel()
    continuation?.resume(with: result)
  }
}
