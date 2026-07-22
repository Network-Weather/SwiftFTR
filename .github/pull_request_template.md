## Summary

Describe the problem and your solution. Include screenshots or sample CLI output when helpful.

## Type of change
- [ ] feat (new feature)
- [ ] fix (bug fix)
- [ ] docs (documentation only)
- [ ] refactor/chore (non‑functional changes)

## Changes
- 

## Testing
Describe how you tested the change locally.

Example commands:
```bash
swift format lint --strict -r Sources Tests
SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test -c debug
swift build -c release
.build/release/swift-ftr trace --timeout 1.5 8.8.8.8
```

## Checklist
- [ ] Formatting: `swift format lint --strict -r Sources Tests` passes
- [ ] Tests: `SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test` passes offline
- [ ] Public APIs documented (DocC / Xcode Quick Help)
- [ ] README / docs updated if behavior or flags changed
- [ ] No secrets or tokens added
- [ ] I have read and agree to follow the project's Code of Conduct (CODE_OF_CONDUCT.md)
