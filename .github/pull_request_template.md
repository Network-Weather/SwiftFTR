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
swift format lint -r Sources Tests
PTR_SKIP_STUN=1 swift test -c debug
swift build -c release && .build/release/swift-ftr -w 1.5 8.8.8.8
```

## Checklist
- [ ] Formatting: `swift format lint -r Sources Tests` passes
- [ ] Tests: `PTR_SKIP_STUN=1 swift test` passes (no network dependency)
- [ ] Public APIs documented (DocC / Xcode Quick Help)
- [ ] README / docs updated if behavior or flags changed
- [ ] No secrets or tokens added

