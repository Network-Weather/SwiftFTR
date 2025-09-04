import Foundation
import ParallelTraceroute

@main
struct App {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            fputs("Usage: ptroute <host> [maxHops] [timeoutSec]\n", stderr)
            exit(2)
        }
        let host = args[1]
        let maxHops = args.count >= 3 ? Int(args[2]) ?? 30 : 30
        let timeout = args.count >= 4 ? (TimeInterval(args[3]) ?? 1.0) : 1.0

        let tracer = ParallelTraceroute()
        do {
            let result = try await tracer.trace(to: host, maxHops: maxHops, timeout: timeout)
            print("traceroute to \(result.destination), \(maxHops) hops max")
            for hop in result.hops {
                let hostStr = hop.host ?? "*"
                let rttMs = hop.rtt.map { String(format: "%.2f ms", $0 * 1000) } ?? "timeout"
                let mark = hop.reachedDestination ? "!" : " "
                print(String(format: "%2d  %@  %@%@", hop.ttl, hostStr, rttMs, mark))
            }
            if result.reached { print("Destination reached.") } else { print("Destination not reached.") }
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }
}
