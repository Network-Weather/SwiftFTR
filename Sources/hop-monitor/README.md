# Hop Monitor

A demo CLI tool that continuously monitors all hops along a network path using SwiftFTR.

## Overview

`hop-monitor` performs a traceroute to discover the network path, then continuously pings all discovered hops at 1 ping per second per host, displaying live statistics including:

- **Last RTT**: Most recent round-trip time
- **p50**: Median latency (50th percentile)
- **p90**: 90th percentile latency
- **Packet Loss**: Percentage of lost pings
- **Jitter**: Average variation in latency between consecutive pings
- **Probes**: Total number of probes sent to each hop

## Usage

```bash
# Build the tool
swift build -c release --product hop-monitor

# Run it
.build/release/hop-monitor <destination>

# Example
.build/release/hop-monitor 1.1.1.1
.build/release/hop-monitor google.com
```

## Sample Output

```
🔍 Discovering network path to 1.1.1.1...

📍 Found 4 hops:
  1: 192.168.1.1
  2: 157.131.132.109
  3: 135.180.179.42
  4: 142.254.59.217

🚀 Monitoring hops (Ctrl+C to stop)...

🌐 Monitoring: 1.1.1.1
==========================================================================================

Hop   IP                  Last      p50       p90       Loss      Jitter    Probes
------------------------------------------------------------------------------------------
1     192.168.1.1         3.4ms     6.1ms     6.6ms     0%        1.8ms     3
2     157.131.132.109     5.2ms     6.5ms     6.6ms     0%        0.8ms     3
3     135.180.179.42      8.7ms     8.7ms     11.0ms    0%        3.4ms     3
4     142.254.59.217      224.4ms   17.3ms    224.4ms   0%        107.9ms   3
12    75.101.33.185       8.4ms     10.8ms    17.3ms    0%        4.4ms     3
14    172.68.188.96       8.7ms     11.0ms    17.2ms    0%        4.2ms     3
15    1.1.1.1             8.6ms     10.3ms    17.0ms    0%        4.2ms     3

Updated: 17:02:48
```

## Features

- **Concurrent monitoring**: Each hop is pinged in parallel using Swift's structured concurrency
- **Live statistics**: Display refreshes every second with updated metrics
- **Percentile calculations**: Rolling window of last 100 samples for p50/p90
- **Jitter measurement**: Tracks latency variation between consecutive pings
- **Clean display**: Uses ANSI escape codes to refresh the terminal screen

## Implementation Details

- Uses `SwiftFTR` for traceroute and ping operations
- Actor-based statistics collection for thread-safe concurrent updates
- Maintains rolling window of RTT samples (last 100) for percentile calculations
- Jitter calculated as average of absolute differences between consecutive RTTs
- No STUN call needed (uses placeholder public IP for faster startup)

## Technical Notes

- **Ping rate**: 1 ping per second per hop
- **Sample window**: Last 100 RTT measurements
- **Concurrent execution**: All hops monitored in parallel
- **Display update**: Every 1 second
- **Traceroute limit**: 10 hops max (configurable in code)

## Use Cases

- **Network troubleshooting**: Identify which hop is causing latency or packet loss
- **Path monitoring**: Continuously track network path quality
- **Jitter analysis**: Detect unstable connections with high jitter
- **Comparative analysis**: Compare different routes or times of day

## Exit

Press `Ctrl+C` to stop monitoring and exit.
