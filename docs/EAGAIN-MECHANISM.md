# What actually makes `sendto` return `EAGAIN` on an unprivileged ICMP datagram socket

Measured constraints on the `errno=35` failures that downstream production
telemetry attributes to `sendto` on the trace socket. This is a measurement
record, not a plan.

**Bottom line:** on `socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` the send buffer is pure
accounting and never holds a byte, so it cannot fill and cannot produce `EAGAIN`.
Interface pressure — the thing a probe burst could in principle cause — reports
`ENOBUFS` (55), never `EAGAIN` (35), and a burst of SwiftFTR's shape does not
reach even that. Across ~3.8 million sends in ten load shapes I could not produce
a single `EAGAIN`. Reading XNU narrows the remaining possibilities to one: a
**content filter or socket-filter network extension** attached to the process's
datagram sockets.

## Environment

| | |
|---|---|
| Host | Apple Silicon (T6000), macOS 26.6 (25G72), Darwin 25.6.0, `xnu-12377.161.13` |
| Kernel source read | `xnu-11215.81.4` (nearest public drop; the code paths below are long-stable) |
| `net.cfil.active_count` | **0** — no content filter attached on this machine |
| `net.soflow.count` | 972 (high-water 8111) |
| `kern.ipc.nmbclusters` | 262144 |
| Default `SO_SNDBUF` on the ICMP dgram socket | 8192 |
| `net.inet.icmp.*` | `maskrepl`, `timestamp`, `drop_redirect`, `log_redirect`, `bmcastecho`, `suppress_icmp_port_unreach` — **no `icmplim`** |

Harnesses live in [`Scripts/eagain/`](../Scripts/eagain/); every number below is
from a run on this host.

## 1. The `SO_SNDBUF` claim: verified, the earlier agent was right

`Scripts/eagain/t1_sndbuf.c` — unprivileged ICMP `SOCK_DGRAM` socket,
`O_NONBLOCK`, `SO_SNDBUF` shrunk and read back with `getsockopt`, then N
back-to-back `sendto` calls with every errno tallied.

macOS **does not clamp** `SO_SNDBUF` on this socket: `getsockopt` reports back
exactly what was set, including `1`.

| requested `SO_SNDBUF` | kernel reports | msg size | sends | ok | errors |
|---|---|---|---|---|---|
| 9216 | 9216 | 64 | 2000 | 2000 | — |
| 128 | 128 | 64 | 2000 | 2000 | — |
| **64** | **64** | **64** | **5000** | **5000** | — |
| 63 | 63 | 64 | 5000 | 0 | 5000 × `EMSGSIZE` (40) |
| 32 | 32 | 64 | 500 | 0 | 500 × `EMSGSIZE` (40) |
| 1 | 1 | 64 | 2000 | 0 | 2000 × `EMSGSIZE` (40) |

The boundary is exactly `sb_hiwat < msglen → EMSGSIZE`. At `sb_hiwat == msglen`
— one message's worth of buffer, the tightest setting that is not an immediate
`EMSGSIZE` — 5000 back-to-back sends all succeed. `sb_cc` therefore never rises
above zero: the buffer never holds anything.

**No `SO_SNDBUF` value produces `EAGAIN`. The claim holds.**

### Why, from the source

`socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)` dispatches to `icmp_dgram_usrreqs`
(`bsd/netinet/in_proto.c:188`), whose `pru_send` is `icmp_dgram_send`
(`bsd/netinet/ip_icmp.c:1210`). That validates the ICMP type/code and tail-calls
`rip_send` → `rip_output` → `ip_output`, all synchronously, on the caller's
thread. Nothing is ever appended to `so_snd`; the protocol is `PR_ATOMIC`, so
`sosend` hands the mbuf straight to `pru_send`.

`sosendcheck` (`bsd/kern/uipc_socket.c:1987`) is the only place a datagram
`sendto` can return `EWOULDBLOCK`:

```c
space = sbspace(&so->so_snd);
if ((atomic && resid > so->so_snd.sb_hiwat) || clen > so->so_snd.sb_hiwat)
        return EMSGSIZE;                     /* <- the boundary measured above */
if ((space < resid + clen && (atomic || ...)) || ...) {
        ...
        if ((so->so_state & SS_NBIO) || (flags & MSG_NBIO) || assumelock)
                return EWOULDBLOCK;          /* <- the only EAGAIN on this path */
```

and `sbspace` (`bsd/kern/uipc_socket2.c:2316`) is

```c
space = imin(sb_hiwat - sb_cc, sb_mbmax - sb_mbcnt);
...
pending = cfil_sock_data_space(sb);          /* CONTENT_FILTER */
space = (pending > space) ? 0 : space - pending;
```

With `sb_cc == sb_mbcnt == 0` always, `space == sb_hiwat`, and the `EMSGSIZE`
test immediately above guarantees `resid <= sb_hiwat`. The `EWOULDBLOCK` branch
is therefore unreachable **unless `cfil_sock_data_space()` is non-zero**.

The other `EWOULDBLOCK` in the path, `sblock()`
(`bsd/kern/uipc_socket2.c:2506`), fires only when `SBL_WAIT` is clear —
`SBLOCKWAIT(flags)` clears it only for `MSG_DONTWAIT`, which SwiftFTR does not
pass (`sendto(..., 0, ...)` in `Traceroute.swift:1381`). `O_NONBLOCK` alone does
not reach it.

## 2. What I could reproduce, and what errno it gives

`Scripts/eagain/t2_load.c` — N threads, one ICMP `SOCK_DGRAM` socket each,
`O_NONBLOCK`, configurable burst/payload/destination/interface. It timestamps
every failure, measures the interval from each failure to the next successful
send on that socket ("recovery"), and optionally times `poll(POLLOUT)`.

| # | shape | sends | errors |
|---|---|---|---|
| A | 8 threads × 40-probe bursts, 200 ms apart, 64 B — **the shape SwiftFTR actually produces** | 16,000 | **0** |
| B | 32 threads × 200, no gap, 64 B, loopback, 71k pkt/s | 1,280,000 | **0** |
| C | 32 threads × 200, no gap, 1480 B, gateway | 256,000 | 1,012 × `ENOBUFS` |
| D | 64 threads × 200, no gap, 1480 B, gateway | 192,000 | **0** |
| E | 32 threads × 100, no gap, 8008 B, gateway, ~40k sends/s | 16,000 | 8,269 × `ENOBUFS` |
| F | repeat of E | 16,000 | 8,885 × `ENOBUFS` |
| G | 32 threads × 500, no gap, 64 B, gateway, 4.2k pkt/s for 380 s | 1,600,000 | 6,771 × `ENOBUFS` |
| H | 31 threads × 500, no gap, 64 B, gateway — background load for run K | 310,000 | 693 × `ENOBUFS` |
| I | **1** socket × 200-probe bursts, 200 ms apart, 64 B | 6,000 | **0** |
| J | 1 socket × 5000-probe bursts, 200 ms apart, 64 B, 19k pkt/s | 150,000 | 139 × `ENOBUFS` |
| K | `t3_victim`: 1 socket × 40-probe bursts, 200 ms apart, 64 B, **concurrent with run H** | 8,000 | **0** |

**Across every run — roughly 3.8 million sends — zero `EAGAIN`. Every single
failure was `ENOBUFS` (55).**

Run A is the important negative: the exact burst SwiftFTR issues — eight
concurrent traces, 40 unpaced probes each, five bursts a second — produced no
send error at all. Run I raises that to a 200-probe burst on one socket, still
clean. A single socket has to reach ~5000 probes per burst (19k pkt/s) before
`ENOBUFS` appears at all.

### `ENOBUFS` is an AQM drop, not a buffer

`EQFULL` and `EQSUSPENDED` — what FQ-CoDel returns when it flow-controls or
suspends a queue — never reach userspace: `dlil_output` converts them into a
flow advisory and rewrites the return to 0 (`bsd/net/dlil.c:6940-6947`). The
`ENOBUFS` an application sees is the *hard drop* case, `fq_addq` returning
`CLASSQEQ_DROP` (`bsd/net/pktsched/pktsched_fq_codel.c:592`) — the scheduler
discarded the packet outright.

Because FQ-CoDel is **per-flow** (hashed on `inp_flowhash`, so per socket), a
low-rate flow is insulated from a high-rate one. Runs H and K demonstrate this
directly: while 31 sockets hammered the same interface hard enough to take 693
`ENOBUFS` with recovery windows up to 1.56 s, a 32nd socket issuing SwiftFTR's
40-probe burst every 200 ms took **zero** send errors across 8000 probes. Other
traffic on the box — including SwiftFTR's own concurrent pings — does not push a
well-behaved trace socket into `ENOBUFS`. Only a socket that itself sustains a
punishing rate gets dropped.

### How long `ENOBUFS` lasts — two different regimes

Recovery interval from a failed send to the next successful send on the same
socket:

| run | shape | failures | p50 | p90 | p99 | max | over 250 ms |
|---|---|---|---|---|---|---|---|
| E | 8 KB, 40k sends/s | 7,984 | 18.6 ms | 83.2 ms | 103.7 ms | 116.2 ms | **0 (0.00 %)** |
| F | 8 KB, 42k sends/s | 8,885 | 9.6 ms | 74.4 ms | 94.0 ms | 110.0 ms | **0 (0.00 %)** |
| J | 64 B, one socket, 19k pkt/s | 139 | 205.5 ms | 206.1 ms | 206.2 ms | 206.2 ms | 0 (0.00 %) |
| H | 64 B, 31 sockets, 5.2k pkt/s | 693 | 49.8 ms | 1.545 s | 1.551 s | 1.557 s | 337 (**48.6 %**) |
| G | 64 B, 32 sockets, 4.2k pkt/s, 380 s | 6,771 | 600.6 ms | 1.671 s | 3.090 s | 3.104 s | 3,948 (**58.3 %**) |
| G′ | repeat of G, shorter | 640 | 1.995 s | 2.033 s | 2.034 s | 2.034 s | 409 (**63.9 %**) |

Two clearly separated regimes, and the split is not about packet size — it is
about whether the *sender keeps hammering*. A burst that overruns and then stops
(E, F, J) clears in 10–210 ms. A socket that keeps retrying into a queue the AQM
has already flow-controlled (G, H, G′) stays blocked for **0.6–3.1 seconds**,
and in G′ every one of the 640 failures shared a single ~2 s window.

This matters for the retry loop specifically: on `ENOBUFS`, `poll(POLLOUT)`
returned writable in 0.000–0.6 ms on every one of the thousands of samples, so
the retry cannot wait — it spins on a 1 ms nap, which is exactly the hammering
that keeps the flow suspended. `SendRetry.swift`'s comment about `poll` being
useless for `ENOBUFS` is correct and is now measured rather than assumed; the
1 ms backoff is the right shape. But a retry loop is, by construction, the
pattern that produces the multi-second regime rather than the fast one.

## 3. Hypotheses eliminated, and by what

| hypothesis | verdict | basis |
|---|---|---|
| Socket send buffer momentarily full | **refuted** | §1 — measurement + `sosendcheck`/`sbspace` source |
| Interface output queue pressure | reproduces, but as **`ENOBUFS`**, not `EAGAIN`, and only for a socket sustaining ~19k pkt/s of its own | runs C/E/F/G/J |
| Concurrent load across many sockets in one process | **refuted as a cause for a trace socket** — FQ-CoDel isolates per-socket flows; 31 flooding sockets left the 40-probe burst untouched | runs H + K |
| mbuf/cluster exhaustion | `netstat -m` grew the cache pool (4167→6810 mbufs, 3864→6376 2 KB clusters) and never came near `nmbclusters`; surfaced as `ENOBUFS` | run C |
| macOS ICMP rate limiting on send | **not present** | there is no `net.inet.icmp.icmplim` on macOS 26.6; the six `net.inet.icmp` knobs are all receive-side |
| Many distinct destinations | no send error; `soflow_get_flow` failure yields `NULL`, not an errno (`uipc_socket.c:2195`) | run B/C + source |
| ARP hold-queue overflow | cannot surface as `EAGAIN` — `la_holdq` is `Q_DROPHEAD`, drops silently, returns `EJUSTRETURN` (`bsd/netinet/in_arp.c:275,318`) | source |
| Interface enqueue backpressure errno | `EQFULL` (106) / `EQSUSPENDED` / `ENOBUFS` — never `EAGAIN` (`bsd/net/dlil.c:6940`) | source |
| `sblock` contention | needs `MSG_DONTWAIT`; SwiftFTR passes `0` | source |
| NECP flow divert | returns `EPROTOTYPE` (100) (`ip_icmp.c:1223`) | source |
| Socket defunct / App Nap | returns `EPIPE` (`sosendcheck` `SOF_DEFUNCT`) | source |
| Latched `so_error` | no kernel path assigns `EAGAIN`/`EWOULDBLOCK` to a socket's `so_error` in `bsd/kern`, `bsd/net*` except `vsock_domain.c` | grep of `so_error =` |

A grep for `EWOULDBLOCK`/`EAGAIN` across `bsd/net/`, `bsd/netinet/`,
`bsd/netinet6/` and `bsd/kern/uipc_*` finds no other site on the ICMPv4 datagram
send path. The `EAGAIN`s that exist there are `in_pcbbind`/`in6_pcbsetport`
ephemeral-port exhaustion (ICMP datagram sockets bind no port),
`fq_if_dequeue_*` on the driver dequeue side, and `accept`/`sendfile`.

## 4. The one path left: content filters

`sbspace()` subtracts `cfil_sock_data_space(sb)`. On macOS — and this differs
from iOS — every INET datagram socket is flow-tracked:

```c
/* bsd/sys/socketvar.h:1036 */
#if !XNU_TARGET_OS_OSX
#define NEED_DGRAM_FLOW_TRACKING(so) (IS_INET(so) && IS_UDP(so))
#else
#define NEED_DGRAM_FLOW_TRACKING(so) (IS_INET(so) && !IS_TCP(so))
#endif
```

`!IS_TCP` includes `SOCK_DGRAM`/`IPPROTO_ICMP`. `cfil_sock_data_space` then
returns `cfil_sock_udp_data_pending()` — bytes handed to a filter and still
awaiting a verdict. `sosend` routes each datagram through `cfil_sock_data_out`
before `pru_send` (`bsd/kern/uipc_socket.c:2558`), and `icmp_dgram_send` itself
carries `CFIL_DGRAM_FILTERED` handling (`ip_icmp.c:1236`). So when a
`NEFilterDataProvider` is attached and slow to verdict, `pending` grows,
`sbspace()` returns 0, and a non-blocking `sendto` gets `EWOULDBLOCK` —
**errno 35, on exactly this socket type.** `sflt_data_out`
(`uipc_socket.c:2545`) is a second, more direct route: a socket-filter NKE may
return any errno it likes, `EWOULDBLOCK` included.

This is a hypothesis, **not** a reproduction. `net.cfil.active_count` is 0 on
this machine and I have no filter to attach, so I could not test it. It is
distinguished from everything else on this page by being the only mechanism the
source leaves standing.

It also fits the field shape better than buffer pressure does: ~80 events a week
concentrated on four machines, rather than spread across the fleet, is what you
would expect from a property of *those machines' software* (Little Snitch, LuLu,
CrowdStrike, Netskope, Zscaler, Cisco Umbrella and similar all ship
`NEFilterDataProvider`s) rather than from a burst shape every install of a
host app produces.

The reporting host app installs no such filter itself — it uses
`NetworkExtension` only for `NEVPNManager`-based VPN detection — so any filter
present belongs to other software on those machines.

### How to settle it

Two cheap steps, neither of which I can take from here:

1. Have the host app's telemetry report `net.cfil.active_count` (readable
   unprivileged via `sysctlbyname`) alongside the errno. If the reporting
   machines have a filter attached and the quiet ones do not, the question is
   closed.
2. On a machine with a content filter installed, run
   `Scripts/eagain/t2_load.c` and see whether `EAGAIN` appears.

## 5. Is `traceBurstSendRetryBudget = 0.25` the right number?

**For `ENOBUFS`: right for the only regime SwiftFTR can reach, and hopeless for
the other — but SwiftFTR cannot reach the other.**

- In the regime a probe burst can plausibly produce — a socket that overruns
  briefly and stops — every measured recovery was 10–210 ms, worst case 206 ms
  over 17,000 samples. 250 ms covers that distribution and still leaves 750 ms of
  the default 1000 ms receive window. Correct sizing.
- In the sustained-hammering regime, recovery is 0.6–3.1 s and 250 ms covers
  only 36–51 % of failures. If SwiftFTR ever landed there, the budget would be
  roughly an order of magnitude short and raising it would be the wrong fix
  anyway — you cannot spin your way out of a flow the AQM has suspended, and a
  2 s stall inside a trace is worse than a failed trace.
- **But SwiftFTR does not land there.** A 40-probe burst takes no error even
  with 31 sockets flooding the same interface (runs H + K), because FQ-CoDel isolates
  flows per socket. `ENOBUFS` needed a single socket sustaining ~19k pkt/s
  before it appeared at all.

So the constant is defensible, and `ENOBUFS` is very likely not what production
is reporting in the first place — production reports 35, and I could not produce
35.

**For `EAGAIN`: unknown, and 250 ms is a guess against an unmeasured
condition.** If the content-filter path is what production is hitting, the
budget is bounded by how long a userspace filter extension takes to verdict —
which is a scheduling property of a third-party process, not a kernel drain, and
there is no reason to expect it to be under 250 ms. The retry may help
(a filter that is briefly behind catches up) or may not (a wedged or
priority-inverted extension outlasts any budget). I have no measurement either
way.

What I can say: the retry is not harmful, and 250 ms is not obviously wrong. But
the justification written into `SendRetry.swift` — "the millisecond-scale buffer
pressure the field reports" — describes a mechanism that does not exist on this
socket type. The constant should be re-derived once step 1 above tells us what
the field condition actually is.

**Separately worth noting:** the *user-visible* bug in Signal 1 is not the errno,
it is that one failed probe aborts a 40-probe trace. A `sendto` failure on hop
17 costs the whole topology measurement even though 39 other probes were fine.
Recording the hop as unreachable and continuing would make the trace robust to
this class of failure regardless of which errno turns out to be responsible, and
without depending on a timeout constant at all.

## Reproducing

```bash
cd Scripts/eagain
clang -O2 -o t1_sndbuf t1_sndbuf.c
clang -O2 -o t2_load  t2_load.c -lpthread

clang -O2 -o t3_victim t3_victim.c

./t1_sndbuf 64 5000 56 1.1.1.1        # SO_SNDBUF boundary
./t2_load -t 8  -b 40  -r 50  -g 200000 -p 56   -d 1.1.1.1        -P   # SwiftFTR-shaped
./t2_load -t 32 -b 100 -r 5   -g 0      -p 8000 -d <your-gateway> -P   # fast ENOBUFS regime
./t2_load -t 32 -b 500 -r 100 -g 0      -p 56   -d <your-gateway>      # multi-second regime

# flow isolation: run the load in one shell, the victim in another
./t2_load   -t 31 -b 500 -r 20  -g 0   -p 56 -d <your-gateway> &
./t3_victim -b 40 -r 200 -g 200 -p 56  -d 1.1.1.1 -B 0.25
```

`t3_victim` models `SendRetry.swift` directly: one socket, a 40-probe unpaced
burst every 200 ms, `poll(POLLOUT)` on `EAGAIN` and a 1 ms nap on `ENOBUFS`,
with a single budget shared across the burst. It reports how many bursts would
have been aborted.

The heavy `t2_load` runs offer up to ~2 Gbit/s at the local gateway. Run them on
a network you own.
