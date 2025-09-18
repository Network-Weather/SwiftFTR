# Contributing to SwiftFTR

Thanks for your interest in improving SwiftFTR! This guide describes how to set up your environment, propose changes, and keep contributions consistent and easy to review.

## Quick Start
- Requirements: macOS 13+, Xcode 26+ (Swift 6.2+), GitHub CLI (optional).
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
   swift format lint -r Sources Tests
   swift test -c debug
   ```
4. Open a Pull Request. The CI will run format, build, tests, docs.

## Formatting
- We enforce Swift formatting in CI using `swift format` (Swift 6.2 toolchain).
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
  swift package --allow-writing-to-directory docc \
    generate-documentation --target SwiftFTR \
    --output-path docc --transform-for-static-hosting
  open docc/index.html
  ```
- Docs auto‑publish to GitHub Pages on pushes to `main`: https://swiftftr.networkweather.com/
- Manual documentation is maintained in the `docs/` directory
- Generated DocC output goes to `docc/` (gitignored)

## Testing
- Unit tests should not depend on network access. Use fakes/mocks.
- For code paths that perform DNS/WHOIS/STUN, prefer injectable resolvers via configuration. Use `SwiftFTRConfig(publicIP: ...)` to bypass STUN in tests.
- Add tests next to the code they exercise under `Tests/SwiftFTRTests`.

## Concurrency Guidelines
- Keep single-threaded entry points (CLI, integration harnesses) on the main actor via `-Xswiftc -default-isolation -Xswiftc MainActor` to honor Swift 6.2's default isolation recommendations.
- Mark synchronous helpers that can execute in parallel with `@concurrent` so reviewers and the compiler understand intent before adding new async work.
- The package manifest enables the `NonisolatedNonsendingByDefault` and `InferIsolatedConformances` upcoming features; keep new code free of diagnostics under these stricter Sendable checks.
- Skim the Swift team’s "[Swift 6.2 Released](https://www.swift.org/blog/swift-6.2-released/)" blog post when adding concurrency-heavy features—it captures the rationale behind these defaults.

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

### Release Checklist
Before creating a new release, ensure:
1. [ ] Update version in `Package.swift` (if applicable)
2. [ ] Update `CHANGELOG.md` with release notes
3. [ ] Update `docs/development/ROADMAP.md` to reflect current version
4. [ ] Update any version references in documentation
5. [ ] Run tests: `swift test`
6. [ ] Build release binary: `swift build -c release`
7. [ ] Test CLI binary: `.build/release/swift-ftr --version`

### Creating a Release
1. Commit all changes and push to `main`
2. Create and push a version tag:
   ```bash
   git tag v0.X.Y
   git push origin v0.X.Y
   ```
3. The automated release workflow will:
   - Build the release binary with attestation
   - Generate SBOM (Software Bill of Materials)
   - Create GitHub Release with auto-generated notes
   - **Automatically update DocC documentation on GitHub Pages**
4. Verify the release:
   - Check GitHub Releases page for binaries and checksums
   - Verify DocC updated at https://swiftftr.networkweather.com/

### Manual Release (if needed)
- Actions → "Release (manual)" → Run workflow with `ref = vX.Y.Z`
- This will trigger the same process as tag-based releases

### Post-Release
- Announce the release if it contains significant features
- Update any dependent projects or documentation

## Security
If you discover a vulnerability, please open a private security advisory or email the maintainer instead of filing a public issue.

## License
By contributing, you agree that your contributions will be licensed under the repository’s MIT license.

## Code of Conduct
This project follows a Code of Conduct. Please read and follow CODE_OF_CONDUCT.md when participating in discussions and contributions.
