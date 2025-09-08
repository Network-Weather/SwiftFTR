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
swift run
```

## CI/CD Integration

This test runs automatically in GitHub Actions as part of the PR test suite. It runs on both cloud runners (build only) and self-hosted runners (full execution).

## Test Coverage

1. **Import Test** - Verifies SwiftFTR can be imported
2. **Basic Trace** - Performs a simple traceroute
3. **Configuration API** - Tests SwiftFTRConfig
4. **Error Handling** - Validates error types are accessible

This ensures the library works correctly as a third-party dependency.