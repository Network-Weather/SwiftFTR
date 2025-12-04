# VPN-Aware Hop Classification Enhancement Proposal

## Executive Summary

The current SwiftFTR hop classification algorithm has a bug when classifying hops that appear **after** a VPN entry point: private IPs (RFC1918) at the VPN exit node's location are incorrectly classified as `LOCAL` instead of `VPN`. This causes false positive alerts in NWX when the remote LAN equipment (e.g., a UniFi router at the exit node) doesn't respond to ICMP.

**Example of the bug:**
```
Hop  IP               Category   Issue
1    10.35.0.1        LOCAL      ✓ Correct (physical gateway)
2    100.120.205.29   ISP        ✗ Should be VPN (Tailscale CGNAT)
3    192.168.1.1      LOCAL      ✗ Should be VPN (exit node's LAN router)
4    157.131.132.109  ISP        ✓ Correct (Sonic.net - physical ISP at exit)
...
```

This proposal outlines enhancements to make the classification algorithm VPN-aware in a way that correctly attributes network segments.

---

## Problem Analysis

### Current Behavior

The existing classification logic in `Segmentation.swift` (lines 189-264) handles VPN context like this:

```swift
if isVPNTrace {
  if isCGNAT { cat = .vpn; seenVPNHop = true }
  else if isPrivate && seenVPNHop { cat = .vpn }
  else if isPrivate && !seenVPNHop { cat = .local }
  // ...
}
```

**The bug**: `seenVPNHop` is only set to `true` when a CGNAT address is seen. But in many VPN configurations (especially Tailscale with exit nodes), the first VPN-related hop might be a public Tailscale relay IP or the exit node's public IP, not CGNAT.

### Real-World Trace Analysis

When tracing through Tailscale to an exit node:

```
TTL  IP                 What It Is                          Current    Correct
1    10.35.0.1          Local gateway (MikroTik)            LOCAL      LOCAL
2    100.120.205.29     Tailscale peer (trogdor.ts.net)     ISP        VPN
3    192.168.1.1        Exit node's LAN router (UniFi)      LOCAL      VPN
4    157.131.132.109    Exit node's ISP (Sonic.net)         ISP        VPN_EXIT_ISP or ISP
5+   ...                Transit/destination                  TRANSIT    TRANSIT
```

### Root Causes

1. **CGNAT-only VPN detection**: `seenVPNHop` only triggers on CGNAT (100.64.0.0/10), but Tailscale peer IPs can also be regular IPs with Tailscale hostnames
2. **No hostname-based detection**: The classifier doesn't use rDNS hostnames like `*.ts.net` or `*.tailscale.com` to identify VPN hops
3. **No position-aware classification**: Private IPs appearing *after* a transition through public space should be classified differently than pre-public private IPs

---

## Proposed Solution

### 1. Keep Existing Categories (No New Categories Needed)

The existing `HopCategory` enum is sufficient:

```swift
public enum HopCategory: String, Sendable, Codable {
  case local = "LOCAL"                 // Pre-VPN private IPs (home LAN)
  case isp = "ISP"                     // ISP network
  case transit = "TRANSIT"             // Transit networks
  case destination = "DESTINATION"     // Destination network
  case unknown = "UNKNOWN"             // No reply
  case vpn = "VPN"                     // VPN tunnel/overlay AND exit node network
}
```

**Rationale**: From the user's perspective, everything after entering the VPN tunnel is "VPN territory":
- The VPN overlay (CGNAT, peer IPs)
- The exit node's LAN (private IPs at remote location)
- The exit node's upstream ISP

If any of these have issues, the user action is the same: **change exit node, disable VPN, or contact VPN provider**. Adding granular categories like `VPN_EXIT` or `VPN_EXIT_ISP` provides no actionable insight and increases complexity.

**The fix is simpler**: Just ensure all hops after the VPN entry point are classified as `VPN` until we reach public internet that's clearly not VPN infrastructure.

### 2. Enhanced VPN Entry Point Detection

Create a multi-signal approach to detect VPN entry points:

```swift
struct VPNEntryDetector {
  /// Known VPN overlay network hostnames
  static let vpnHostnamePatterns: [String] = [
    ".ts.net",           // Tailscale MagicDNS
    ".tailscale.com",    // Tailscale public relays
    ".wg.run",           // WireGuard hosting
    ".mullvad.net",      // Mullvad VPN
    ".nordvpn.com",      // NordVPN
    ".expressvpn.com",   // ExpressVPN
    // Add more as discovered
  ]

  /// Detect if a hop is a VPN entry point
  static func isVPNEntryPoint(
    ip: String,
    hostname: String?,
    isCGNAT: Bool,
    context: VPNContext
  ) -> Bool {
    // Signal 1: CGNAT in VPN context
    if isCGNAT && context.isVPNTrace { return true }

    // Signal 2: Hostname matches known VPN patterns
    if let hostname = hostname?.lowercased() {
      for pattern in vpnHostnamePatterns {
        if hostname.hasSuffix(pattern) { return true }
      }
    }

    // Signal 3: IP is in VPNContext's known local IPs
    if context.vpnLocalIPs.contains(ip) { return true }

    return false
  }
}
```

### 3. Simplified State Machine for Classification

Replace the current `seenVPNHop` boolean with a cleaner two-state model:

```swift
enum ClassificationState {
  case preVPN           // Haven't entered VPN yet
  case inVPN            // Inside VPN (everything after entry point)
}
```

**State Transitions:**

```
preVPN ──[VPN entry detected]──> inVPN ──[stays in VPN until destination]
```

**Key insight**: Once we enter the VPN, we stay "in VPN" for classification purposes. The exit node's LAN, its ISP, transit networks - all get classified as `VPN` because from the user's perspective, these are all under the VPN's purview.

### 4. Updated Classification Algorithm

```swift
func classify(hops: [TraceHop], context: VPNContext) -> [ClassifiedHop] {
  var inVPN = false
  var results: [ClassifiedHop] = []

  for hop in hops {
    guard let ip = hop.ip else {
      results.append(ClassifiedHop(hop: hop, category: .unknown))
      continue
    }

    let isPrivate = isPrivateIPv4(ip)
    let isCGNAT = isCGNATIPv4(ip)
    let hostname = hop.hostname

    // Check for VPN entry point
    let isVPNEntry = context.isVPNTrace && VPNEntryDetector.isVPNEntryPoint(
      ip: ip, hostname: hostname, isCGNAT: isCGNAT, context: context
    )

    if isVPNEntry {
      inVPN = true
    }

    // Classification logic
    if inVPN {
      // Everything after VPN entry is VPN territory
      // Exception: final destination keeps its DESTINATION category
      if hop.ip == destinationIP {
        results.append(ClassifiedHop(hop: hop, category: .destination))
      } else {
        results.append(ClassifiedHop(hop: hop, category: .vpn))
      }
    } else {
      // Pre-VPN classification (unchanged from current logic)
      if isPrivate {
        results.append(ClassifiedHop(hop: hop, category: .local))
      } else if isCGNAT {
        results.append(ClassifiedHop(hop: hop, category: .isp))  // ISP CGNAT, not VPN
      } else {
        results.append(classifyByASN(hop, context: context))
      }
    }
  }

  return results
}
```

### 5. Enhanced VPNContext

Expand `VPNContext` to carry more information:

```swift
public struct VPNContext: Sendable {
  public let traceInterface: String?
  public let isVPNTrace: Bool
  public let vpnLocalIPs: Set<String>

  // NEW: Known VPN provider for better detection
  public let vpnProvider: VPNProvider?

  // NEW: Exit node information (if known)
  public let exitNodeIP: String?
  public let exitNodeHostname: String?

  public enum VPNProvider: String, Sendable {
    case tailscale
    case wireguard
    case openvpn
    case ipsec
    case other
  }
}
```

### 6. Hostname Pattern Database

Create an extensible system for VPN hostname detection:

```swift
public struct VPNHostnamePatterns {
  /// Built-in patterns for common VPN providers
  public static let builtin: [VPNProvider: [String]] = [
    .tailscale: [".ts.net", ".tailscale.com", "tailscale-"],
    .wireguard: [".wg.run", "wg-"],
    // ... more providers
  ]

  /// User-provided custom patterns
  public var custom: [String] = []

  /// Check if hostname matches any VPN pattern
  public func matches(_ hostname: String) -> Bool {
    let lower = hostname.lowercased()

    for patterns in Self.builtin.values {
      for pattern in patterns {
        if lower.contains(pattern) { return true }
      }
    }

    for pattern in custom {
      if lower.contains(pattern.lowercased()) { return true }
    }

    return false
  }
}
```

---

## Implementation Plan

### Phase 1: Core Algorithm Fix (Priority: High)

**Goal**: Fix the immediate bug where exit node LANs are classified as LOCAL

**Changes**:
1. Add `vpnExit` category to `HopCategory` enum
2. Implement state machine in `TraceClassifier.classify()`
3. Add hostname-based VPN detection for Tailscale (`.ts.net`)
4. Update hole-filling to handle new category

**Files**:
- `Sources/SwiftFTR/Segmentation.swift`
- `Sources/SwiftFTR/Utils.swift` (add hostname matching)

**Tests**:
- Add test case for Tailscale exit node trace
- Add test case for hostname-based VPN detection
- Verify backward compatibility with non-VPN traces

### Phase 2: Enhanced Detection (Priority: Medium)

**Goal**: Improve VPN detection reliability across providers

**Changes**:
1. Create `VPNHostnamePatterns` with extensible pattern database
2. Enhance `VPNContext` with provider and exit node info
3. Add `VPN_EXIT_ISP` category for exit node's ISP (optional)

**Files**:
- `Sources/SwiftFTR/VPNDetection.swift` (new file)
- `Sources/SwiftFTR/Segmentation.swift`

**Tests**:
- Add tests for multiple VPN providers
- Test hostname pattern matching
- Test provider-specific detection

### Phase 3: NWX Integration (Priority: Medium)

**Goal**: Update NWX to use new classifications

**Changes**:
1. Update `TopologyDataProvider` to handle `vpnExit` category
2. Suppress alerts for packet loss in `VPN_EXIT` segment
3. Update UI to show "VPN Exit Network" segment

**Files** (in NWX repo):
- `NWX/Views/Topology/TopologyDataProvider.swift`
- `NWX/Models/TopologySegmentData.swift`
- `NWX/ImpliedImpairmentAnalyzer.swift`

---

## Test Cases

### Test 1: Tailscale Exit Node Trace

```swift
func testTailscaleExitNodeClassification() {
  let hops = [
    TraceHop(ttl: 1, ip: "10.35.0.1", hostname: nil),           // Local gateway
    TraceHop(ttl: 2, ip: "100.120.205.29", hostname: "trogdor.tail3b5a2.ts.net"),  // Tailscale peer
    TraceHop(ttl: 3, ip: "192.168.1.1", hostname: "unifi.localdomain"),  // Exit node LAN
    TraceHop(ttl: 4, ip: "157.131.132.109", hostname: "lo0.bras2.rdcyca01.sonic.net"),  // Exit ISP
    TraceHop(ttl: 5, ip: "1.1.1.1", hostname: "one.one.one.one"),  // Destination
  ]

  let context = VPNContext(traceInterface: "utun15", isVPNTrace: true, vpnLocalIPs: [])
  let classified = TraceClassifier.classify(hops, destinationIP: "1.1.1.1", context: context)

  #expect(classified[0].category == .local)       // Physical gateway (pre-VPN)
  #expect(classified[1].category == .vpn)         // Tailscale peer (VPN entry via hostname)
  #expect(classified[2].category == .vpn)         // Exit node's LAN (VPN territory)
  #expect(classified[3].category == .vpn)         // Exit node's ISP (VPN territory)
  #expect(classified[4].category == .destination) // Final destination
}
```

### Test 2: CGNAT-Only VPN (No Hostname)

```swift
func testCGNATOnlyVPN() {
  let hops = [
    TraceHop(ttl: 1, ip: "192.168.1.1", hostname: nil),   // Local
    TraceHop(ttl: 2, ip: "100.64.0.1", hostname: nil),    // CGNAT = VPN entry
    TraceHop(ttl: 3, ip: "10.0.0.1", hostname: nil),      // Private after CGNAT (VPN)
    TraceHop(ttl: 4, ip: "8.8.8.8", hostname: nil),       // Public (still VPN territory)
  ]

  let context = VPNContext.forInterface("utun0")
  let classified = TraceClassifier.classify(hops, destinationIP: "8.8.8.8", context: context)

  #expect(classified[0].category == .local)
  #expect(classified[1].category == .vpn)
  #expect(classified[2].category == .vpn)
  #expect(classified[3].category == .destination)
}
```

### Test 3: Non-VPN Trace (Backward Compatibility)

```swift
func testNonVPNTraceUnchanged() {
  let hops = [
    TraceHop(ttl: 1, ip: "192.168.1.1", hostname: nil),   // Local
    TraceHop(ttl: 2, ip: "100.64.0.1", hostname: nil),    // ISP CGNAT (NOT VPN)
    TraceHop(ttl: 3, ip: "203.0.113.1", hostname: nil),   // Public
  ]

  // No VPN context
  let context = VPNContext(traceInterface: "en0", isVPNTrace: false, vpnLocalIPs: [])
  let classified = TraceClassifier.classify(hops, context: context)

  #expect(classified[0].category == .local)
  #expect(classified[1].category == .isp)    // CGNAT without VPN = ISP
  #expect(classified[2].category == .isp)    // or .transit based on ASN
}
```

---

## Risks and Mitigations

### Risk 1: Hostname Lookup Latency
**Concern**: Waiting for rDNS to detect VPN hops could slow classification.

**Mitigation**:
- Classification runs *after* trace completes (rDNS already done)
- Hostname is optional signal; CGNAT and interface detection still work without it

### Risk 2: False Positives on Hostname Patterns
**Concern**: Non-VPN services might have similar hostnames.

**Mitigation**:
- Only use hostname detection when `isVPNTrace` is already true from interface
- Patterns are suffix-based (`.ts.net`) not substring-based
- Keep pattern list conservative and well-tested

### Risk 3: Backward Compatibility
**Concern**: Existing code might depend on current classification behavior.

**Mitigation**:
- New `vpnExit` category only appears when VPN context is active
- Non-VPN traces produce identical output to current implementation
- Extensive test coverage for both paths

---

## Success Criteria

1. **Bug Fixed**: `192.168.1.1` at Tailscale exit node classified as `VPN_EXIT`, not `LOCAL`
2. **No False Positives**: Non-VPN traces with CGNAT still classify correctly as `ISP`
3. **Hostname Detection**: Tailscale peers with `.ts.net` hostnames detected as VPN hops
4. **NWX Integration**: No alerts for packet loss in `VPN_EXIT` segment
5. **Test Coverage**: All new code paths have unit tests
6. **Performance**: No measurable latency increase in classification

---

## Open Questions

1. **How to handle nested VPNs (VPN-over-VPN)?**
   - Current proposal assumes single VPN layer
   - Could extend state machine for multi-layer tunnels
   - *Recommendation*: Defer until we see real-world demand

2. **Should hostname patterns be configurable via NWX settings?**
   - Useful for enterprise VPNs with custom hostnames
   - Adds configuration complexity
   - *Recommendation*: Start with hardcoded patterns for common VPNs, add config later if needed

3. **What if VPN entry isn't detected (no hostname, no CGNAT)?**
   - Some VPN configurations might not have obvious entry markers
   - Could use ASN-based detection (known VPN provider ASNs)
   - *Recommendation*: Interface-based detection (`utun*`) as primary signal is sufficient for most cases

---

## Appendix: Current vs Proposed Classification

### Before (Current Implementation)

| TTL | IP | Hostname | Category | Issue |
|-----|-----|----------|----------|-------|
| 1 | 10.35.0.1 | - | LOCAL | ✓ Correct |
| 2 | 100.120.205.29 | trogdor.tail3b5a2.ts.net | ISP | ✗ Should be VPN |
| 3 | 192.168.1.1 | unifi.localdomain | LOCAL | ✗ Should be VPN |
| 4 | 157.131.132.109 | lo0.bras2...sonic.net | ISP | ✗ Should be VPN |
| 5 | 1.1.1.1 | one.one.one.one | DESTINATION | ✓ Correct |

**User sees**: "Network Equipment Dropping Packets" alert blaming local gateway when the issue is at the VPN exit node's LAN.

### After (Proposed Implementation)

| TTL | IP | Hostname | Category | Note |
|-----|-----|----------|----------|------|
| 1 | 10.35.0.1 | - | LOCAL | Physical gateway (pre-VPN) |
| 2 | 100.120.205.29 | trogdor.tail3b5a2.ts.net | VPN | VPN entry detected via `.ts.net` |
| 3 | 192.168.1.1 | unifi.localdomain | VPN | VPN territory (exit node LAN) |
| 4 | 157.131.132.109 | lo0.bras2...sonic.net | VPN | VPN territory (exit node ISP) |
| 5 | 1.1.1.1 | one.one.one.one | DESTINATION | Final destination |

**User sees**: "VPN Issues Detected" alert correctly attributing the problem to the VPN, with actionable advice to change exit node or disable VPN.

---

## Summary of Simplified Approach

The key insight from review: **users don't need granular VPN sub-categories**. Everything after entering the VPN tunnel is "VPN's responsibility" from a troubleshooting perspective.

**Changes required**:
1. Add hostname-based VPN entry detection (`.ts.net`, etc.)
2. Once VPN entry detected, classify all subsequent hops as `VPN` (except final destination)
3. No new enum cases needed - existing `HopCategory.vpn` is sufficient

**Files to modify**:
- `Sources/SwiftFTR/Segmentation.swift` - Update classification logic
- `Sources/SwiftFTR/Utils.swift` - Add hostname pattern matching
- `Tests/SwiftFTRTests/VPNClassificationTests.swift` - Add new test cases

**Estimated effort**: ~2-4 hours for an agent to implement and test.

---

*Document created: 2024-12-03*
*Author: Claude (with David E. Weekly)*
*Status: Proposal - Ready for Implementation*
