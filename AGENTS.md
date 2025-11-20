# Repository Guidelines

## Project Structure & Module Organization
SwiftPM’s `Package.swift` wires the `SwiftFTR` library plus CLI. Core tracer logic, DNS helpers, and configuration live in `Sources/SwiftFTR`; the CLI entry point and JSON emitters are in `Sources/swift-ftr`. Tests mirror the layout under `Tests/SwiftFTRTests`. Docs and integration assets sit in `docs/`, generated DocC lives in `docc/`, and fuzzing inputs live in `FuzzCorpus/`. Keep new tooling in a named top-level folder so SwiftPM targets stay predictable.

## Build, Test, and Development Commands
- `swift build -c debug` — fast iteration build for library + CLI; use `-Xswiftc -warnings-as-errors` when validating releases.
- `swift build -c release && .build/release/swift-ftr trace example.com -m 30 -w 1.0` — produce the shipping binary and exercise traceroute.
- `swift test -c debug` — default unit tests; add `PTR_SKIP_STUN=1 swift test` to bypass live STUN lookups in CI.
- `swift format lint -r Sources Tests` (or `swift format -i -r …`) — enforce formatting before pushing.
- `swift package --allow-writing-to-directory docc generate-documentation --target SwiftFTR --output-path docc --transform-for-static-hosting` — regenerate DocC locally.

## Coding Style & Naming Conventions
`swift-format` drives style; keep code camelCase and document public APIs with `///`. The accepted exceptions are snake_case JSON properties in `Sources/swift-ftr/main.swift`, libFuzzer entry points named `LLVMFuzzerTestOneInput`, and double-underscore helpers exposed via `@_spi(Testing)`. Update `docs/development/CODE_STYLE.md` if you introduce any new exception.

## Testing Guidelines
All tests live under `Tests/SwiftFTRTests` and must remain deterministic/offline. Inject resolvers or supply `SwiftFTRConfig(publicIP: ...)` instead of contacting live DNS/STUN endpoints. For CLI changes, cover both library behavior and `.build/debug/swift-ftr` invocation via fixtures. Use sanitizers or fuzz targets (`swift build -c release -Xswiftc -sanitize=address`, `.build/release/icmpfuzz`) when editing packet parsing, and refresh corpora in `FuzzCorpus/` if you add new shapes.

## Commit & Pull Request Guidelines
Favor Conventional Commits (`feat(tracer):`, `fix(dns):`, `docs(docc):`) so automation can generate changelogs. PR descriptions should outline the problem, solution, and any CLI/API impact, plus link issues when possible. Before requesting review, run `swift format lint`, `PTR_SKIP_STUN=1 swift test`, and a release build of the CLI; include sample output for user-visible updates. Squash noisy WIP commits and keep each PR scoped to one concern.

## Security & Configuration Tips
Review `SECURITY.md` before filing vulnerabilities; disclose privately via the listed channel. Keep tokens and ASN data out of git—configure behavior with `SwiftFTRConfig(publicIP:)`, `SwiftFTRConfig(interface:)`, or CLI flags like `--public-ip`. Install `git config core.hooksPath .githooks` for local format enforcement, and keep generated `docc/` output untracked to avoid churn.
