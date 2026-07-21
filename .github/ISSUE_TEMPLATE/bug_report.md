---
name: Bug report
about: Help us improve by filing a detailed bug
labels: bug
---

## Description
What happened? What did you expect?

## Environment
- macOS version:
- Xcode / Swift version (`swift --version`):
- SwiftFTR version (commit or tag):

## Repro Steps
Commands/code to reproduce. `PTR_SKIP_STUN` and `SKIP_NETWORK_TESTS` only select tests; they do not
change library or CLI runtime behavior.

```bash
# minimal local example
.build/release/swift-ftr -w 1.0 127.0.0.1
```

## Logs / Output
Paste relevant output. Redact any sensitive info.

## Additional context
Anything else helpful (screenshots, traces, etc.).
