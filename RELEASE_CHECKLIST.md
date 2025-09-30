# SwiftFTR 0.5.0 Release Checklist

## Pre-Release Verification

### Code Quality
- [x] All tests passing (44 tests across 12 suites)
- [x] New code formatted with `swift format`
- [x] No Swift 6 compiler warnings
- [x] No breaking changes to existing public API

### Documentation
- [x] CHANGELOG.md updated with v0.5.0 release notes
- [x] README.md updated with "New in v0.5.0" section
- [x] ROADMAP.md updated to reflect v0.5.0 as current version
- [x] DocC documentation created (Ping.md, Multipath.md)
- [x] EXAMPLES.md updated with new feature examples
- [x] Temporary plan file (SWIFTFTR_MULTIPATH_PLAN.md) removed

### Feature Completeness
- [x] Ping API implemented with PingExecutor actor
- [x] Multipath discovery implemented with MultipathDiscovery actor
- [x] Flow identifier control via optional flowID parameter
- [x] CLI ping subcommand with JSON output
- [x] CLI multipath subcommand with JSON output
- [x] Comprehensive unit tests (44 tests total)
- [x] Integration tests for real network validation

### Performance
- [ ] Performance profiling (optional - can defer)
- [x] All integration tests complete in reasonable time (<20s)

## Release Process

### 1. Final Code Review
```bash
# Review all changes
git diff origin/main...feature/multipath-0.5.0

# Ensure branch is up to date
git fetch origin
git rebase origin/main
```

### 2. Run Full Test Suite
```bash
# Format check
swift format lint -r Sources Tests

# Build release
swift build -c release

# Run all tests with STUN disabled
PTR_SKIP_STUN=1 swift test -c debug

# Test CLI commands
.build/release/swift-ftr ping 1.1.1.1 -c 5
.build/release/swift-ftr multipath 8.8.8.8 --flows 5
.build/release/swift-ftr trace 1.1.1.1
```

### 3. Build DocC Documentation
```bash
swift package --allow-writing-to-directory docs \
  generate-documentation --target SwiftFTR \
  --output-path docs --transform-for-static-hosting --hosting-base-path SwiftFTR

# Verify documentation builds without errors
open docs/index.html
```

### 4. Create Release PR
```bash
# Push feature branch
git push origin feature/multipath-0.5.0

# Create PR via GitHub CLI
gh pr create --base main --head feature/multipath-0.5.0 \
  --title "Release v0.5.0: Ping and Multipath Discovery" \
  --body "$(cat <<'EOF'
## SwiftFTR v0.5.0 - Ping and Multipath Discovery

### Major Features
- **Ping API**: ICMP echo monitoring with comprehensive statistics
- **Multipath Discovery**: Dublin Traceroute-style ECMP path enumeration
- **Flow Identifier Control**: Optional flow ID for reproducible traces
- **CLI Enhancements**: New `ping` and `multipath` subcommands

### Testing
- All 44 tests passing (12 suites)
- Integration tests validate real network behavior
- No breaking changes to existing API

### Documentation
- CHANGELOG.md updated
- README.md updated with v0.5.0 features
- DocC documentation (Ping.md, Multipath.md)
- EXAMPLES.md with 10 new examples

See CHANGELOG.md for full release notes.
EOF
)"
```

### 5. Merge to Main
```bash
# After PR approval, merge via GitHub UI or CLI
gh pr merge --squash --delete-branch

# Pull merged changes
git checkout main
git pull origin main
```

### 6. Create Release Tag
```bash
# Tag the release
git tag -a v0.5.0 -m "SwiftFTR v0.5.0 - Ping and Multipath Discovery"

# Push tag
git push origin v0.5.0
```

### 7. Create GitHub Release
```bash
# Create release via GitHub CLI
gh release create v0.5.0 \
  --title "v0.5.0 - Ping and Multipath Discovery" \
  --notes "$(cat CHANGELOG.md | sed -n '/^0.5.0/,/^0.4.0/p' | head -n -1)"

# Or create via GitHub UI:
# https://github.com/Network-Weather/SwiftFTR/releases/new
```

### 8. Verify Release
```bash
# Clone fresh copy and test
cd /tmp
git clone https://github.com/Network-Weather/SwiftFTR.git
cd SwiftFTR
git checkout v0.5.0
swift build -c release
PTR_SKIP_STUN=1 swift test
.build/release/swift-ftr ping 1.1.1.1 -c 3
```

### 9. Update Documentation Site
GitHub Actions will automatically rebuild and publish DocC documentation to GitHub Pages when the tag is pushed.

Verify at: https://swiftftr.networkweather.com/

## Post-Release

### Announcements
- [ ] Update NWX project to use SwiftFTR v0.5.0
- [ ] Announce release in relevant channels

### Next Steps
- [ ] Plan v0.5.5 UDP multipath discovery (highest priority)
- [ ] Plan v0.6.0 VPN/Zero Trust network classification
- [ ] Monitor for bug reports and issues

## Notes

### Known Limitations (Documented)
- ICMP multipath may discover fewer paths than UDP-based tools (see ROADMAP.md v0.5.5)
- UDP multipath planned for v0.5.5 to address ECMP router hashing behavior

### Deferred Features
- Enhanced interface selection API (nice-to-have, can add in v0.5.1)
- Detailed performance profiling (can do post-release)
- CLI --version flag (not critical)

### Version Numbering
Swift packages use git tags for versioning, not Package.swift version field. The v0.5.0 tag is the authoritative version marker.