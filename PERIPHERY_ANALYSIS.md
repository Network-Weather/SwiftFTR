# Periphery Analysis - Unused Code Detection

## Summary
Periphery scan found 26 warnings about potentially unused code in SwiftFTR. These fall into several categories:

## Categories of Findings

### 1. Properties Never Read (8 items)
These properties are assigned values but never used:
- `ASN.swift:13` - `registry` in ASNEntry
- `DNS.swift:22` - `name` in TXTResource
- `DNS.swift:25` - `ttl` in TXTResource  
- `ICMP.swift:18-22` - Properties in EchoReply struct (type, code, checksum, identifier, sequence)
- `ICMP.swift:211` - `source` property
- `Segmentation.swift:47` - `destinationHostname` in ClassifiedTrace
- `Segmentation.swift:50` - `publicHostname` in ClassifiedTrace

**Recommendation**: These are mostly debug/diagnostic fields that could be useful for future features. Consider:
- Keep ICMP fields for potential debugging/logging
- Keep hostname fields as they were just added in v0.3.0
- Consider removing truly unused fields like `registry`

### 2. Public API Not Used Externally (11 items)
Public declarations only used within the module:
- `ASN.swift:72-75` - CachingASNResolver and its methods
- `STUN.swift:8-9` - STUNPublicIP struct

**Recommendation**: These are part of the public API. Keep them as they may be used by library consumers.

### 3. Newly Added but Unused Features (7 items)
Features just added in v0.3.0 that aren't used yet:
- `RDNSCache.swift:77,82,87` - Cache management methods (clear, count, pruneExpired)
- `Traceroute.swift:524,543,550,558` - Network change and cache management APIs

**Recommendation**: Keep these - they're part of the new v0.3.0 API for library users.

### 4. Actually Unused Code (1 item)
- `ASN.swift:92` - CymruWhoisResolver struct is completely unused
- `Traceroute.swift:35` - Deprecated `host` property

**Recommendation**: Remove these.

## Action Items

### Should Remove
1. `CymruWhoisResolver` struct (line 92 in ASN.swift) - completely unused
2. Deprecated `host` property (line 35 in Traceroute.swift) 

### Should Keep
1. ICMP packet fields - useful for debugging and completeness
2. Hostname fields in ClassifiedTrace - just added, may be used by consumers
3. Public API methods - part of the library interface
4. Cache management methods - part of v0.3.0 features

### Consider Removing
1. `registry` field in ASNEntry if truly not needed
2. DNS TXT record fields if not planning to expose them

## Periphery Configuration

For future scans, consider creating a `.periphery.yml` configuration file to:
- Retain public API declarations
- Ignore test support code
- Focus on truly dead code

Example configuration:
```yaml
retain_public: true
targets:
  - SwiftFTR
exclude:
  - "**/*Tests*"
  - "**/Mock*"
```

## Conclusion

Most findings are either:
1. Public API that should be retained for library users
2. Diagnostic fields that provide completeness
3. New v0.3.0 features not yet utilized

Only 2 items should definitely be removed as truly unused code.