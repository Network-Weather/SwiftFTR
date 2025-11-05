# GitHub Actions Workflows

## Overview

This repository uses GitHub Actions for CI/CD automation. The workflows are designed to be efficient, non-duplicative, and provide comprehensive coverage of testing, releases, and documentation.

## Workflows

### 1. CI (`ci.yml`)
**Triggers:** Push to main, Pull Requests
**Purpose:** Continuous integration for all changes

**Jobs:**
- **format**: Swift format linting (required before merge)
- **macos**: Build debug + release, run tests with network isolation

**Environment Variables:**
- `PTR_SKIP_STUN=1` - Skip STUN tests in CI
- `SKIP_NETWORK_TESTS=1` - Skip tests requiring real network access

### 2. Release (`release.yml`)
**Triggers:**
- Automatic: Push tags matching `v*` (e.g., `v0.7.0`)
- Manual: `workflow_dispatch` with optional inputs

**Inputs (manual only):**
- `ref` (optional): Specific tag/ref to release (defaults to current ref)
- `rebuild_docs` (optional): Trigger docs rebuild after release

**Jobs:**
- **macos-release**:
  - Build release binary for macOS ARM64
  - Generate SHA256 checksums
  - Generate SBOM (CycloneDX format)
  - Create build attestations (OIDC provenance)
  - Create GitHub Release with auto-generated notes

- **rebuild-docs** (conditional):
  - Only runs for manual releases with `rebuild_docs: true`
  - Calls docs.yml workflow to regenerate documentation

**Outputs:**
- `swift-ftr-macos-arm64` - Release binary
- `swift-ftr-macos-arm64.sha256` - Checksum file
- `sbom.cdx.json` - Software Bill of Materials

**Note:** This workflow consolidates the previous `release.yml` and `release-manual.yml` files, eliminating duplication.

### 3. Docs (`docs.yml`)
**Triggers:**
- Push to main branch (when Sources/** or README.md change)
- Manual: `workflow_dispatch`
- Called by: Other workflows via `workflow_call`

**Purpose:** Generate and deploy DocC documentation to GitHub Pages

**Jobs:**
- **build**: Calls `docc-generate.yml` with domain configuration
- **deploy**: Deploys generated docs to GitHub Pages

**Output:** Documentation hosted at https://swiftftr.networkweather.com

### 4. DocC Generate (`docc-generate.yml`)
**Triggers:** `workflow_call` (reusable workflow)

**Purpose:** Generate DocC documentation (used by docs.yml)

**Inputs:**
- `docs-domain`: Custom domain for documentation (default: `swiftftr.networkweather.com`)

**Features:**
- Generates static DocC site
- Creates custom index.html redirect
- Adds CNAME for custom domain
- Adds .nojekyll for GitHub Pages

### 5. Local Integration Tests (`local-integration-tests.yml`)
**Triggers:**
- Manual: `workflow_dispatch`
- Pull Requests: When labeled with `test-integration`

**Purpose:** Run comprehensive integration tests requiring real network access

**Requirements:** Self-hosted runner with labels: `macos`, `traceroute`

**Test Suites:**
- Unit tests (full suite without isolation)
- Real network traces to common destinations
- ASN classification accuracy
- Performance benchmarks
- Concurrent trace stress tests
- External package integration tests
- Code coverage reports

**Note:** These tests DO NOT run on GitHub-hosted runners as they require actual network trace capabilities.

## Workflow Dependencies

```
ci.yml (on every push/PR)
  └─> format check → build → test

release.yml (on tag push or manual)
  └─> build release → attestations → GitHub Release
      └─> [optional] docs.yml → docc-generate.yml

docs.yml (on main push or workflow_call)
  └─> docc-generate.yml → GitHub Pages deploy

local-integration-tests.yml (manual or labeled PR)
  └─> comprehensive real-network testing
```

## Best Practices

### For Contributors
1. **Before pushing:** Ensure `swift format lint -r Sources Tests` passes
2. **For PRs:** CI must pass before merge
3. **For integration tests:** Add `test-integration` label to PR if self-hosted runner available

### For Maintainers
1. **Releases:**
   - Tag from main branch: `git tag -a v0.X.0 -m "Release message"`
   - Push with tags: `git push --follow-tags`
   - Workflow automatically creates GitHub Release

2. **Manual releases:**
   - Use Actions tab → Release workflow → Run workflow
   - Specify ref if releasing older version
   - Enable `rebuild_docs` if documentation needs refresh

3. **Documentation:**
   - Automatically rebuilds on main branch changes to Sources/**
   - Manual trigger available via Actions tab
   - Custom domain: swiftftr.networkweather.com

## Consolidation History

**2025-11-05:** Consolidated `release.yml` and `release-manual.yml` into single workflow
- Eliminated ~70 lines of duplication
- Added optional docs rebuild trigger
- Improved ref handling for both automatic and manual releases
