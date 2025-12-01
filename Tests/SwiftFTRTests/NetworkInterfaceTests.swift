import Foundation
import Testing

@testable import SwiftFTR

@Suite("Network Interface Tests")
struct NetworkInterfaceTests {

  // MARK: - Interface Classification Tests

  @Test("Classifies WiFi interface")
  func testWiFiClassification() {
    #expect(NetworkInterfaceDiscovery.classifyInterface("en0") == .wifi)
  }

  @Test("Classifies Ethernet interfaces")
  func testEthernetClassification() {
    #expect(NetworkInterfaceDiscovery.classifyInterface("en1") == .ethernet)
    #expect(NetworkInterfaceDiscovery.classifyInterface("en2") == .ethernet)
    #expect(NetworkInterfaceDiscovery.classifyInterface("en14") == .ethernet)
  }

  @Test("Classifies VPN tunnel interfaces")
  func testVPNTunnelClassification() {
    #expect(NetworkInterfaceDiscovery.classifyInterface("utun0") == .vpnTunnel)
    #expect(NetworkInterfaceDiscovery.classifyInterface("utun3") == .vpnTunnel)
    #expect(NetworkInterfaceDiscovery.classifyInterface("utun16") == .vpnTunnel)
    #expect(NetworkInterfaceDiscovery.classifyInterface("tun0") == .vpnTunnel)
    #expect(NetworkInterfaceDiscovery.classifyInterface("tap0") == .vpnTunnel)
    #expect(NetworkInterfaceDiscovery.classifyInterface("wg0") == .vpnTunnel)
    #expect(NetworkInterfaceDiscovery.classifyInterface("gpd0") == .vpnTunnel)  // GlobalProtect
    #expect(NetworkInterfaceDiscovery.classifyInterface("ztun0") == .vpnTunnel)  // Zscaler
  }

  @Test("Classifies IPSec interfaces")
  func testIPSecClassification() {
    #expect(NetworkInterfaceDiscovery.classifyInterface("ipsec0") == .vpnIPSec)
    #expect(NetworkInterfaceDiscovery.classifyInterface("ipsec1") == .vpnIPSec)
  }

  @Test("Classifies PPP interfaces")
  func testPPPClassification() {
    #expect(NetworkInterfaceDiscovery.classifyInterface("ppp0") == .vpnPPP)
    #expect(NetworkInterfaceDiscovery.classifyInterface("ppp1") == .vpnPPP)
  }

  @Test("Classifies loopback interface")
  func testLoopbackClassification() {
    #expect(NetworkInterfaceDiscovery.classifyInterface("lo0") == .loopback)
  }

  @Test("Classifies bridge interface")
  func testBridgeClassification() {
    #expect(NetworkInterfaceDiscovery.classifyInterface("bridge0") == .bridge)
    #expect(NetworkInterfaceDiscovery.classifyInterface("bridge1") == .bridge)
  }

  @Test("Classifies unknown interfaces as other")
  func testOtherClassification() {
    #expect(NetworkInterfaceDiscovery.classifyInterface("awdl0") == .other)
    #expect(NetworkInterfaceDiscovery.classifyInterface("llw0") == .other)
    #expect(NetworkInterfaceDiscovery.classifyInterface("anpi0") == .other)
  }

  // MARK: - VPN Detection Tests

  @Test("Detects VPN interfaces by name")
  func testIsVPNInterface() {
    // VPN interfaces
    #expect(NetworkInterfaceDiscovery.isVPNInterface("utun0") == true)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("utun16") == true)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("ipsec0") == true)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("ppp0") == true)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("tun0") == true)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("tap0") == true)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("wg0") == true)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("gpd0") == true)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("ztun0") == true)

    // Non-VPN interfaces
    #expect(NetworkInterfaceDiscovery.isVPNInterface("en0") == false)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("en1") == false)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("lo0") == false)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("bridge0") == false)
    #expect(NetworkInterfaceDiscovery.isVPNInterface("awdl0") == false)
  }

  // MARK: - InterfaceType Properties Tests

  @Test("InterfaceType isVPN property")
  func testInterfaceTypeIsVPN() {
    #expect(InterfaceType.vpnTunnel.isVPN == true)
    #expect(InterfaceType.vpnIPSec.isVPN == true)
    #expect(InterfaceType.vpnPPP.isVPN == true)

    #expect(InterfaceType.wifi.isVPN == false)
    #expect(InterfaceType.ethernet.isVPN == false)
    #expect(InterfaceType.loopback.isVPN == false)
    #expect(InterfaceType.bridge.isVPN == false)
    #expect(InterfaceType.other.isVPN == false)
  }

  @Test("InterfaceType isPhysical property")
  func testInterfaceTypeIsPhysical() {
    #expect(InterfaceType.wifi.isPhysical == true)
    #expect(InterfaceType.ethernet.isPhysical == true)

    #expect(InterfaceType.vpnTunnel.isPhysical == false)
    #expect(InterfaceType.vpnIPSec.isPhysical == false)
    #expect(InterfaceType.vpnPPP.isPhysical == false)
    #expect(InterfaceType.loopback.isPhysical == false)
    #expect(InterfaceType.bridge.isPhysical == false)
    #expect(InterfaceType.other.isPhysical == false)
  }

  // MARK: - Interface Discovery Tests

  @Test("Discovers interfaces on system")
  func testDiscoverInterfaces() async {
    let discovery = NetworkInterfaceDiscovery()
    let snapshot = await discovery.discover()

    // Should find at least loopback
    #expect(snapshot.interfaces.count > 0)

    // Loopback should be present
    let loopback = snapshot.interface(named: "lo0")
    #expect(loopback != nil)
    #expect(loopback?.type == .loopback)
    #expect(loopback?.ipv4Addresses.contains("127.0.0.1") == true)
  }

  @Test("Snapshot filters work correctly")
  func testSnapshotFilters() async {
    let discovery = NetworkInterfaceDiscovery()
    let snapshot = await discovery.discover()

    // Physical interfaces should only include wifi/ethernet
    for iface in snapshot.physicalInterfaces {
      #expect(iface.type.isPhysical == true)
      #expect(iface.isUp == true)
    }

    // VPN interfaces should only include VPN types
    for iface in snapshot.vpnInterfaces {
      #expect(iface.type.isVPN == true)
      #expect(iface.isUp == true)
    }

    // Active interfaces should exclude loopback
    for iface in snapshot.activeInterfaces {
      #expect(iface.isUp == true)
      #expect(iface.type != .loopback)
    }
  }

  // MARK: - NetworkInterface Codable Tests

  @Test("NetworkInterface is Codable")
  func testNetworkInterfaceCodable() throws {
    let iface = NetworkInterface(
      name: "utun3",
      type: .vpnTunnel,
      ipv4Addresses: ["100.64.97.64"],
      ipv6Addresses: ["fe80::1"],
      isUp: true,
      isPointToPoint: true,
      mtu: 1500
    )

    let encoder = JSONEncoder()
    let data = try encoder.encode(iface)

    let decoder = JSONDecoder()
    let decoded = try decoder.decode(NetworkInterface.self, from: data)

    #expect(decoded.name == iface.name)
    #expect(decoded.type == iface.type)
    #expect(decoded.ipv4Addresses == iface.ipv4Addresses)
    #expect(decoded.isUp == iface.isUp)
    #expect(decoded.isPointToPoint == iface.isPointToPoint)
  }
}
