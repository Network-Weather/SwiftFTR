# Contributing to SwiftFTR

Thanks for your interest in improving SwiftFTR! This guide describes how to set up your environment, propose changes, and keep contributions consistent and easy to review.

## Quick Start
- Requirements: macOS 13+, Xcode 16 (Swift 6) or Xcode 15.4 (Swift 5.10+), GitHub CLI (optional).
- Build & test:
  ```bash
  swift build -c debug
  PTR_SKIP_STUN=1 swift test -c debug
  ```
- Run CLI:
  ```bash
  swift build -c release
  .build/release/swift-ftr --help
  ```

## Dev Workflow
1. Fork the repo and create a feature branch from `main`.
2. Make changes with focused commits and clear messages (see Commit Style).
3. Ensure formatting and tests pass locally:
   ```bash
   swift format lint -r Sources Tests
   PTR_SKIP_STUN=1 swift test -c debug
   ```
4. Open a Pull Request. The CI will run format, build, tests, docs.

## Formatting
- We enforce Swift formatting in CI using `swift format` (Swift 6 toolchain).
- Locally, you can install the git pre‑push hook once:
  ```bash
  git config core.hooksPath .githooks
  ```
  Then pushes will be blocked if formatting fails.
- To auto‑format in place (optional):
  ```bash
  swift format -i -r Sources Tests
  ```

## Documentation
- Public APIs should have Swift doc comments (///) suitable for Xcode Quick Help.
- Generate and preview DocC locally:
  ```bash
  swift package --allow-writing-to-directory docs \
    generate-documentation --target SwiftFTR \
    --output-path docs --transform-for-static-hosting
  open docs/index.html
  ```
- Docs auto‑publish to GitHub Pages on pushes to `main`: https://swiftftr.networkweather.com/

## Testing
- Unit tests should not depend on network access. Use fakes/mocks.
- For code paths that perform DNS/WHOIS/STUN, prefer injectable resolvers and guard with env vars. CI sets `PTR_SKIP_STUN=1` to ensure isolation.
- Add tests next to the code they exercise under `Tests/SwiftFTRTests`.

## Commit Style
- Conventional commits preferred:
  - `feat(api): add TraceResult.duration`
  - `fix(tracer): use monotonic clock in receive loop`
  - `docs(docc): expand TraceClassifier examples`
  - `ci(fmt): enforce swift format lint in CI`
- Keep commits focused and descriptive. Squash on merge if there are many WIP commits.

## PR Guidelines
- Describe the problem and solution. Include screenshots or sample output where helpful.
- Note any user‑visible changes: new flags, breaking API changes, or behavior shifts.
- Ensure:
  - `swift format lint -r Sources Tests` passes
  - `PTR_SKIP_STUN=1 swift test` passes
  - Public symbols have reasonable documentation

## Releases (maintainers)
- Tag a version (e.g., `v0.1.0`) on `main`.
- Run the manual release workflow if needed (attestation + SBOM):
  - Actions → "Release (manual)" → Run workflow with `ref = vX.Y.Z`.
- Artifacts: binary, SHA‑256 checksum, CycloneDX SBOM, build provenance attestation.

## Security
If you discover a vulnerability, please open a private security advisory or email the maintainer instead of filing a public issue.

## License
By contributing, you agree that your contributions will be licensed under the repository’s MIT license.

