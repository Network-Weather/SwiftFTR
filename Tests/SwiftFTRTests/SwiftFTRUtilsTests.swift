import XCTest

@testable import SwiftFTR

final class SwiftFTRUtilsTests: XCTestCase {
  func testPrivateAndCGNATDetection() {
    // Private
    XCTAssertTrue(isPrivateIPv4("10.0.0.1"))
    XCTAssertTrue(isPrivateIPv4("172.16.0.1"))
    XCTAssertTrue(isPrivateIPv4("172.31.255.255"))
    XCTAssertTrue(isPrivateIPv4("192.168.1.1"))
    XCTAssertTrue(isPrivateIPv4("169.254.10.10"))  // link-local
    XCTAssertFalse(isPrivateIPv4("8.8.8.8"))

    // CGNAT
    XCTAssertTrue(isCGNATIPv4("100.64.0.1"))
    XCTAssertTrue(isCGNATIPv4("100.127.255.254"))
    XCTAssertFalse(isCGNATIPv4("100.63.255.255"))
    XCTAssertFalse(isCGNATIPv4("8.8.8.8"))
  }

  func testPrivateAndCGNATDetectionRejectsMalformedAddresses() {
    let malformedPrivateAddresses = [
      "10.0.-1.999",
      "172.16.0",
      "192.168.0.1.2",
      "169.254.256.1",
      "::ffff:192.168.1.1",
    ]
    for address in malformedPrivateAddresses {
      XCTAssertFalse(isPrivateIPv4(address), address)
    }

    let malformedCGNATAddresses = [
      "100.64.-1.999",
      "100.64.0",
      "100.64.0.1.2",
      "100.64.256.1",
      "::ffff:100.64.0.1",
    ]
    for address in malformedCGNATAddresses {
      XCTAssertFalse(isCGNATIPv4(address), address)
    }
  }
}
