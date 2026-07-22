# Contributing to SwiftFTR

Thanks for your interest in improving SwiftFTR! This guide describes how to set up your environment, propose changes, and keep contributions consistent and easy to review.

## Quick Start
- Requirements: macOS 13+, Xcode 16.4+ (Swift 6.1+), GitHub CLI (optional).
- Build & test:
  ```bash
  swift build -c debug
  swift test -c debug
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
   swift format lint --strict -r Sources Tests
   swift test -c debug
   ```
4. Open a Pull Request. The CI will run format, build, tests, docs.

## Formatting
- We enforce Swift formatting in CI using `swift format` (Swift 6 toolchain).
- See [docs/development/CODE_STYLE.md](docs/development/CODE_STYLE.md) for naming conventions and intentional exceptions (JSON API compatibility, external integration requirements).
- Locally, you can install the git pre‑push hook once:
  ```bash
  git config core.hooksPath .githooks
  ```
  Then pushes will be blocked if formatting fails.
- To auto‑format in place (optional):
  ```bash
  swift format format --in-place -r Sources Tests
  ```

## Documentation
- Public APIs should have Swift doc comments (///) suitable for Xcode Quick Help.
- Generate and preview DocC locally:
  ```bash
  swift package --allow-writing-to-directory docc \
    generate-documentation --target SwiftFTR \
    --output-path docc --transform-for-static-hosting \
    --warnings-as-errors
  open docc/index.html
  ```
- Docs auto‑publish to GitHub Pages on pushes to `main`: https://swiftftr.networkweather.com/
- Manual documentation is maintained in the `docs/` directory
- Generated DocC output goes to `docc/` (gitignored)

## Testing
- Unit tests should not depend on network access. Use fakes/mocks.
- For code paths that perform DNS/WHOIS/STUN, prefer injectable resolvers. Use `SwiftFTRConfig(publicIP: ...)` to bypass discovery in classified-trace or multipath tests.
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
  - `swift format lint --strict -r Sources Tests` passes
  - `SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test` passes offline
  - Public symbols have reasonable documentation

## Releases (maintainers)

### Release Checklist
Before creating a new release, ensure:
1. [ ] Update `Sources/SwiftFTR/Version.swift`; `Package.swift` has no package-version field
2. [ ] Consolidate `CHANGELOG.md` into dated, adopter-facing release notes
3. [ ] Update the SwiftPM version and migration links in `README.md`
4. [ ] Update `ROADMAP.md` only when the release actually completes or reprioritizes work
5. [ ] Run the offline test suite: `SKIP_NETWORK_TESTS=1 PTR_SKIP_STUN=1 swift test`
6. [ ] Run debug/release builds, external-consumer builds, DocC, and the API compatibility check
7. [ ] Run the release's documented live IPv4/IPv6 matrix on the final mainline commit
8. [ ] Test the CLI version in both pretty and JSON output

### Creating a Release
1. Merge the release-preparation PR and wait for main CI and documentation deployment
2. Create an annotated tag on the release-preparation merge commit and push it:
   ```bash
   git tag -a v0.X.Y <merge-commit> -m "v0.X.Y"
   git push origin v0.X.Y
   ```
3. The automated release workflow will:
   - Build the release binary with attestation
   - Generate SBOM (Software Bill of Materials)
   - Create GitHub Release with auto-generated notes
4. Replace the generated GitHub notes with the curated `CHANGELOG.md` section, then verify:
   - Check GitHub Releases page for binaries and checksums
   - Verify the build attestation and that the checksum matches the binary
   - Verify DocC updated at https://swiftftr.networkweather.com/
   - Build a throwaway consumer using the published remote tag

### Manual Release (if needed)
- Actions → "Release (attested + SBOM)" → Run workflow with `tag = vX.Y.Z`
- The annotated tag must already exist and its CLI version must match; documentation deploys from
  `main`

### Post-Release
- Announce the release if it contains significant features
- Update any dependent projects or documentation

## Security
If you discover a vulnerability, please open a private security advisory or email the maintainer instead of filing a public issue.

## License
By contributing, you agree that your contributions will be licensed under the repository’s MIT license.

## Code of Conduct
This project follows a Code of Conduct. Please read and follow CODE_OF_CONDUCT.md when participating in discussions and contributions.
