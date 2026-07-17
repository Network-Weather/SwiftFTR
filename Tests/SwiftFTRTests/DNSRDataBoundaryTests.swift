import Foundation
@_spi(Test) import SwiftFTR
import Testing

@Suite("DNS RDATA boundary safety")
struct DNSRDataBoundaryTests {
  @Test("Name-only records cannot borrow an encoded name from the following record")
  func nameOnlyRecordsStayWithinRData() {
    let rdata = Data([2, 0x6E, 0x73])  // "ns" without its terminating root label.
    var message = rdata
    message.append(0)  // Root owner name belonging to the next record.

    #expect(
      __dnsParsePTR(rdata: rdata, rdataOffsetInMessage: 0, fullMessage: message) == nil)
    #expect(__dnsParseNS(rdata: rdata, rdataOffsetInMessage: 0, fullMessage: message) == nil)
    #expect(
      __dnsParseCNAME(rdata: rdata, rdataOffsetInMessage: 0, fullMessage: message) == nil)
  }

  @Test("MX and SRV target names cannot cross RDLENGTH")
  func fixedPrefixRecordsStayWithinRData() {
    let mxRData = Data([0, 10, 2, 0x6D, 0x78])  // Preference + unterminated "mx".
    var mxMessage = mxRData
    mxMessage.append(0)
    #expect(
      __dnsParseMX(rdata: mxRData, rdataOffsetInMessage: 0, fullMessage: mxMessage) == nil)

    let srvRData = Data([0, 1, 0, 2, 0, 80, 2, 0x73, 0x72])  // Header + unterminated "sr".
    var srvMessage = srvRData
    srvMessage.append(0)
    #expect(
      __dnsParseSRV(rdata: srvRData, rdataOffsetInMessage: 0, fullMessage: srvMessage)
        == nil)
  }

  @Test("SOA names and fixed fields cannot cross RDLENGTH")
  func soaFieldsStayWithinRData() {
    let truncatedNameRData = Data([0, 2, 0x6E, 0x73])  // Root MNAME + unterminated "ns".
    var nameMessage = truncatedNameRData
    nameMessage.append(0)
    nameMessage.append(contentsOf: repeatElement(UInt8(0), count: 20))
    #expect(
      __dnsParseSOA(
        rdata: truncatedNameRData,
        rdataOffsetInMessage: 0,
        fullMessage: nameMessage
      ) == nil)

    var truncatedFieldsRData = Data([0, 0])  // Root MNAME and RNAME.
    truncatedFieldsRData.append(contentsOf: repeatElement(UInt8(0), count: 16))
    var fieldsMessage = truncatedFieldsRData
    fieldsMessage.append(contentsOf: repeatElement(UInt8(0), count: 4))
    #expect(
      __dnsParseSOA(
        rdata: truncatedFieldsRData,
        rdataOffsetInMessage: 0,
        fullMessage: fieldsMessage
      ) == nil)
  }

  @Test("Compression pointers may target valid names outside RDATA")
  func compressedNamesCanTargetTheFullMessage() throws {
    let encodedTarget = Data(__dnsEncodeQName("target.example"))
    let pointer = Data([0xC0, 0x00])

    let (nameOffset, nameMessage) = message(prefix: encodedTarget, rdata: pointer)
    #expect(
      __dnsParsePTR(
        rdata: pointer,
        rdataOffsetInMessage: nameOffset,
        fullMessage: nameMessage
      ) == "target.example")
    #expect(
      __dnsParseNS(
        rdata: pointer,
        rdataOffsetInMessage: nameOffset,
        fullMessage: nameMessage
      ) == "target.example")
    #expect(
      __dnsParseCNAME(
        rdata: pointer,
        rdataOffsetInMessage: nameOffset,
        fullMessage: nameMessage
      ) == "target.example")

    var mxRData = Data([0, 10])
    mxRData.append(pointer)
    let (mxOffset, mxMessage) = message(prefix: encodedTarget, rdata: mxRData)
    let mx = try #require(
      __dnsParseMX(rdata: mxRData, rdataOffsetInMessage: mxOffset, fullMessage: mxMessage))
    #expect(mx.0 == 10)
    #expect(mx.1 == "target.example")

    var srvRData = Data([0, 1, 0, 2, 0, 80])
    srvRData.append(pointer)
    let (srvOffset, srvMessage) = message(prefix: encodedTarget, rdata: srvRData)
    let srv = try #require(
      __dnsParseSRV(
        rdata: srvRData,
        rdataOffsetInMessage: srvOffset,
        fullMessage: srvMessage
      ))
    #expect(srv.priority == 1)
    #expect(srv.weight == 2)
    #expect(srv.port == 80)
    #expect(srv.target == "target.example")

    var soaRData = pointer
    soaRData.append(pointer)
    for value: UInt32 in 1...5 {
      append(value, to: &soaRData)
    }
    let (soaOffset, soaMessage) = message(prefix: encodedTarget, rdata: soaRData)
    let soa = try #require(
      __dnsParseSOA(
        rdata: soaRData,
        rdataOffsetInMessage: soaOffset,
        fullMessage: soaMessage
      ))
    #expect(soa.primaryNS == "target.example")
    #expect(soa.adminEmail == "target.example")
    #expect(soa.serial == 1)
    #expect(soa.refresh == 2)
    #expect(soa.retry == 3)
    #expect(soa.expire == 4)
    #expect(soa.minimumTTL == 5)
  }

  @Test("Compression pointers cannot reference a later record")
  func forwardCompressionPointerIsRejected() {
    let forwardPointer = Data([0xC0, 0x02])
    var message = forwardPointer
    message.append(contentsOf: __dnsEncodeQName("next.example"))

    #expect(
      __dnsParsePTR(
        rdata: forwardPointer,
        rdataOffsetInMessage: 0,
        fullMessage: message
      ) == nil)
  }

  @Test("Record-specific parsers reject bytes after their final field")
  func trailingRDataIsRejected() {
    var nameRData = Data(__dnsEncodeQName("target.example"))
    nameRData.append(0xFF)
    #expect(
      __dnsParsePTR(
        rdata: nameRData,
        rdataOffsetInMessage: 0,
        fullMessage: nameRData
      ) == nil)
    #expect(
      __dnsParseNS(
        rdata: nameRData,
        rdataOffsetInMessage: 0,
        fullMessage: nameRData
      ) == nil)
    #expect(
      __dnsParseCNAME(
        rdata: nameRData,
        rdataOffsetInMessage: 0,
        fullMessage: nameRData
      ) == nil)

    var mxRData = Data([0, 10])
    mxRData.append(contentsOf: __dnsEncodeQName("target.example"))
    mxRData.append(0xFF)
    #expect(
      __dnsParseMX(rdata: mxRData, rdataOffsetInMessage: 0, fullMessage: mxRData) == nil)

    var srvRData = Data([0, 1, 0, 2, 0, 80])
    srvRData.append(contentsOf: __dnsEncodeQName("target.example"))
    srvRData.append(0xFF)
    #expect(
      __dnsParseSRV(rdata: srvRData, rdataOffsetInMessage: 0, fullMessage: srvRData) == nil)

    var soaRData = Data([0, 0])
    for value: UInt32 in 1...5 {
      append(value, to: &soaRData)
    }
    soaRData.append(0xFF)
    #expect(
      __dnsParseSOA(rdata: soaRData, rdataOffsetInMessage: 0, fullMessage: soaRData) == nil)
  }

  @Test("Malformed compressed names are rejected")
  func malformedCompressedNamesAreRejected() {
    let reserved01 = Data([0x40, 0])
    #expect(
      __dnsParsePTR(
        rdata: reserved01,
        rdataOffsetInMessage: 0,
        fullMessage: reserved01
      ) == nil)

    let reserved10 = Data([0x80, 0])
    #expect(
      __dnsParsePTR(
        rdata: reserved10,
        rdataOffsetInMessage: 0,
        fullMessage: reserved10
      ) == nil)

    let badPointer = Data([0xC0, 0xFF])
    #expect(
      __dnsParsePTR(
        rdata: badPointer,
        rdataOffsetInMessage: 0,
        fullMessage: badPointer
      ) == nil)

    let pointerCycle = Data([0xC0, 0x00])
    #expect(
      __dnsParsePTR(
        rdata: pointerCycle,
        rdataOffsetInMessage: 0,
        fullMessage: pointerCycle
      ) == nil)
  }

  @Test("Expanded names longer than 255 wire octets are rejected")
  func overlongExpandedNameIsRejected() {
    var overlongName = Data()
    for _ in 0..<4 {
      overlongName.append(63)
      overlongName.append(contentsOf: repeatElement(UInt8(0x61), count: 63))
    }
    overlongName.append(0)

    #expect(
      __dnsParsePTR(
        rdata: overlongName,
        rdataOffsetInMessage: 0,
        fullMessage: overlongName
      ) == nil)
  }

  private func message(prefix: Data, rdata: Data) -> (rdataOffset: Int, message: Data) {
    var result = prefix
    let rdataOffset = result.count
    result.append(rdata)
    return (rdataOffset, result)
  }

  private func append(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
  }
}
