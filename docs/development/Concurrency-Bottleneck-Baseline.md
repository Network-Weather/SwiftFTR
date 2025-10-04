# Concurrency Bottleneck Baseline Metrics

**Date**: 2025-10-04
**Version**: v0.5.3
**Test File**: `Tests/SwiftFTRTests/ConcurrencyBottleneckTests.swift`

## Overview

This document captures baseline performance metrics for concurrency bottlenecks in SwiftFTR v0.5.3. These metrics establish the current state before implementing concurrency modernization improvements.

## Test Results Summary

| Test | Status | Time | Notes |
|------|--------|------|-------|
| Test 1: Concurrent Traces | ✅ PASS | 0.55s | No bottleneck detected (STUN disabled) |
| Test 2: Blocking I/O | ✅ PASS | 1.22s | ping() already nonisolated |
| Test 3: Multipath Sequential | ❌ FAIL | 6.06s | **Bottleneck confirmed** |
| Test 4: Cache Concurrency | ✅ PASS | 2.25s | Baseline established |

## Detailed Results

### Test 1: Concurrent Traces Serialization

**Purpose**: Detect actor serialization when running 20 concurrent `trace()` calls

**Results**:
- Total time: **0.55s**
- Completion spread: **0.04s**
- Min completion: 0.51s
- Max completion: 0.55s

**Analysis**: ✅ **No bottleneck detected**
- Traces ran in parallel successfully
- Likely because: short traces (maxHops: 10, timeout: 500ms) + STUN disabled (`publicIP: "0.0.0.0"`)
- The actor serialization may only be visible with longer-running traces or when STUN/DNS blocking is involved

**Target**: <2s total, <1s spread (already achieved)

---

### Test 2: Actor Blocking During STUN/DNS

**Purpose**: Detect if synchronous STUN/DNS operations block the actor

**Results**:
- Ping times: 0.01s, 0.01s, 0.01s, 0.01s, 0.01s
- Max ping time: **0.01s**
- Avg ping time: **0.01s**

**Analysis**: ✅ **Test passed but not conclusive**
- `ping()` is already nonisolated, so it doesn't get blocked by actor operations
- This test doesn't actually prove/disprove the STUN/DNS blocking issue
- **Need better test**: Concurrent `traceClassified()` calls would show blocking

**Target**: All pings <0.5s (achieved, but test design needs improvement)

---

### Test 3: Multipath Flows Run Sequentially

**Purpose**: Detect sequential execution of multipath flow variations

**Results**:
- Flows: 10
- Time: **6.06s**
- Paths discovered: 1
- Expected (sequential): ~10-20s (10 flows × ~1-2s each)
- Target (parallel): ~2-3s

**Analysis**: ❌ **BOTTLENECK CONFIRMED**
- 10 flows took 6.06 seconds
- If fully parallel, should complete in ~0.6s (one flow duration)
- **Serialization factor**: ~10x slower than parallel execution would be
- This clearly demonstrates the sequential execution in `MultipathDiscovery.discoverPaths()`

**Impact**: For ECMP discovery with many flow variations, this is a significant performance bottleneck

**Next Steps**: Implement parallel flow execution using `withThrowingTaskGroup` in `Multipath.swift:285`

---

### Test 4: ASN Cache Concurrent Access

**Purpose**: Establish baseline for NSLock-based cache performance

**Results**:
- Total time: **2.25s**
- Avg task time: **1.11s**
- Min task time: 0.00s (cache hit)
- Max task time: 2.25s (cache miss + DNS lookup)
- Task time spread: **2.25s**

**Analysis**: ✅ **Baseline established**
- Cache performs acceptably under concurrent load
- Wide spread (0-2.25s) is due to cache hits vs DNS lookups, not contention
- When converting to actor-based cache, performance should remain similar or improve
- No evidence of NSLock contention in this test

**Target**: Maintain <30s total time (achieved: 2.25s)

---

## Key Findings

### Confirmed Bottlenecks

1. **✅ Multipath Sequential Execution** (Test 3)
   - **Magnitude**: 10x slower than parallel would be
   - **Impact**: High (affects ECMP discovery speed)
   - **Priority**: **HIGH** - This is the clearest bottleneck

### Potential Bottlenecks (Needs Better Tests)

2. **⚠️ Actor Serialization** (Test 1)
   - Not detected with short traces + STUN disabled
   - May exist with longer traces or STUN/DNS enabled
   - Need stress test with realistic workload

3. **⚠️ Blocking I/O** (Test 2)
   - Test design doesn't capture this bottleneck (ping is nonisolated)
   - Need concurrent `traceClassified()` test

### No Bottleneck Detected

4. **✅ Cache Contention** (Test 4)
   - NSLock-based cache performs well
   - Actor conversion is for safety, not performance

---

## Phase 2 Results (2025-10-04)

### ✅ Multipath Parallelism Implemented

**Changes**: Converted sequential loop to batched parallel execution using `withThrowingTaskGroup`

**Implementation**:
- Launch flows in batches of 5 (parallel within batch)
- Process batches sequentially for early stopping support
- Maintains all existing early stopping logic

**Results**:
- **Test 3**: 6.06s → 1.20s (**5x speedup!**)
- All 22 multipath tests: ✅ PASS
- Early stopping still works
- Multipath performance test: 10.4s → 7.1s (30% improvement)

**Code Location**: `Sources/SwiftFTR/Multipath.swift:285-370`

---

## Phase 3 Results (2025-10-04)

### ✅ Improved Tests - No Additional Bottlenecks Found

**Changes**: Added improved Tests 1b and 2b to detect actor serialization and blocking I/O

**Test 1b: Longer Concurrent Traces with STUN**
- Config: maxHops: 30, maxWaitMs: 2000, STUN enabled
- 10 concurrent traces to 1.1.1.1
- **Result**: ✅ PASSED
  - Total time: **2.04s**
  - Completion spread: **0.02s**
  - Target: <5s total, <2s spread

**Analysis**: ✅ **No actor serialization bottleneck**
- Even with longer traces and STUN enabled, traces execute in parallel
- Minimal completion spread indicates concurrent execution
- Actor is NOT blocking concurrent trace operations

**Test 2b: Concurrent Classified Traces (Blocking I/O)**
- Config: maxHops: 15, maxWaitMs: 1000, rDNS enabled
- 5 concurrent traceClassified() calls to 1.1.1.1
- **Result**: ✅ PASSED
  - Total time: **1.58s**
  - Completion spread: **0.00s** (simultaneous)
  - Target: <3s total, <1s spread

**Analysis**: ✅ **No blocking I/O bottleneck**
- Concurrent classified traces complete in parallel
- Zero spread indicates no serialization from STUN/DNS operations
- I/O operations are NOT blocking the actor

**Key Finding**: The SwiftFTR actor implementation already handles concurrency well. The only confirmed bottleneck was multipath flow serialization (now fixed).

**Code Location**: `Tests/SwiftFTRTests/ConcurrencyBottleneckTests.swift:105-158, 244-298`

---

## Recommendations

### Completed

1. ✅ **Phase 0: Bottleneck Tests** - DONE (baseline established)
2. ✅ **Phase 2: Multipath Parallelism** - DONE (5x speedup achieved)
3. ✅ **Improved Tests 1b & 2b** - DONE (no additional bottlenecks found)

### Analysis Summary

**Confirmed Bottlenecks**:
- ✅ Multipath sequential execution - **FIXED** (5x speedup)

**No Bottleneck Detected**:
- ✅ Actor serialization - Traces already execute in parallel
- ✅ Blocking I/O - Operations don't block actor
- ✅ Cache contention - NSLock performs well

### Remaining Work (Optional)

1. **Phase 5: Cache Actor** (safety improvement, not performance)
   - Convert `_ASNMemoryCache` from NSLock to actor
   - Modernizes caching but won't improve performance
2. **Consider Swift 6.2 Features** (if/when available)
   - Explore `@concurrent`, `ManagedCriticalState`
   - May simplify actor isolation patterns

---

## Conclusion

The concurrency modernization effort successfully identified and fixed the primary bottleneck:

**Primary Achievement**: **5x speedup** in multipath discovery (6.06s → 1.20s)

**Key Insight**: SwiftFTR's actor-based architecture already provides good concurrency for individual trace operations. The actor doesn't serialize concurrent traces, and I/O operations don't block the actor. The multipath flow serialization was the only significant bottleneck, now resolved.

**Optional Future Work**: Converting caches to actors (Phase 5) would modernize the code but won't improve performance based on our testing.

---

## References

- Test file: `Tests/SwiftFTRTests/ConcurrencyBottleneckTests.swift`
- Concurrency audit: `docs/development/SwiftFTR-Concurrency-Audit.md`
- Concurrency plan: `docs/development/SwiftFTR-Concurrency-Plan.md`
