import Darwin
import Dispatch
import Foundation
@_spi(Test) import SwiftFTR
import Testing

@Suite("DNS wire hardening", .serialized)
struct DNSWireHardeningTests {
  @Test("Compressed HTTPS targets keep SvcParams within RDATA")
  func compressedHTTPSTargetUsesWireBytesConsumed() throws {
    var message = Data(repeating: 0, count: 12)
    message.append(contentsOf: __dnsEncodeQName("service.example.com"))
    appendUInt16(65, to: &message)
    appendUInt16(1, to: &message)

    let svcParams = Data([0x00, 0x01, 0x00, 0x02, 0x68, 0x32])
    var rdata = Data([0x00, 0x01, 0xC0, 0x0C])
    rdata.append(svcParams)
    let rdataOffset = message.count
    message.append(rdata)

    let result = try #require(
      __dnsParseHTTPS(
        rdata: rdata,
        rdataOffsetInMessage: rdataOffset,
        fullMessage: message
      ))

    #expect(result.priority == 1)
    #expect(result.target == "service.example.com")
    #expect(result.svcParams == svcParams)
  }

  @Test("HTTPS parsing rejects RDATA outside the DNS message")
  func httpsRDATARequiresValidMessageBounds() {
    let rdata = Data([0x00, 0x01, 0x00])
    let message = Data([0x00, 0x01])

    let result = __dnsParseHTTPS(
      rdata: rdata,
      rdataOffsetInMessage: 1,
      fullMessage: message
    )

    #expect(result == nil)
  }

  @Test("Production query preserves compressed answer owner names")
  func productionQueryPreservesOwnerName() async throws {
    let fixture = try DNSUDPFixture()
    let responder = Task.detached {
      try fixture.respond(with: .success(address: [192, 0, 2, 42]))
    }

    let answers = try await runDNSFixtureQuery(
      port: fixture.port,
      name: "owner.example.com",
      type: 1,
      timeout: 0.5
    )
    try await responder.value

    let answer = try #require(answers.first)
    #expect(answer.name == "owner.example.com")
    #expect(answer.type == 1)
    #expect(answer.rdata == Data([192, 0, 2, 42]))
  }

  @Test(
    "Production query rejects invalid DNS response headers",
    arguments: InvalidDNSHeader.allCases
  )
  func productionQueryRejectsInvalidHeaders(_ invalidHeader: InvalidDNSHeader) async throws {
    let fixture = try DNSUDPFixture()
    let responder = Task.detached {
      try fixture.respond(with: invalidHeader.scenario)
    }

    await #expect {
      try await runDNSFixtureQuery(
        port: fixture.port,
        name: "header.example.com",
        type: 1,
        timeout: 0.5
      )
    } throws: { error in
      guard let dnsError = error as? DNSError else { return false }
      if case .malformedResponse = dnsError { return true }
      return false
    }
    try await responder.value
  }

  @Test("Production query rejects datagrams from an unexpected source")
  func productionQueryRejectsUnexpectedSource() async throws {
    let fixture = try DNSUDPFixture()
    let query = Task {
      try await runDNSFixtureQuery(
        port: fixture.port,
        name: "source.example.com",
        type: 1,
        timeout: 1.0
      )
    }
    let responder = Task.detached {
      try fixture.respond(with: .unexpectedSource)
    }

    try await responder.value
    await #expect {
      try await query.value
    } throws: { error in
      guard let dnsError = error as? DNSError else { return false }
      if case .timeout = dnsError { return true }
      return false
    }
  }
}

/// Runs the synchronous DNS SPI outside Swift's cooperative executor.
///
/// The fixture responder is a Swift task. Blocking a cooperative worker in `recv()` can starve
/// that responder on constrained CI runners and turn a deterministic loopback test into a timeout.
private func runDNSFixtureQuery(
  port: UInt16,
  name: String,
  type: UInt16,
  timeout: TimeInterval
) async throws -> [__DNSAnswer] {
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        continuation.resume(
          returning: try __dnsQuery(
            server: "127.0.0.1",
            port: port,
            name: name,
            type: type,
            timeout: timeout
          ))
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

enum InvalidDNSHeader: CaseIterable, CustomTestStringConvertible, Sendable {
  case mismatchedTransactionID
  case queryInsteadOfResponse
  case unsupportedOpcode
  case truncated

  var scenario: DNSFixtureScenario {
    switch self {
    case .mismatchedTransactionID: .mismatchedTransactionID
    case .queryInsteadOfResponse: .queryInsteadOfResponse
    case .unsupportedOpcode: .unsupportedOpcode
    case .truncated: .truncated
    }
  }

  var testDescription: String {
    switch self {
    case .mismatchedTransactionID: "mismatched transaction ID"
    case .queryInsteadOfResponse: "QR bit not set"
    case .unsupportedOpcode: "non-query opcode"
    case .truncated: "truncated UDP response"
    }
  }
}

enum DNSFixtureScenario: Sendable {
  case success(address: [UInt8])
  case mismatchedTransactionID
  case queryInsteadOfResponse
  case unsupportedOpcode
  case truncated
  case unexpectedSource
}

private enum DNSFixtureError: Error {
  case socketCreationFailed
  case socketConfigurationFailed
  case bindFailed
  case addressLookupFailed
  case receiveFailed
  case malformedQuery
  case sendFailed
}

private final class DNSUDPFixture: @unchecked Sendable {
  let port: UInt16

  private let descriptor: Int32

  init() throws {
    let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
    guard descriptor >= 0 else { throw DNSFixtureError.socketCreationFailed }

    var shouldClose = true
    defer {
      if shouldClose { close(descriptor) }
    }

    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    let timeoutResult = withUnsafePointer(to: &timeout) { pointer in
      setsockopt(
        descriptor,
        SOL_SOCKET,
        SO_RCVTIMEO,
        pointer,
        socklen_t(MemoryLayout<timeval>.size)
      )
    }
    guard timeoutResult == 0 else { throw DNSFixtureError.socketConfigurationFailed }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    let parsedAddress = "127.0.0.1".withCString { pointer in
      inet_pton(AF_INET, pointer, &address.sin_addr)
    }
    guard parsedAddress == 1 else { throw DNSFixtureError.addressLookupFailed }

    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else { throw DNSFixtureError.bindFailed }

    var boundAddress = sockaddr_in()
    var boundAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        getsockname(descriptor, sockaddrPointer, &boundAddressLength)
      }
    }
    guard nameResult == 0 else { throw DNSFixtureError.addressLookupFailed }

    self.descriptor = descriptor
    self.port = UInt16(bigEndian: boundAddress.sin_port)
    shouldClose = false
  }

  deinit {
    close(descriptor)
  }

  func respond(with scenario: DNSFixtureScenario) throws {
    var buffer = [UInt8](repeating: 0, count: 2048)
    var clientAddress = sockaddr_storage()
    var clientAddressLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
    let received = buffer.withUnsafeMutableBytes { bytes in
      withUnsafeMutablePointer(to: &clientAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
          recvfrom(
            descriptor,
            bytes.baseAddress,
            bytes.count,
            0,
            sockaddrPointer,
            &clientAddressLength
          )
        }
      }
    }
    guard received > 0 else { throw DNSFixtureError.receiveFailed }

    let query = Data(buffer.prefix(Int(received)))
    let response = try makeDNSResponse(for: query, scenario: scenario)

    let sendingDescriptor: Int32
    var unexpectedDescriptor: Int32?
    if case .unexpectedSource = scenario {
      let newDescriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
      guard newDescriptor >= 0 else { throw DNSFixtureError.socketCreationFailed }
      unexpectedDescriptor = newDescriptor
      sendingDescriptor = newDescriptor
    } else {
      sendingDescriptor = descriptor
    }
    defer {
      if let unexpectedDescriptor { close(unexpectedDescriptor) }
    }

    let sent = response.withUnsafeBytes { bytes in
      withUnsafePointer(to: &clientAddress) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
          sendto(
            sendingDescriptor,
            bytes.baseAddress,
            bytes.count,
            0,
            sockaddrPointer,
            clientAddressLength
          )
        }
      }
    }
    guard sent == response.count else { throw DNSFixtureError.sendFailed }
  }
}

private func makeDNSResponse(for query: Data, scenario: DNSFixtureScenario) throws -> Data {
  guard query.count >= 17 else { throw DNSFixtureError.malformedQuery }
  let queryBytes = [UInt8](query)
  var transactionID = (UInt16(queryBytes[0]) << 8) | UInt16(queryBytes[1])
  var flags: UInt16 = 0x8180
  var address = [UInt8]([203, 0, 113, 7])

  switch scenario {
  case .success(let responseAddress):
    address = responseAddress
  case .mismatchedTransactionID:
    transactionID &+= 1
  case .queryInsteadOfResponse:
    flags = 0x0180
  case .unsupportedOpcode:
    flags = 0x8980
  case .truncated:
    flags = 0x8380
  case .unexpectedSource:
    break
  }

  guard address.count == 4 else { throw DNSFixtureError.malformedQuery }

  var response = Data()
  appendUInt16(transactionID, to: &response)
  appendUInt16(flags, to: &response)
  appendUInt16(1, to: &response)
  appendUInt16(1, to: &response)
  appendUInt16(0, to: &response)
  appendUInt16(0, to: &response)
  response.append(query.dropFirst(12))
  response.append(contentsOf: [0xC0, 0x0C])
  appendUInt16(1, to: &response)
  appendUInt16(1, to: &response)
  appendUInt32(60, to: &response)
  appendUInt16(UInt16(address.count), to: &response)
  response.append(contentsOf: address)
  return response
}

private func appendUInt16(_ value: UInt16, to data: inout Data) {
  var bigEndianValue = value.bigEndian
  withUnsafeBytes(of: &bigEndianValue) { data.append(contentsOf: $0) }
}

private func appendUInt32(_ value: UInt32, to data: inout Data) {
  var bigEndianValue = value.bigEndian
  withUnsafeBytes(of: &bigEndianValue) { data.append(contentsOf: $0) }
}
