import Darwin
import Foundation
@_spi(Test) import SwiftFTR
import Testing

@Suite("DNS Input Validation")
struct DNSInputValidationTests {
  enum PublicTimeoutAPI: CaseIterable, Sendable, CustomTestStringConvertible {
    case dnsQueriesA
    case dnsQueriesAAAA
    case dnsQueriesReverseIPv4
    case dnsQueriesReverseIPv6
    case dnsQueriesTXT
    case dnsQueriesGeneric
    case dnsProbeConvenience
    case dnsProbeConfiguration
    case legacyReverseDNS
    case legacyReverseIPv6
    case legacyQueryA
    case legacyQueryAAAA
    case cymruResolver

    var testDescription: String {
      switch self {
      case .dnsQueriesA: "DNSQueries.a"
      case .dnsQueriesAAAA: "DNSQueries.aaaa"
      case .dnsQueriesReverseIPv4: "DNSQueries.reverseIPv4"
      case .dnsQueriesReverseIPv6: "DNSQueries.reverseIPv6"
      case .dnsQueriesTXT: "DNSQueries.txt"
      case .dnsQueriesGeneric: "DNSQueries.query"
      case .dnsProbeConvenience: "dnsProbe(server:query:timeout:)"
      case .dnsProbeConfiguration: "dnsProbe(config:)"
      case .legacyReverseDNS: "reverseDNS"
      case .legacyReverseIPv6: "reverseIPv6"
      case .legacyQueryA: "queryA"
      case .legacyQueryAAAA: "queryAAAA"
      case .cymruResolver: "CymruDNSResolver.resolve"
      }
    }

    func invoke(timeout: TimeInterval) async throws {
      let invalidServer = "not-a-dns-server"

      switch self {
      case .dnsQueriesA:
        _ = try await SwiftFTR().dns.a(
          hostname: "example.com", server: invalidServer, timeout: timeout)
      case .dnsQueriesAAAA:
        _ = try await SwiftFTR().dns.aaaa(
          hostname: "example.com", server: invalidServer, timeout: timeout)
      case .dnsQueriesReverseIPv4:
        _ = try await SwiftFTR().dns.reverseIPv4(
          ip: "192.0.2.1", server: invalidServer, timeout: timeout)
      case .dnsQueriesReverseIPv6:
        _ = try await SwiftFTR().dns.reverseIPv6(
          ip: "2001:db8::1", server: invalidServer, timeout: timeout)
      case .dnsQueriesTXT:
        _ = try await SwiftFTR().dns.txt(
          hostname: "example.com", server: invalidServer, timeout: timeout)
      case .dnsQueriesGeneric:
        _ = try await SwiftFTR().dns.query(
          name: "example.com", type: .mx, server: invalidServer, timeout: timeout)
      case .dnsProbeConvenience:
        _ = try await dnsProbe(server: invalidServer, timeout: timeout)
      case .dnsProbeConfiguration:
        _ = try await dnsProbe(
          config: DNSProbeConfig(server: invalidServer, timeout: timeout))
      case .legacyReverseDNS:
        _ = try await reverseDNS(
          ip: "192.0.2.1", server: invalidServer, timeout: timeout)
      case .legacyReverseIPv6:
        _ = try await reverseIPv6(
          ip: "2001:db8::1", server: invalidServer, timeout: timeout)
      case .legacyQueryA:
        _ = try await queryA(
          hostname: "example.com", server: invalidServer, timeout: timeout)
      case .legacyQueryAAAA:
        _ = try await queryAAAA(
          hostname: "example.com", server: invalidServer, timeout: timeout)
      case .cymruResolver:
        _ = try await CymruDNSResolver().resolve(ipv4Addrs: [], timeout: timeout)
      }
    }
  }

  enum PTRFamily: Sendable {
    case ipv4
    case ipv6
  }

  struct MalformedPTRInput: Sendable, CustomTestStringConvertible {
    let ip: String
    let family: PTRFamily

    var testDescription: String { ip }
  }

  static let invalidTimeouts: [TimeInterval] = [
    .nan,
    .infinity,
    -.infinity,
    0,
    -1,
    TimeInterval(Int.max),
  ]

  static let invalidQNames = [
    String(repeating: "a", count: 64) + ".example",
    "example..com",
    ".example.com",
    "example.com..",
  ]

  static let malformedPTRInputs = [
    MalformedPTRInput(ip: "1.invalid.2.3.4", family: .ipv4),
    MalformedPTRInput(ip: "1..2.3.4", family: .ipv4),
    MalformedPTRInput(ip: "1.2.3.4.", family: .ipv4),
    MalformedPTRInput(ip: "2001:db8:::1", family: .ipv6),
    MalformedPTRInput(ip: "2001:db8::1%", family: .ipv6),
    MalformedPTRInput(ip: "2001:db8::1%wifi%extra", family: .ipv6),
  ]

  @Test(
    "Every public DNS timeout rejects non-finite and non-positive values",
    arguments: PublicTimeoutAPI.allCases,
    invalidTimeouts
  )
  func invalidTimeout(api: PublicTimeoutAPI, timeout: TimeInterval) async {
    do {
      try await api.invoke(timeout: timeout)
      Issue.record("\(api.testDescription) accepted invalid timeout \(timeout)")
    } catch let error as DNSError {
      guard case .invalidTimeout(let rejectedTimeout) = error else {
        Issue.record("\(api.testDescription) threw the wrong DNS error: \(error)")
        return
      }

      if timeout.isNaN {
        #expect(rejectedTimeout.isNaN)
      } else {
        #expect(rejectedTimeout == timeout)
      }
    } catch {
      Issue.record("\(api.testDescription) threw an unexpected error: \(error)")
    }
  }

  @Test("Socket timeout option failures are surfaced")
  func socketTimeoutOptionFailure() {
    do {
      try __dnsApplySocketTimeout(fd: -1, timeout: 1)
      Issue.record("Applying DNS timeouts to an invalid descriptor unexpectedly succeeded")
    } catch let error as DNSError {
      guard case .setsockoptFailed(let option, let errorCode) = error else {
        Issue.record("Socket timeout setup threw the wrong DNS error: \(error)")
        return
      }

      #expect(option == "SO_RCVTIMEO")
      #expect(errorCode == EBADF)
    } catch {
      Issue.record("Socket timeout setup threw an unexpected error: \(error)")
    }
  }

  @Test("QNAME encoding rejects invalid labels", arguments: invalidQNames)
  func invalidQName(name: String) async {
    do {
      _ = try await queryA(
        hostname: name,
        server: "not-a-dns-server",
        timeout: 1
      )
      Issue.record("Accepted invalid QNAME \(name)")
    } catch let error as DNSError {
      guard case .invalidHostname(let rejectedName) = error else {
        Issue.record("Invalid QNAME threw the wrong DNS error: \(error)")
        return
      }
      #expect(rejectedName == name)
    } catch {
      Issue.record("Invalid QNAME threw an unexpected error: \(error)")
    }
  }

  @Test("QNAME encoding accepts a 63-byte label and a trailing root dot")
  func maximumQNameLabel() {
    let label = String(repeating: "a", count: 63)
    let encoded = __dnsEncodeQName(label + ".")

    #expect(encoded.first == 63)
    #expect(encoded.count == 65)
    #expect(encoded.last == 0)
  }

  @Test(
    "Malformed PTR inputs are rejected without querying a server", arguments: malformedPTRInputs)
  func malformedPTRInput(input: MalformedPTRInput) async {
    let tracer = SwiftFTR()

    switch input.family {
    case .ipv4:
      await expectInvalidIP(input.ip) {
        _ = try await reverseDNS(
          ip: input.ip, server: "not-a-dns-server", timeout: 1)
      }
      await expectInvalidIP(input.ip) {
        _ = try await tracer.dns.reverseIPv4(
          ip: input.ip, server: "not-a-dns-server", timeout: 1)
      }
    case .ipv6:
      await expectInvalidIP(input.ip) {
        _ = try await reverseIPv6(
          ip: input.ip, server: "not-a-dns-server", timeout: 1)
      }
      await expectInvalidIP(input.ip) {
        _ = try await tracer.dns.reverseIPv6(
          ip: input.ip, server: "not-a-dns-server", timeout: 1)
      }
    }
  }

  @Test("Family-specific PTR APIs reject the other address family")
  func ptrAddressFamilyMismatch() async {
    let tracer = SwiftFTR()

    await expectInvalidIP("2001:db8::1") {
      _ = try await reverseDNS(
        ip: "2001:db8::1", server: "not-a-dns-server", timeout: 1)
    }
    await expectInvalidIP("127.0.0.1") {
      _ = try await reverseIPv6(
        ip: "127.0.0.1", server: "not-a-dns-server", timeout: 1)
    }
    await expectInvalidIP("2001:db8::1") {
      _ = try await tracer.dns.reverseIPv4(
        ip: "2001:db8::1", server: "not-a-dns-server", timeout: 1)
    }
    await expectInvalidIP("127.0.0.1") {
      _ = try await tracer.dns.reverseIPv6(
        ip: "127.0.0.1", server: "not-a-dns-server", timeout: 1)
    }
  }

  private func expectInvalidIP(
    _ expectedIP: String,
    operation: @Sendable () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("Accepted invalid PTR input \(expectedIP)")
    } catch let error as DNSError {
      guard case .invalidIP(let rejectedIP) = error else {
        Issue.record("Invalid PTR input threw the wrong DNS error: \(error)")
        return
      }
      #expect(rejectedIP == expectedIP)
    } catch {
      Issue.record("Invalid PTR input threw an unexpected error: \(error)")
    }
  }
}
