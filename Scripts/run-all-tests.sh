#!/bin/bash

# Comprehensive test runner script for SwiftFTR
# This script runs all tests and generates coverage reports

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

cd "$PROJECT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🧪 SwiftFTR Comprehensive Test Suite"
echo "===================================="
echo ""

# Function to run a test section
run_test_section() {
    local section_name=$1
    local command=$2
    
    echo -e "${YELLOW}Running: ${section_name}${NC}"
    if eval "$command"; then
        echo -e "${GREEN}✓ ${section_name} passed${NC}\n"
        return 0
    else
        echo -e "${RED}✗ ${section_name} failed${NC}\n"
        return 1
    fi
}

# Track failures
FAILED_TESTS=()

# 1. Clean and build
echo "📦 Building project..."
swift build --disable-sandbox 2>&1 | tail -5
echo ""

# 2. Run unit tests with coverage
if ! run_test_section "Unit Tests" "swift test --enable-code-coverage"; then
    FAILED_TESTS+=("Unit Tests")
fi

# 3. Run integration tests
if ! run_test_section "Integration Tests (Built-in)" ".build/debug/integrationtest"; then
    FAILED_TESTS+=("Integration Tests")
fi

# 4. Test CLI tool
echo -e "${YELLOW}Testing CLI Tool${NC}"
if .build/debug/swift-ftr --help > /dev/null 2>&1; then
    echo "  ✓ Help command works"
else
    echo "  ✗ Help command failed"
    FAILED_TESTS+=("CLI Help")
fi

if .build/debug/swift-ftr 1.1.1.1 -m 3 -t 1.0 > /dev/null 2>&1; then
    echo "  ✓ Basic trace works"
else
    echo "  ✗ Basic trace failed"
    FAILED_TESTS+=("CLI Trace")
fi

if .build/debug/swift-ftr --json 8.8.8.8 -m 3 > /dev/null 2>&1; then
    echo "  ✓ JSON output works"
else
    echo "  ✗ JSON output failed"
    FAILED_TESTS+=("CLI JSON")
fi
echo ""

# 5. Test as external package
echo -e "${YELLOW}Testing as External Package${NC}"
if [ -d "test-external-package" ]; then
    cd test-external-package
    if swift build > /dev/null 2>&1; then
        echo "  ✓ External package builds"
        if swift run > /dev/null 2>&1; then
            echo "  ✓ External package runs"
        else
            echo "  ✗ External package run failed"
            FAILED_TESTS+=("External Package Run")
        fi
    else
        echo "  ✗ External package build failed"
        FAILED_TESTS+=("External Package Build")
    fi
    cd ..
else
    echo "  ⚠️  External package test not found"
fi
echo ""

# 6. Generate coverage report
echo -e "${YELLOW}Generating Coverage Report${NC}"
if [ -f ".build/debug/SwiftFTRPackageTests.xctest/Contents/MacOS/SwiftFTRPackageTests" ]; then
    xcrun llvm-cov report \
        .build/debug/SwiftFTRPackageTests.xctest/Contents/MacOS/SwiftFTRPackageTests \
        -instr-profile .build/debug/codecov/default.profdata \
        -ignore-filename-regex="Tests|.build" 2>/dev/null || echo "  ⚠️  Coverage report generation failed"
    
    # Generate detailed HTML report
    xcrun llvm-cov show \
        .build/debug/SwiftFTRPackageTests.xctest/Contents/MacOS/SwiftFTRPackageTests \
        -instr-profile .build/debug/codecov/default.profdata \
        -format=html \
        -output-dir=coverage-report \
        -ignore-filename-regex="Tests|.build" 2>/dev/null && \
        echo "  ✓ HTML coverage report generated in coverage-report/"
else
    echo "  ⚠️  Test binary not found for coverage"
fi
echo ""

# 7. Performance benchmark
echo -e "${YELLOW}Running Performance Benchmark${NC}"
cat > /tmp/benchmark.swift << 'EOF'
import SwiftFTR
import Foundation

@main
struct Benchmark {
    static func main() async {
        let config = SwiftFTRConfig(maxHops: 5, maxWaitMs: 1000)
        let tracer = SwiftFTR(config: config)
        
        print("  Running 5 traces for benchmark...")
        var times: [TimeInterval] = []
        
        for i in 1...5 {
            let start = Date()
            if let _ = try? await tracer.trace(to: "1.1.1.1") {
                let elapsed = Date().timeIntervalSince(start)
                times.append(elapsed)
                print("    Run \(i): \(String(format: "%.3f", elapsed))s")
            }
        }
        
        if !times.isEmpty {
            let avg = times.reduce(0, +) / Double(times.count)
            print("  Average: \(String(format: "%.3f", avg))s")
        }
    }
}
EOF

if swiftc /tmp/benchmark.swift -I .build/debug -L .build/debug -lSwiftFTR -o /tmp/benchmark 2>/dev/null; then
    /tmp/benchmark || echo "  ⚠️  Benchmark failed"
else
    echo "  ⚠️  Could not compile benchmark"
fi
rm -f /tmp/benchmark.swift /tmp/benchmark
echo ""

# 8. Summary
echo "===================================="
echo "📊 Test Summary"
echo "===================================="

if [ ${#FAILED_TESTS[@]} -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}❌ Failed tests:${NC}"
    for test in "${FAILED_TESTS[@]}"; do
        echo "  - $test"
    done
    exit 1
fi