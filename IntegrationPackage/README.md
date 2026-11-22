# Integration Package Test

This package tests SwiftFTR as an external dependency to ensure the library works correctly when imported by other Swift packages.

## Purpose

- Validates that SwiftFTR can be imported as a package dependency
- Tests the public API from an external consumer perspective  
- Ensures all required symbols are properly exported
- Verifies configuration API works without environment variables

## Running Locally

```bash
cd IntegrationPackage
swift build
swift run   # needs ICMP and network access: traces 1.1.1.1 and 8.8.8.8
```

The package depends on SwiftFTR by local path (`../`), so it always tests the working tree.

## CI/CD Integration

The CI workflow (`ci.yml`) builds this package on every push to `main` and every PR, on
GitHub-hosted runners, without running it. The Local Integration Tests workflow
(`local-integration-tests.yml`, self-hosted runner, manual or `test-integration` label) runs it
with `swift run`.

## Test Coverage

1. **Import Test** - Verifies SwiftFTR can be imported
2. **Basic Trace** - Traces 1.1.1.1 and requires that it is reached with responsive hops
3. **Classified Trace** - Classifies a trace to 8.8.8.8 and checks its segments
4. **Configuration API** - Tests SwiftFTRConfig
5. **Error Handling** - Validates error types are accessible

This ensures the library works correctly as a third-party dependency.