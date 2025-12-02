import Foundation

#if canImport(Darwin)
  import Darwin
#endif

/// Type of network interface
public enum InterfaceType: String, Sendable, Codable {
  case wifi  // en0 typically on Mac
  case ethernet  // en1+ or Thunderbolt adapters
  case vpnTunnel  // utun* (WireGuard, Tailscale, OpenVPN, etc.)
  case vpnIPSec  // ipsec* interfaces
  case vpnPPP  // ppp* (L2TP, legacy)
  case bridge  // bridge0
  case loopback  // lo0
  case other

  /// Whether this interface type represents a VPN tunnel
  public var isVPN: Bool {
    switch self {
    case .vpnTunnel, .vpnIPSec, .vpnPPP:
      return true
    default:
      return false
    }
  }

  /// Whether this interface type represents a physical network adapter
  public var isPhysical: Bool {
    switch self {
    case .wifi, .ethernet:
      return true
    default:
      return false
    }
  }
}

/// A discovered network interface
public struct NetworkInterface: Sendable, Codable, Identifiable {
  public var id: String { name }

  /// Interface name (e.g., "en0", "utun3")
  public let name: String

  /// Classified interface type
  public let type: InterfaceType

  /// IPv4 addresses assigned to this interface
  public let ipv4Addresses: [String]

  /// IPv6 addresses assigned to this interface
  public let ipv6Addresses: [String]

  /// Whether the interface is up and running
  public let isUp: Bool

  /// Whether this is a point-to-point interface (typical for VPN tunnels)
  public let isPointToPoint: Bool

  /// Interface MTU (if available)
  public let mtu: Int?

  public init(
    name: String,
    type: InterfaceType,
    ipv4Addresses: [String],
    ipv6Addresses: [String],
    isUp: Bool,
    isPointToPoint: Bool,
    mtu: Int?
  ) {
    self.name = name
    self.type = type
    self.ipv4Addresses = ipv4Addresses
    self.ipv6Addresses = ipv6Addresses
    self.isUp = isUp
    self.isPointToPoint = isPointToPoint
    self.mtu = mtu
  }
}

/// Snapshot of all network interfaces at a point in time
public struct NetworkInterfaceSnapshot: Sendable, Codable {
  /// All discovered interfaces
  public let interfaces: [NetworkInterface]

  /// Timestamp when discovery was performed
  public let timestamp: Date

  public init(interfaces: [NetworkInterface], timestamp: Date = Date()) {
    self.interfaces = interfaces
    self.timestamp = timestamp
  }

  /// Physical network interfaces (WiFi, Ethernet)
  public var physicalInterfaces: [NetworkInterface] {
    interfaces.filter { $0.type.isPhysical && $0.isUp }
  }

  /// VPN tunnel interfaces
  public var vpnInterfaces: [NetworkInterface] {
    interfaces.filter { $0.type.isVPN && $0.isUp }
  }

  /// All active (up) interfaces excluding loopback
  public var activeInterfaces: [NetworkInterface] {
    interfaces.filter { $0.isUp && $0.type != .loopback }
  }

  /// Find interface by name
  public func interface(named name: String) -> NetworkInterface? {
    interfaces.first { $0.name == name }
  }
}

/// Actor for discovering network interfaces
public actor NetworkInterfaceDiscovery {
  public init() {}

  /// Check if an interface name indicates a VPN tunnel
  public static func isVPNInterface(_ name: String) -> Bool {
    let vpnPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg", "gpd", "ztun"]
    return vpnPrefixes.contains { name.hasPrefix($0) }
  }

  /// Classify interface type from its name
  public static func classifyInterface(_ name: String) -> InterfaceType {
    // VPN tunnels
    if name.hasPrefix("utun") { return .vpnTunnel }
    if name.hasPrefix("tun") { return .vpnTunnel }
    if name.hasPrefix("tap") { return .vpnTunnel }
    if name.hasPrefix("wg") { return .vpnTunnel }
    if name.hasPrefix("gpd") { return .vpnTunnel }  // GlobalProtect
    if name.hasPrefix("ztun") { return .vpnTunnel }  // Zscaler
    if name.hasPrefix("ipsec") { return .vpnIPSec }
    if name.hasPrefix("ppp") { return .vpnPPP }

    // System interfaces
    if name == "lo0" || name.hasPrefix("lo") { return .loopback }
    if name.hasPrefix("bridge") { return .bridge }

    // Physical interfaces
    // On macOS: en0 is typically WiFi on laptops, en1+ are additional adapters
    // This is a heuristic - precise detection would require IOKit
    if name == "en0" { return .wifi }
    if name.hasPrefix("en") { return .ethernet }

    return .other
  }

  /// Discover all network interfaces on the system
  public func discover() -> NetworkInterfaceSnapshot {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
      return discoverDarwin()
    #else
      // Fallback for unsupported platforms
      return NetworkInterfaceSnapshot(interfaces: [])
    #endif
  }

  #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
    private func discoverDarwin() -> NetworkInterfaceSnapshot {
      var ifaddrsPtr: UnsafeMutablePointer<ifaddrs>?
      guard getifaddrs(&ifaddrsPtr) == 0, let firstAddr = ifaddrsPtr else {
        return NetworkInterfaceSnapshot(interfaces: [])
      }
      defer { freeifaddrs(ifaddrsPtr) }

      // Collect interface data, grouping by name
      var interfaceData: [String: InterfaceBuilder] = [:]

      var current: UnsafeMutablePointer<ifaddrs>? = firstAddr
      while let addr = current {
        let name = String(cString: addr.pointee.ifa_name)
        let flags = addr.pointee.ifa_flags

        var builder = interfaceData[name] ?? InterfaceBuilder(name: name)
        builder.flags = flags

        // Extract address based on family
        if let sockaddr = addr.pointee.ifa_addr {
          switch Int32(sockaddr.pointee.sa_family) {
          case AF_INET:
            // IPv4 address
            let ipv4 = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
              var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
              var addrCopy = ptr.pointee.sin_addr
              inet_ntop(AF_INET, &addrCopy, &buf, socklen_t(INET_ADDRSTRLEN))
              let nullIdx = buf.firstIndex(of: 0) ?? buf.endIndex
              let bytes = buf[..<nullIdx].map { UInt8(bitPattern: $0) }
              return String(decoding: bytes, as: UTF8.self)
            }
            if !builder.ipv4Addresses.contains(ipv4) {
              builder.ipv4Addresses.append(ipv4)
            }

          case AF_INET6:
            // IPv6 address
            let ipv6 = sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { ptr in
              var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
              var addrCopy = ptr.pointee.sin6_addr
              inet_ntop(AF_INET6, &addrCopy, &buf, socklen_t(INET6_ADDRSTRLEN))
              let nullIdx = buf.firstIndex(of: 0) ?? buf.endIndex
              let bytes = buf[..<nullIdx].map { UInt8(bitPattern: $0) }
              return String(decoding: bytes, as: UTF8.self)
            }
            if !builder.ipv6Addresses.contains(ipv6) {
              builder.ipv6Addresses.append(ipv6)
            }

          default:
            break
          }
        }

        interfaceData[name] = builder
        current = addr.pointee.ifa_next
      }

      // Build final interface list
      let interfaces = interfaceData.values.map { $0.build() }
        .sorted { $0.name < $1.name }

      return NetworkInterfaceSnapshot(interfaces: interfaces)
    }
  #endif
}

// MARK: - Internal Builder

private struct InterfaceBuilder {
  let name: String
  var flags: UInt32 = 0
  var ipv4Addresses: [String] = []
  var ipv6Addresses: [String] = []

  init(name: String) {
    self.name = name
  }

  func build() -> NetworkInterface {
    let isUp = (flags & UInt32(IFF_UP)) != 0
    let isPointToPoint = (flags & UInt32(IFF_POINTOPOINT)) != 0

    return NetworkInterface(
      name: name,
      type: NetworkInterfaceDiscovery.classifyInterface(name),
      ipv4Addresses: ipv4Addresses,
      ipv6Addresses: ipv6Addresses,
      isUp: isUp,
      isPointToPoint: isPointToPoint,
      mtu: nil  // Could be retrieved via ioctl if needed
    )
  }
}
