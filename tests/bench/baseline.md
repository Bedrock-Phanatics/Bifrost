# Baseline

Recorded 2026-10-04 before managed sessions, transfers and plugins. Later changes should be compared against these
numbers on the same kind of host and build mode.

Host: WSL2 Ubuntu (kernel 6.6.87.2), 12 logical CPUs, loopback, clients and backends on the same machine.
Every column is one full `zig build bench` run. The workers rows also show two extra runs of `-- workers`.

```sh
zig build bench -Doptimize=ReleaseFast                       # work_stealing proxy, the production default
zig build bench -Doptimize=ReleaseFast -Dscheduling=pinned   # proxy tasks never migrate between executors
```

`-Dscheduling` only changes the proxy under test; the load driver always uses the default scheduler.

## ReleaseFast

| metric | Zig 0.16 (2558615) | Zig 0.17, work_stealing | Zig 0.17, pinned |
|---|---|---|---|
| relay 512 B 1x1, round trips/s | 6910 | 7782 | 8554 |
| relay 512 B 1x1, p50 / p99 us | 121 / 301 | 97 / 318 | 86 / 257 |
| relay 512 B 8x32, round trips/s | 31040 | 29056 | 35796 |
| relay 512 B 8x32, p50 / p99 us | 7428 / 16836 | 7547 / 23212 | 6248 / 14940 |
| relay 20 KiB 8x12, MiB/s one way | 45.2 | 54.0 | 56.5 |
| observed handshake, p50 / p99 us | 3366 / 4281 | 3330 / 4202 | 3125 / 4369 |
| joins/s, 2000 players wave 1 | 839 | 1101 | 958 |
| join p50 / p99 ms, 2000 players wave 1 | 41.7 / 557.3 | 27.5 / 550.3 | 35.3 / 547.0 |
| joins/s, 1 healthy backend | 1491 | 1509 | 1662 |
| reconnect churn, cycles/s per round | 1199 / 1238 / 1153 | 1439 / 1178 / 1555 | 1718 / 1563 / 1602 |
| reconnect churn round 1, p50 / p99 ms | 26.5 / 33.6 | 21.4 / 38.4 | 18.0 / 25.4 |
| RSS per held player, 2000 players | 222.9 KiB | 217.9 KiB | 218.0 KiB |
| heap per held player | 266.3 KiB | 266.3 KiB | 266.3 KiB |
| fresh proxy RSS | 3584 KiB | 3584 KiB | 3712 KiB |
| workers 1 / 2 / 4 / 8, round trips/s (k) | 21.6 / 48.4 / 78.6 / 101.2 | 23.2 / 55.8 / 83.0 / 83.0 | 28.1 / 24.5 / 79.5 / 121.0 |
| workers repeat 1 (k) | | 23.6 / 47.3 / 76.6 / 126.8 | 24.3 / 21.9 / 72.1 / 113.8 |
| workers repeat 2 (k) | | 25.1 / 46.2 / 83.8 / 138.5 | 26.1 / 25.1 / 82.1 / 122.5 |

Zig 0.17 is at or above the 0.16 numbers everywhere outside run-to-run noise, with identical heap per player.

Pinned scheduling halves 2-worker throughput in every run (proxy CPU stays near 100%): ZIO places tasks round-robin,
so the health and report tasks shift the worker tasks and both workers can share one executor. Pinned needs explicit
worker placement before it is worth considering as a default. At 4 and 8 workers the two are within noise.

Both versions occasionally lose a whole churn round or connection wave (thousands of failed cycles, or 0 joined) when
the kernel drops UDP bursts; see `net.core.rmem_max` in the README. Treat a single such row as noise, not a regression.

## Passthrough vs managed

`zig build bench -Doptimize=ReleaseFast -- managed`, same host, 1 worker, random payloads, no packet subscribers.
Managed sessions compress batches over 256 B with deflate on both legs.

| payload | load | passthrough round trips/s | managed round trips/s | managed p50 / p99 us | proxy CPU (pass / managed) |
|---|---|---|---|---|---|
| 64 B | 1x1 | 7921 | 7497 | 102 / 377 | 90% / 88% |
| 64 B | 8x32 | 31690 | 30022 | 8471 / 11096 | 98% / 98% |
| 512 B | 1x1 | 8272 | 2448 | 383 / 584 | 92% / 72% |
| 512 B | 8x32 | 34150 | 8535 | 27020 / 61497 | 94% / 93% |
| 8 KiB | 1x1 | 4645 | 1200 | 801 / 1180 | 95% / 64% |
| 8 KiB | 8x32 | 5025 | 1652 | 140321 / 249920 | 97% / 98% |

Joins: 1.9 ms per player passthrough, 15.1 ms managed (token check, proxy login, two key exchanges).
Below the compression threshold managed costs about 5%. Above it, re-compressing every batch makes the proxy
CPU-bound at roughly a quarter to a third of passthrough; that is the first thing to optimise in managed mode.

## Managed relay fast path

Recorded 2026-10-07 on Windows 11, ReleaseFast, `-- managed deflate --quick`, 1 worker, random payloads. Round trips/s;
"decoded" has two backends configured, so transfers are possible and every batch is decoded.

| payload | load | passthrough | decoded | relayed | relayed, 10 idle plugins | 1 decoded subscriber |
|---|---|---|---|---|---|---|
| 256 B | 1x1 | 7210 | 3504 | 4026 | 3994 | 3682 |
| 256 B | 8x32 | 21836 | 9924 | 12462 | 12800 | 12704 |
| 1 KiB | 1x1 | 4892 | 2420 | 2946 | 3174 | 2804 |
| 1 KiB | 8x32 | 15520 | 5554 | 9772 | 10068 | 8784 |
| 8 KiB | 1x1 | 1346 | 750 | 944 | 974 | 886 |
| 8 KiB | 8x32 | 2818 | 1364 | 2054 | 1982 | 1860 |
| 20 KiB | 1x1 | 676 | 304 | 370 | 392 | 346 |
| 20 KiB | 8x12 | 1376 | 546 | 834 | 826 | 786 |

Relaying skips the proxy's two deflate passes per batch: 1.6x to 1.8x the decoded throughput under load. The rest of
the gap to passthrough is the two AES/SHA legs and the bench client and backend compressing on the same machine. The
decoded subscriber only hooks player packets, so backend batches still relay (50% relayed).

Deflate level, in-process, one batch: on game-like data level 1 is 0% to 13% faster than level 6 with the same
output size; random data costs the same at every level. Not worth changing the default now that unchanged batches
skip compression.

## Stability baselines

Recorded 2026-10-06 on WSL2 Ubuntu, 12 logical CPUs, ReleaseFast, 1 worker, loopback, 512 B echoes.
`zig build bench -Doptimize=ReleaseFast -- relay managed plugins connections` and
`zig build test -Doptimize=ReleaseFast -Dtransfer-report=true`.

| setup | load | round trips/s | p50 / p95 / p99 us | proxy CPU | memory per player |
|---|---|---|---|---|---|
| passthrough | 1x1 | 9215 | 84 / 157 / 198 | 95% | 218.5 KiB RSS, 266.5 KiB heap |
| passthrough | 8x32 | 44700 | 5057 / 9021 / 11544 | 104% | |
| managed | 1x1 | 2613 | 350 / 428 / 593 | 77% | 252.5 KiB heap |
| managed | 8x32 | 11048 | 20382 / 34393 / 45700 | 102% | |
| managed, 10 plugins without packet hooks | 1x1 | 2962 | 323 / 361 / 399 | 77% | 252.5 KiB heap |
| managed, 10 plugins without packet hooks | 8x32 | 10862 | 20813 / 36041 / 49083 | 101% | |
| managed, 1 packet subscriber | 1x1 | 2849 | 329 / 385 / 457 | 75% | 276.5 KiB heap |
| managed, 1 packet subscriber | 8x32 | 10886 | 20763 / 34992 / 46146 | 104% | |

Managed rows already have transfers available: an idle transfer costs nothing per packet, so there is no separate
row for it. The packet-subscriber heap includes one ~190 KiB rewrite buffer per worker, spread over 8 players.

| transfers | p50 / p95 / p99 ms | live heap |
|---|---|---|
| one player, A↔B 200 times | 33.6 / - / 36.9 | identical after 20 and 200 |
| 8 players at once, 50 rounds, time for the whole batch | 80.5 / 88.0 / 90.8 | identical after 5 and 50 |

Joins take 1.4 ms passthrough and 14.3 ms managed per player. RSS for managed players is not measured separately.

## Plugin dispatch

`zig build bench -Doptimize=ReleaseFast -- plugins`. The first table times what a managed relay does per packet for
plugins, in-process, over a stream that alternates the hot packet with another one. Callbacks do nothing, so a
callback's cost is the table lookup, its two clock reads and its metrics. The bench prints `OVER` when a setup exceeds
its budget.

| setup | ns per callback, Windows / WSL2 | budget |
|---|---|---|
| 0 plugins | 0 (0.5 ns per packet total) | 2 ns |
| 10 plugins, no packet subscriptions | 0 | 2 ns |
| 1 raw subscriber on the hot packet | 49 / 52 | 100 ns |
| 1 decoded subscriber on the hot packet | 86 / 88 | 200 ns |
| 10 subscribers on different packet ids | 49 / 55 | 100 ns |
| 10 subscribers on the same hot packet | 52 / 54 | 100 ns |

End to end (managed echo, 512 B, WSL2) every setup stays within run-to-run noise of 0 plugins: 2.6k to 2.8k round
trips/s at 1x1 with p99 423 to 454 us, and 9.7k to 10.8k round trips/s at 8x32. Managed re-compression costs
microseconds per batch, so a few callbacks per packet don't show. Windows end-to-end runs vary more than the setups do.

Heap of a managed proxy (WSL2): 16.6 MiB fresh, 252 KiB per managed player. Idle plugins add nothing; packet
subscribers add one ~190 KiB rewrite buffer per worker.

### Lazy scratch and chained clock reads

Recorded 2026-10-11 on Windows, ReleaseFast, `-- plugins --quick`, dispatch table only, three alternating runs each
against 019660c. Ns per packet; the stream is half hot packets.

| setup | before | after |
|---|---|---|
| 1 raw subscriber on the hot packet | 29 to 43 | 31 to 34 |
| 1 decoded subscriber on the hot packet | 55 to 77 | 56 to 63 |
| 10 subscribers on different packet ids | 58 to 75 | 62 to 68 |
| 10 subscribers on the same hot packet | 285 to 339 | 171 to 180 |
| 1 before-game subscriber on the hot packet, in game | 4.4 to 6.3 | 2.0 to 3.4 |
| 1 subscriber replacing the hot packet | 55 to 73 | 66 to 75 |
| 2 subscribers chaining replacements | 122 to 137 | 118 to 139 |

One clock read now ends a callback and starts the next, so ten callbacks on a packet take 11 reads instead of 20.
Packets nobody hooks for the current phase skip dispatch, and in-game batches still take the opaque relay when every
hook in that direction is before-game only. The rewrite buffer is gone: a 128 KiB scratch buffer per worker is
allocated on the first hooked packet, and replacements are copied into the batch arena, so they no longer split
batches. A single replacement costs one extra copy, within run-to-run noise here.

## Player id translation

`zig build bench -Doptimize=ReleaseFast -- ids`, recorded 2026-10-08, three runs each. After a transfer the proxy swaps
the client's first actor ids with the current backend's. The stream is half MovePlayer and SetActorMotion, half text
and raw packets, which are never decoded.

| case | added ns per packet, Windows / WSL2 |
|---|---|
| no transfer yet, or the same ids | 0 (0.5 ns per packet total) |
| swap active, actor packets name other actors | 25 to 27 / 22 to 29 |
| swap active, actor packets name the player | 65 to 70 / 65 to 104 |

Per packet that can hold an actor id that is about 50 ns to decode and check, and 130 to 200 ns when it has to be
re-encoded, against microseconds per batch for managed re-compression.

Transfers, A/B on Windows against cace0fc (the commit before translation), two alternating runs each, ReleaseFast:
200 A↔B transfers p50 30.9 to 31.2 ms before and 31.3 to 31.5 ms after, p99 45 to 51 ms both; 8 concurrent
transfers p50 127 to 139 ms either way. The live heap stays flat and is 48 B larger.

## Plugin tasks

`zig build bench -Doptimize=ReleaseFast -- tasks`, recorded 2026-10-09, three runs each. Empty tasks from one plugin
(32 in flight), `done` drained on the submitting thread. Before is `std.Io.Threaded` with up to 128 threads, after is
the fixed pool with 4 threads.

| | tasks/s, Windows / WSL2 | submit to done p50 | p99 |
|---|---|---|---|
| before | 140k to 197k / 43k to 47k | 6.0 to 6.8 / 32.5 to 34.2 us | 9.5 to 11.1 / 72.6 to 76.1 us |
| after | 2.8M to 3.3M / 61k to 65k | 2.8 to 4.4 / 14.8 to 18.8 us | 7.7 to 14.8 / 33.5 to 117 us |

On WSL2 each submit wakes a sleeping thread through a futex, which is most of the cost; fine for blocking work.

## Plugin handle table

`zig build bench -Doptimize=ReleaseFast -- handles`, recorded 2026-10-09, two runs each, 12 CPUs. Threads resolve
random handles among 1024 live players nonstop, with and without another thread joining and leaving players nonstop.

| lookup threads | ns per lookup, Windows / WSL2 | with churn | total lookups/s, worst |
|---|---|---|---|
| 1 | 4.8 / - | 33 / 50 to 115 | 30M / 9M |
| 2 | 45 to 64 / 41 to 42 | 94 / 167 to 177 | 21M / 11M |
| 4 | 175 to 191 / 143 to 158 | 264 to 291 / 230 to 262 | 14M / 15M |
| 8 | 629 to 678 / 601 to 634 | 817 to 830 / 810 to 845 | 10M / 9.5M |

The global spinlock does contend when every thread does nothing but lookups, but lookups only come from plugin host
calls, joins, leaves and queue drains, never the relay itself. Even a host call per packet on 8 busy workers is around
1M lookups/s against 10M/s fully contended, so the table stays as it is.

## Plugin command advertisement

The decoded relay now checks each backend packet for `available_commands`. A/B on WSL2 against a76a533,
`-- managed --quick`, "managed, transfers possible", three alternating runs each, round trips/s:

| | before | after |
|---|---|---|
| 256 B 1x1 | 3200 to 3452 | 3288 to 3404 |
| 256 B 8x32 | 12.6k to 13.9k | 14.2k to 14.7k |
| 1 KiB 1x1 | 2472 to 2760 | 2536 to 2850 |
| 8 KiB 8x32 | 1934 to 2010 | 1704 to 2204 |
| 20 KiB 8x12 | 780 to 854 | 816 to 888 |

All within run-to-run noise. A proxy with plugin commands no longer takes the opaque relay in either direction,
so it costs what "transfers possible" costs instead of the relayed rows.

## Load audit

Recorded 2026-10-05 on WSL2, ReleaseFast. Nothing here needed a change.

Fairness (`-- fairness`): 4 light players (64 B, 1 in flight) next to 4 hot ones (512 B, 32 in flight) on 1 worker see
the same latency as the hot players, p50 3.3 ms and p99 4.3 ms, against 0.35 / 0.70 ms alone. Every packet waits
behind the same listener socket and saturated worker, so reordering the ready list cannot help.

Scheduling (`-- workers managed --quick`, both `-Dscheduling` values): pinned loses at every worker count above one,
17k against 63k round trips/s at 2 workers and 92k against 147k at 8, with p99 8.8 ms against 3.7 ms at 8. Managed
single-worker numbers are the same either way. Work stealing stays the default.

Queues: every queue has a packet and a byte limit. Copying each packet into its own allocation costs 0.7 us per
64 x 512 B burst against 27 us for one growing buffer when the queue is new, as it is for the initial-dial queue, so
`PacketQueue` stays as it is.

## Transfers

`zig build test -Doptimize=ReleaseFast -Dtransfer-report=true`. The stress test moves one player A↔B 200 times and
times each request until the client is synced and its echo comes back from the target. Windows 11, Zig 0.17.

| build | p50 / p99 ms | proxy live heap after 20 / 200 transfers |
|---|---|---|
| ReleaseFast | 31.1 / 32.7 | 16053437 / 16053437 B |
| ReleaseSafe | 31.0 / 32.7 | 16053525 / 16053525 B |
| Debug | 189.4 / 236.3 | 16053525 / 16053525 B |

WSL2 Ubuntu: ReleaseFast 33.7 / 34.4 ms, ReleaseSafe 33.9 / 35.6 ms, same flat heap.
The test fails if the live heap grows more than 64 KiB between those points.

## ReleaseSafe

`-- --quick`, Zig 0.17, work_stealing: relay 512 B 1x1 8554 round trips/s (p50 91 us, p99 221 us), 8 KiB 8x32 23.8 MiB/s,
observed handshake p50 9456 us, 400 joins/s at 500 players, churn 582 to 732 cycles/s with no failures,
328 KiB RSS per held player at 500 players, workers 1 / 2 / 4 / 8 at 27k / 55k / 105k / 144k round trips/s.

## Windows

Windows 11, same machine, ReleaseFast, Zig 0.17: relay 512 B 1x1 5076 round trips/s (p50 155 us, p99 303 us),
1149 joins/s with 1 healthy backend, churn 307 to 836 cycles/s. RSS, CPU and multiple workers are Linux only.

## 1.0.0-rc.1

Recorded 2026-10-10 on WSL2 Ubuntu, 12 logical CPUs, ReleaseFast, full `zig build bench` plus
`zig build test -Doptimize=ReleaseFast -Dtransfer-report=true`, with raknet `38b1da9`.

That raknet limits handshake traffic per IP instead of per client port, at 20 tokens a second by default. With every
bench client on 127.0.0.1 that capped joins at about 8 a second, both at the proxy and at the bench's own echo
backends. Bifrost now sets the player listener from `[limits] handshake_rate_per_ip` (default 2000), and the bench
and test backends lift the limit entirely.

| metric | result | earlier baseline |
|---|---|---|
| raw relay 512 B 1x1 | 10266 round trips/s, p50 80 us, p99 175 us | 9215, 84 / 198 |
| raw relay 512 B 8x32 | 44591 round trips/s, 21.8 MiB/s | 44700 |
| raw relay 20 KiB 8x12 | 62.5 MiB/s one way | 54.0 |
| managed 512 B 1x1, relayed | 3524 round trips/s, p50 257 us, p99 425 us | 2613 decoded |
| managed 512 B 8x32, relayed | 26094 round trips/s | 11048 decoded |
| managed 256 B 8x32, every batch decoded | 14676 round trips/s, p50 15.2 ms, p99 39.1 ms | |
| workers 1 / 2 / 4 / 8 | 34.2k / 66.1k / 107.9k / 146.5k round trips/s | 23.2k / 55.8k / 83.0k / 83.0k |
| joins/s, 2000 players, first wave | 800 to 872 | 1101 |
| join p50 / p99, 2000 players, first wave | 27.6 to 47.9 / 552 to 565 ms | 27.5 / 550.3 |
| joins/s, 1 healthy backend | 1617 | 1509 |
| reconnect churn, cycles/s per round | 617 to 1643 | 1153 to 1555 |
| RSS per held player, passthrough | 228.3 KiB | 217.9 KiB |
| heap per managed player | 252.5 KiB, 276.5 KiB with a packet hook | 252.5 / 276.5 |
| fresh proxy | 4096 KiB RSS, 0.1% CPU with 8 silent players | 3584 KiB |
| one player A↔B 200 times | p50 33.1 ms, p99 33.8 ms, live heap identical after 20 and 200 | 33.6 / 36.9 |
| 8 players at once, 50 rounds | p50 77.2 ms, p95 86.6 ms, p99 87.5 ms, live heap identical after 5 and 50 | 80.5 / 88.0 / 90.8 |

Nothing regressed beyond run-to-run noise once the handshake limit was lifted. Joins in the first 2000-player wave
are about a quarter below the old baseline and churn varies more between rounds; both runs logged thousands of
kernel UDP drops (`net.core.rmem_max` is 208 KiB here), which likely explains the spread. Second waves of 500
and 2000 players occasionally join nobody for the same reason.

## Plugin packet header and milestone checks

Recorded 2026-10-12 on Windows x86_64, 12 logical CPUs, Zig 0.17.0, ReleaseFast,
`zig build bench -Doptimize=ReleaseFast -- plugins --quick`. Both builds use the same alternating text/raw
stream. Dispatch figures are medians of seven samples, each processing 200 x 4096 packets. Relay figures are
medians of three 500 ms samples after a 300 ms warmup. The final run had no other Bifrost builds or tests running.

| dispatch setup | before, ns/packet | after, ns/packet |
|---|---|---|
| no plugins | 0.6 | 0.5 |
| 10 plugins without packet subscriptions | 0.5 | 0.5 |
| one raw listener | 33.3 | 30.0 |
| one validated listener | 56.4 | 53.6 |
| 10 listeners on different IDs | 64.5 | 58.2 |
| 10 listeners on the hot ID | 175.8 | 155.8 |
| before-game listener while in game | 2.3 | 0.5 |
| one replacement | 64.2 | 57.4 |
| two chained replacements | 115.3 | 106.7 |

The phase mismatch now skips header parsing by selecting the table once per batch. Other differences do not
establish a speedup: clock costs and machine load vary between runs. Canonical header validation and preserving
both sub-client indices stayed within the existing dispatch budgets. Header parsing and phase filtering introduce
no allocator calls or packet copies; accepted replacements retain their existing arena copy.

| managed relay setup | before, round trips/s | after, round trips/s | before/after p50 us | before/after p99 us |
|---|---|---|---|---|
| one raw listener, 1x1 | 2364 | 2346 | 359 / 359 | 654 / 650 |
| one raw listener, 8x32 | 7502 | 7442 | 28774 / 29621 | 93157 / 92550 |
| one replacement, 1x1 | 2412 | 2432 | 355 / 352 | 716 / 686 |
| one replacement, 8x32 | 7998 | 7628 | 28059 / 28687 | 76706 / 81138 |

Heap snapshots were unchanged in every setup: 16.6 MiB for a fresh proxy and 252.5 KiB per joined managed player,
except 268.5 KiB with subscriptions on 10 different IDs. These are snapshots after joining, before relay load;
they are not peak-memory measurements. Windows CPU and RSS measurements are unavailable, so reported zeros
must not be interpreted as measurements. Linux performance remains unverified for this change.

Verification: the 66 plugin unit/integration tests and the delivered-packet milestone regression passed in Debug,
ReleaseSafe and ReleaseFast, using the testing allocator. Formatting, whitespace checks, and the ReleaseSafe
proxy and native examples build passed. The regression cases cover all 16384 valid headers, malformed varints,
replacement validation reuse, split-screen routing, the 64 KiB replacement boundary, spawn cancellation, and
container cleanup after cancellation and transfer.

## Lazy native packet fields

Recorded 2026-10-12 on the same Windows x86_64 machine, 12 logical CPUs, Zig 0.17.0, ReleaseFast.
Before adding the dispatch cache, the codec prototype measured ten independent text decodes at 797.5 ns/packet
and one decode shared by ten readers at 106.6 ns/packet. That comparison justified a dispatch-local cache.

Final command: `zig build bench -Doptimize=ReleaseFast -- packet-dispatch decode --quick`, with other Bifrost
builds and tests stopped. Each dispatch result is the median of seven samples of 200 x 4096 packets, alternating
text and unknown raw packets. Typed listeners only run on the text half. The native codec uses seven samples of
100 x 4096 text packets with varying messages. The output sink consumes only encoded bytes, not unused scratch.

| dispatch setup | ns/packet | added ns/callback |
|---|---|---|
| one raw listener | 31.0 | 60.8 |
| one validated listener | 54.4 | 107.7 |
| ten raw listeners on the hot ID | 158.3 | 31.5 |
| one listener reading lazy fields | 87.0 | 172.8 |
| ten independent decoders | 572.8 | 114.4 |
| ten listeners sharing fields | 329.3 | 65.7 |
| raw replacement | 60.0 | 118.9 |
| typed text modification | 188.0 | 374.9 |

Sharing fields reduces the ten-reader dispatch cost from 572.8 to 329.3 ns/packet in this workload. Typed
modification costs more than raw replacement and exceeds the existing 200 ns/callback replacement budget;
it remains optional. Raw dispatch was 30.0 ns/packet in the previous batch and 31.0 here; validated dispatch
was 53.6 and 54.4. These small differences do not establish a regression or speedup. No-subscription and
phase-mismatch paths remain about 0.5 to 0.6 ns/packet.

| codec-only case | ns/packet |
|---|---|
| raw read | 1.1 |
| one lazy decode | 90.7 |
| ten independent decodes | 901.7 |
| one decode, ten readers | 126.5 |
| raw copy | 4.4 |
| decode and typed re-encode | 196.9 |

The codec takes no allocator. Decoded strings borrow packet memory, and the cache and candidate replacement
view live on the dispatch stack. There is no retained decode cache or global lock. The subscription stores one
additional host-context pointer; the per-ID table's phase flags fit its existing padding. Accepted replacements
keep their existing arena copy. Windows CPU/RSS and Linux network-worker behavior remain unmeasured here.

Verification: full ReleaseSafe tests passed (220 passed, three platform skips); after the final phase-filter
refinement, all 76 plugin tests passed in Debug, ReleaseSafe and ReleaseFast. Tests include every text variant,
signed numeric boundaries, malformed input, output aliasing and transactional failures, old-host SDK behavior,
C/C++ ABI layouts, cached failures, replacement refresh, callback scope, and concurrent worker-local dispatch.
Managed transport tests verify cancellation and edits through compression/encryption, again after a transfer,
and exercise the loaded C++23 example. ReleaseSafe proxy/example builds and formatting checks passed.

## C++ packet filter

Recorded 2026-10-12 on Windows x86_64, 12 logical CPUs, Zig 0.17.0, ReleaseFast.
Command: `zig build bench -Doptimize=ReleaseFast -- packet-dispatch --quick`, with other Bifrost builds and
tests stopped during measurement. Each result is the median of seven samples of 200 x 4096 packets, alternating
text and an unknown 64 B raw packet. Chat cases use matching chat packets and a valid named player handle.

| dispatch setup | ns/packet | added ns/callback |
|---|---|---|
| one raw listener | 28.8 | 57.1 |
| C++ filter passing raw text | 86.2 | 172.0 |
| native listener reading chat fields | 91.8 | 183.1 |
| C++ chat filter with player-name lookup | 93.9 | 187.4 |

Both filter pass paths meet the existing 200 ns/callback budget. These measurements include dispatch, timing,
metrics, decoding and the filter's policy checks; chat includes the real host name lookup. They do not measure
author correction, radius modification or multi-worker name-lookup contention. The plugin owns no heap state,
copies no message bodies on its pass path, and only encodes accepted field changes into the supplied replacement
buffer. Bifrost still copies accepted replacements into its existing batch arena. Windows CPU/RSS were not measured.

Verification: all 26 plugin integration tests passed in ReleaseSafe; 25 packet unit/integration tests passed in
Debug and ReleaseFast. The native C++ checks passed in all three modes, including the 512/513-byte boundary,
author correction, unchanged raw text, radius limits, stale handles, failed decoding/encoding, old-host rejection
and two concurrent callers. The loaded-plugin transport test checks cancellation, preserved fields and radius
caps through compression/encryption, again after transfer. Windows and Linux ReleaseSafe package builds passed;
the Windows package was restored afterward. Formatting and whitespace checks passed. Linux runtime behavior
and Linux network-worker performance remain unverified for this example.

## Native packet injection

Recorded 2026-10-12 on Windows x86_64, 12 logical CPUs, Zig 0.17.0, ReleaseFast.
Command: `zig build bench -Doptimize=ReleaseFast -- injection packet-dispatch --quick`, with other Bifrost builds
and tests stopped. Injection results are medians of seven samples of 500 batches of 32 Text packets, after one
warmup batch. They include strict decoding, copying, queue insertion, drain and free, plus allocation accounting.
The sink performs no session lookup, compression, encryption or network work; these are queue throughput figures.

| packet bytes | ns/packet | packets/s | allocations/packet | queued heap for 32 | retained heap after drain |
|---|---|---|---|---|---|
| 32 | 131.0 | 7,633,588 | 1 | 4,096 B | 0 B |
| 1,024 | 193.6 | 5,165,956 | 1 | 35,840 B | 0 B |
| 16,384 | 884.2 | 1,130,966 | 1 | 527,360 B | 0 B |
| 65,536 | 2,898.9 | 344,961 | 1 | 2,100,224 B | 0 B |

Each queued packet has one allocation containing 96 B of metadata and an exact-size payload. Queue arrays and
plugin/handle storage are allocated before the timed loop and excluded from the heap deltas. The copied-payload
budget is 4 MiB globally, and injections share the existing 1024-item bound with messages and posts. Counters stay
reserved until the allocation is freed. Retained heap is requested live memory, not allocator pages or process RSS.

The same isolated run measured raw dispatch at 27.1 ns/packet, the C++ raw-text filter at 74.3 and the C++ chat
filter at 79.8 (159.1 added ns/callback). The previous raw result was 28.8 and chat was 93.9; these differences
do not establish a speedup. Both filter pass paths remain within their 200 ns/callback budget. Typed modification
remains above that budget at 333.7 added ns/callback. The raw dispatch implementation is unchanged.

Verification: the final full ReleaseSafe suite passed 229 tests with three platform skips. The 18 packet unit
tests and 15 packet integration tests passed in Debug, ReleaseSafe and ReleaseFast, along with native C++ checks.
Coverage includes copied-buffer lifetime, FIFO sends, stale/reused handles, route invalidation, transfer rejection,
initialization publication, byte/count exhaustion, allocation failure, shutdown cleanup, deferred completion chains,
four submitter threads and two worker queues, malformed/truncated input, and the 64 KiB boundary. The managed
transport test delivers packets to player and backend, verifies listener bypass and compressed/encrypted maximum-size
delivery, and checks both injected radius fields replay to the new backend after transfer. C/C++ ABI layout checks,
old-host SDK rejection, formatting, whitespace checks, and Windows/Linux ReleaseSafe builds passed.

Linux runtime behavior, injection transport throughput, lookup scaling, multi-worker network throughput, process
CPU/RSS and allocator page retention were not measured. The supported injection set is Text in both directions and
RequestChunkRadius to the backend; other packet kinds remain unsupported.

## Windows process counters

Recorded 2026-10-12 on Windows x86_64, 12 logical CPUs, Zig 0.17.0, ReleaseFast.
Command: `zig build bench -Doptimize=ReleaseFast -- injection relay --quick`, with other Bifrost builds and tests
stopped. Windows benchmarks previously returned zero for process CPU and resident memory. They now use
[GetProcessTimes](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getprocesstimes)
for kernel plus user CPU time and
[K32GetProcessMemoryInfo](https://learn.microsoft.com/en-us/windows/win32/api/psapi/nf-psapi-getprocessmemoryinfo)
for current and peak working set. Working set includes resident shared pages; peak is the process lifetime peak.
These figures are distinct from requested live heap bytes and are not directly comparable to the earlier WSL2 runs.

Injection wall time remains the median of seven samples of 500 batches of 32. CPU is measured in a separate run
of at least 250 ms per packet size (1000 ms without `--quick`), with time checked between blocks of 2048 packets.
Process sampling occurs outside the packet loops and includes every process thread. CPU accounting resolution and
the different sampling window can make CPU ns/packet differ from the wall-time median. The sink still does no
session lookup, compression, encryption or transport work.

| packet bytes | before, wall ns/packet | after, wall ns/packet | CPU ns/packet | packets/s | resident / peak KiB |
|---|---|---|---|---|---|
| 32 | 166.1 | 165.3 | 136.9 | 6,051,208 | 6,708 / 6,708 |
| 1,024 | 224.9 | 275.2 | 261.4 | 3,634,381 | 6,772 / 6,780 |
| 16,384 | 1,049.3 | 1,190.0 | 1,109.7 | 840,363 | 7,304 / 7,304 |
| 65,536 | 3,434.8 | 3,570.3 | 3,390.8 | 280,091 | 8,896 / 8,912 |

Every size still has one allocation per accepted packet and zero retained payload heap after draining. Queued
heap for 32 packets remains 4,096 / 35,840 / 527,360 / 2,100,224 B. Resident memory covers the entire driver,
including its runtime, buffers and allocator pages. The production injection implementation is unchanged; CPU
probes now run between packet sizes, and these two runs do not establish a production speedup or regression.

The real child proxy's raw-relay benchmark reported 83–94% CPU under load and 0.0% with eight silent players;
100% means one fully occupied core. Working set was 6,956 KiB fresh, 9,920 KiB with eight players and 13,776 KiB
at its lifetime peak. All eight measured relay workloads completed with zero lost messages. These are passthrough
relay measurements, not injection transport throughput.

`zig build bench-test` runs the two process-counter checks: 64-bit FILETIME conversion, including the maximum
counter value, and live CPU/resident-memory sampling after touching 4 MiB. Both passed in Debug, ReleaseSafe and
ReleaseFast. `zig build bench-build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast` compiled both benchmark
binaries. The driver stops and joins its proxy worker task if stats collection or output fails. Failed supported
platform counters propagate an error; unsupported injection CPU/resident fields print `null`. Formatting and
whitespace checks passed. Linux runtime counters, macOS counters, injection network throughput and callback tail
latency remain unmeasured in this batch.

## Session memory snapshots

The benchmark now reads session memory from Bifrost's atomic stats. Each owning worker publishes its listener
quota after a turn and during shutdown; the previous atomic read raced with RakNet's non-atomic quota writes.
Session and total heap samples can represent different instants. This change adds no locks or allocations.

On Windows x86_64, `zig build bench -Doptimize=ReleaseFast -- connections --quick` completed both waves at
100 and 500 players with every player joined. Session memory was 86.4 KiB/player at both sizes. Three reconnect
churn rounds had zero failed operations and the same 4,657,709 B live heap after each round. These figures do not
establish a throughput improvement or prove the absence of all leaks; retained allocator pages and listener table
capacity remain distinct from live per-player allocations.

The lifecycle regression checks two connect/disconnect cycles and exact quota equality after worker shutdown.
It passed in Debug, ReleaseSafe and ReleaseFast. The full ReleaseSafe suite passed 231 tests with three platform
skips, and both Linux ReleaseFast benchmark binaries compiled. Linux runtime and multi-worker network behavior
were not exercised in this batch. Formatting and whitespace checks passed.

## Worker link index

Recorded 2026-10-12 on Windows x86_64, Zig 0.17.0, ReleaseFast, with other builds and tests stopped.
Command before and after: `zig build bench -Doptimize=ReleaseFast -- links --quick`. Each result is the median
of seven samples of 65,536 calls through `Proxy.packet`, after 4,096 warmup calls. Both runs use the same seeded
uniform sequence of live IDs and contiguous Link allocations. Links have no managed session: the measurement
covers worker lookup and the unsupported check, excluding queue validation, copying, compression, encryption,
and network delivery. The benchmark rejects missing links and any allocation during lookup.

| live links | list ns/lookup | index ns/lookup | index lookups/s | index heap B |
|---|---|---|---|---|
| 1 | 3.6 | 4.1 | 242,725,926 | 272 |
| 64 | 46.8 | 9.2 | 109,063,072 | 2,052 |
| 512 | 401.4 | 8.2 | 122,337,129 | 16,644 |
| 4,096 | 3,627.5 | 11.0 | 90,757,513 | 131,332 |

The worker now owns one standard-library array hash map instead of an intrusive linked list. Packet delivery,
messages, and transfer requests share its lookup. The table adds the gross heap shown above; Link allocations
are excluded, and their intrusive list node has been removed. Capacity grows with peak live links, is reused
across disconnects, and is freed on proxy destruction. No locks or allocations were added to lookup. These are
lookup microbenchmarks, not injection transport throughput; the one-link result does not establish an improvement.

Registration reserves table capacity before callbacks or asynchronous connection work. Internal IDs are consumed
before callbacks, including on failed connections, and exhaustion returns an error instead of wrapping. This
prevents an old queued transfer request from finding a later player under a reused ID. The ID regression failed
with the former update order and passed with the fix.

The three worker regression tests passed in Debug, ReleaseSafe, and ReleaseFast. They cover rejected connections,
ID exhaustion, lookup after table growth/removal and address reuse, and cleanup at every allocation failure during
registration. The full ReleaseSafe suite passed 234 tests with three platform skips, including existing managed
injection, transfer, disconnect, and shutdown checks. Native and Linux ReleaseFast benchmark binaries compiled;
Linux runtime and multi-worker network behavior were not tested. Formatting and whitespace checks passed.

## Injection scheduler notifications

The injection benchmark now attaches the actual scheduler wake notifier. Each batch checks that the event was
set, resets it before draining, and verifies the exact delivered count. Earlier injection queue measurements
omitted notification work. The sink still performs no session lookup, compression, encryption, or network send;
no worker is suspended on the event, so this does not measure a cross-thread wakeup or its latency.

Recorded 2026-10-12 on Windows x86_64, Zig 0.17.0, ReleaseFast. Command:
`zig build bench -Doptimize=ReleaseFast -- injection`, with other builds and tests stopped. Wall time is the median
of seven samples of 5,000 batches of 32. CPU is sampled separately for at least one second per packet size.

| packet bytes | wall ns/packet | CPU ns/packet | packets/s | allocations/packet | queued heap for 32 | retained payload heap |
|---|---|---|---|---|---|---|
| 32 | 166.1 | 162.5 | 6,018,680 | 1 | 4,096 B | 0 B |
| 1,024 | 205.0 | 200.5 | 4,878,376 | 1 | 35,840 B | 0 B |
| 16,384 | 1,048.2 | 1,044.2 | 954,061 | 1 | 527,360 B | 0 B |
| 65,536 | 3,058.3 | 3,170.7 | 326,981 | 1 | 2,100,224 B | 0 B |

Notifying only on an empty-to-nonempty queue transition was evaluated and rejected. Its wall times were
156.6 / 208.7 / 1,052.9 / 2,979.9 ns, while two runs of the existing behavior measured
151.8 / 243.8 / 1,038.6 / 3,038.2 and 166.1 / 205.0 / 1,048.2 / 3,058.3 ns. These results do not establish a
consistent speedup. Production queue behavior is unchanged. All four final benchmark cases completed with
the expected delivery, wake, allocation, and retained-heap checks; formatting and whitespace checks passed.
Linux compilation/runtime and concurrent notification throughput were not checked in this batch.

## Managed observer memory

Recorded 2026-10-13 on Windows x86_64, Zig 0.17.0, ReleaseFast, with other builds and tests stopped.
Managed workers now omit the passthrough observer pool and links omit observer initialization. Both directions
already use the managed session exclusively. Passthrough observation and authentication retain their own pool.
The benchmark's observer-pool counter reports zero in managed mode; it excludes the separate managed pool.

Fresh-process snapshots use the benchmark proxy with `proxy 1 500 1000 <mode> 9`, send `stats\n`, then close stdin.
Each mode was sampled in three independent processes before and after the change, with no players joined.
Every sample in each group had the exact tracked heap below, and every child exited successfully.

| mode | live heap before | live heap after | observer storage before | observer storage after |
|---|---|---|---|---|
| passthrough | 4,655,653 B | 4,655,661 B | 2,621,440 B | 2,621,440 B |
| managed | 17,386,111 B | 14,699,103 B | 2,621,440 B | 0 B |

Managed workers remove two allocations: 2.5 MiB of receive storage and its slot metadata, including 64 KiB of
decompression history. After the optional pool's 8 B presence tag, the net reduction is 2,687,008 B per worker.
This is allocated heap, not resident memory: the median managed working set was 6,176 KiB before and 6,188 KiB
after, so these fresh-process samples show no resident-memory reduction. The shared Link layout still reserves
space for either mode's observer; removing initialization does not establish a per-player heap improvement.

The regression checks pool presence, each link's mode, the observer's stable pool pointer, and cleanup at every
allocation failure during proxy and link creation in both modes. It passed in Debug, ReleaseSafe, and ReleaseFast.
The full ReleaseSafe suite passed 235 tests with three platform skips, including managed login allocation failures,
injection, transfers, disconnects, and passthrough authentication. Native and Linux ReleaseFast benchmark binaries
compiled. Linux runtime and multi-worker network behavior were not exercised.

Before and after: `zig build bench -Doptimize=ReleaseFast -- managed --quick`, three 500 ms iterations after
300 ms warmup, one worker, four driver threads. All 40 relay workloads completed in both runs. Selected results
for the managed relay with matching compression and no plugins:

| payload / load | trips/s before / after | p50 us before / after | p99 us before / after | CPU before / after |
|---|---|---|---|---|
| 256 B / 1x1 | 3,412 / 3,276 | 244 / 246 | 408 / 483 | 55% / 59% |
| 256 B / 8x32 | 11,422 / 11,916 | 19,654 / 19,041 | 39,883 / 41,151 | 97% / 94% |
| 20 KiB / 1x1 | 302 / 316 | 3,186 / 3,092 | 3,871 / 3,876 | 66% / 70% |
| 20 KiB / 8x12 | 630 / 762 | 116,750 / 100,351 | 400,572 / 293,930 | 90% / 86% |

Throughput is the median of the three iterations; latency percentiles combine their samples. CPU 100% is one
occupied core. These short runs have mixed throughput and tail-latency changes and do not establish a speedup.
The measured improvement is the worker's allocated heap. Formatting and whitespace checks passed.

## Final native packet API verification

Recorded 2026-10-13 on Windows x86_64 with Zig 0.17.0. The final review covered callback-scoped decoding,
replacement invalidation, queue bounds and ownership, stale handles, transfers, shutdown, ABI layouts and the
C++ packet filter. It found missing cleanup when a producer thread failed to start in the concurrency tests.
Those tests now stop and join started producers before releasing shared state, and limit delivery waits to five
seconds. A regression forces failure at each of four startup positions for both posts and packet injections;
all eight cases passed using the leak-detecting test allocator. The C++ test uses joining thread ownership.

`zig build test -Doptimize=ReleaseSafe --summary all` and the corresponding ReleaseFast command each passed
242 of 245 Zig tests, with three Windows platform skips, and ran the C++ filter checks successfully.
`zig build bench-test -Doptimize=ReleaseSafe --summary all` passed all four benchmark checks. ReleaseFast
`zig build` compiled and packaged the proxy, Zig maintenance plugin, C++ greeter and C++ packet filter for
both native Windows and `x86_64-linux-gnu`. Formatting and whitespace checks passed.

Linux runtime, network behavior with several reuse-port workers, injection transport throughput and callback
tail latency remain unmeasured. The earlier codec, dispatch, injection queue and heap measurements retain their
stated scope; this verification does not establish a new performance result or the absence of all races or leaks.

## Native packet API recheck

Recorded 2026-10-14 on Windows x86_64, 12 logical CPUs, Zig 0.17.0, ReleaseFast.
Command: `zig build bench -Doptimize=ReleaseFast -- decode packet-dispatch injection --quick`.
The API was already implemented on `main`; this change adds a typed replacement-chain regression and a raw
C++ access example in the ABI documentation. Production dispatch, codecs, queue behavior and ABI layouts are unchanged.
These are current measurements, not a before/after performance comparison.

| case | codec-only ns/packet | dispatch ns/packet |
|---|---|---|
| raw access | 1.2 | 28.4 |
| lazy typed decode | 79.5 | 88.6 |
| ten independent decoders | 806.7 | 509.0 |
| ten readers sharing fields | 114.4 | 287.8 |
| raw replacement | 3.6 | 60.8 |
| typed replacement | 179.3 | 176.4 |

Each result is the median of seven samples. Codec samples process 100 x 4096 Text packets; dispatch samples
process 200 x 4096 packets alternating Text and an unknown raw packet. Codec and dispatch columns therefore
have different workloads and must not be subtracted. Sharing reduced the measured ten-reader dispatch cost by
43.5%. Typed replacement remains above the existing 200 ns/callback budget at 352.4 added ns/callback.
The codec has no allocator, its views borrow packet bytes, and its cache lives on the dispatch stack.

| injected bytes | ns/packet | packets/s | CPU ns/packet | allocations/packet | queued heap for 32 | retained heap after drain | resident KiB | peak resident KiB |
|---|---|---|---|---|---|---|---|---|
| 32 | 130.3 | 7,674,597 | 142.0 | 1 | 4,096 B | 0 B | 7,500 | 7,732 |
| 1,024 | 213.9 | 4,676,175 | 161.4 | 1 | 35,840 B | 0 B | 7,100 | 7,732 |
| 16,384 | 872.0 | 1,146,838 | 1,049.9 | 1 | 527,360 B | 0 B | 7,628 | 7,732 |
| 65,536 | 3,407.4 | 293,477 | 2,774.3 | 1 | 2,100,224 B | 0 B | 9,216 | 9,216 |

Injection timings cover validation, copying, queue insertion, scheduler notification, wake reset, draining and
freeing, using seven samples of 500 batches of 32 packets. CPU is sampled separately over at least 250 ms.
Heap figures exclude setup allocations and measure requested live memory, while resident figures cover the
whole process. The sink does no compression, encryption or network work. Transport throughput, callback tail
latency, Linux runtime and multi-worker network behavior remain unmeasured in this run.

Verification: the full ReleaseSafe suite passed 247 of 250 Zig tests with three platform skips. The focused
packet suite passed all 34 tests in Debug and ReleaseFast. All three runs passed the native C++ filter checks.
The new regression chains three typed replacements across both scratch buffers, rejects a malformed fourth
replacement, and checks that later listeners, including a validated listener, retain the third version with shared decoding.
The documented raw callback compiled as C++23 with `-Wall -Wextra -Werror`. Repository formatting and
whitespace checks passed. No full Debug/ReleaseFast suite or cross-platform build was run for this recheck.

## Managed packet injection transport

Recorded 2026-10-14 on Windows x86_64, 12 logical CPUs, Zig 0.17.0, ReleaseFast, four driver threads and
one proxy worker. Command: `zig build bench -Doptimize=ReleaseFast -- injection-transport --quick`.
The driver authenticates eight managed sessions against a real child proxy and encrypted echo backend.
A native packet callback cancels each incoming Text packet and submits a copied packet through `send_packet`.
The player target replies directly; the backend target traverses the backend injection path and returns through
the normal backend relay. These are verified request/reply rates, not isolated injection queue throughput.

| target | packet bytes | load | replies/s median [min-max] | p50 us | p95 us | p99 us | proxy CPU % | resident KiB | peak resident KiB |
|---|---|---|---|---|---|---|---|---|---|
| player | 32 | 1x1 | 7,568 [7,452-7,586] | 89 | 143 | 247 | 72.9 | 9,848 | 9,848 |
| player | 32 | 8x32 | 20,820 [19,512-22,772] | 12,316 | 14,096 | 14,837 | 98.6 | 9,880 | 9,880 |
| player | 1,024 | 1x1 | 3,280 [3,278-3,370] | 246 | 304 | 445 | 78.1 | 9,904 | 9,904 |
| player | 1,024 | 8x32 | 10,562 [10,538-10,934] | 18,886 | 66,825 | 77,096 | 89.8 | 11,240 | 11,240 |
| player | 16,384 | 1x1 | 638 [608-656] | 1,483 | 1,799 | 2,121 | 70.7 | 11,320 | 11,320 |
| player | 16,384 | 8x16 | 1,164 [1,148-1,182] | 96,375 | 184,442 | 248,018 | 98.5 | 12,508 | 13,180 |
| player | 65,536 | 1x1 | 154 [152-158] | 6,382 | 6,915 | 7,119 | 70.3 | 12,772 | 13,180 |
| player | 65,536 | 8x4 | 266 [262-268] | 98,268 | 201,765 | 252,248 | 90.1 | 12,996 | 13,772 |
| backend | 32 | 1x1 | 4,062 [3,860-4,092] | 201 | 266 | 347 | 72.9 | 9,324 | 9,324 |
| backend | 32 | 8x32 | 16,042 [14,994-16,792] | 15,903 | 18,116 | 18,708 | 99.2 | 9,396 | 9,396 |
| backend | 1,024 | 1x1 | 2,252 [2,234-2,276] | 394 | 465 | 647 | 72.9 | 9,424 | 9,424 |
| backend | 1,024 | 8x32 | 7,856 [7,798-8,010] | 25,582 | 74,791 | 104,813 | 96.7 | 10,872 | 10,872 |
| backend | 16,384 | 1x1 | 386 [378-388] | 2,548 | 2,789 | 2,928 | 63.3 | 10,964 | 10,964 |
| backend | 16,384 | 8x16 | 808 [774-836] | 129,632 | 225,997 | 300,226 | 94.5 | 11,900 | 12,944 |
| backend | 65,536 | 1x1 | 90 [90-92] | 10,896 | 11,851 | 12,013 | 60.5 | 12,280 | 12,944 |
| backend | 65,536 | 8x4 | 196 [190-202] | 129,499 | 255,400 | 298,888 | 95.6 | 13,164 | 13,904 |

Throughput is the median of three 500 ms intervals after 300 ms warmup. Latency runs from before driver
encoding through reply decoding and content checks. Percentiles combine the intervals' samples, including
replies drained after each interval; throughput excludes those late replies. Every submitted
request must receive exactly one ordered reply with the expected message fields and per-player content, or the
run fails. Outstanding replies have a three-second drain deadline. Sample storage is bounded and exhaustion
fails the run. Printable pseudorandom message bodies permit strict UTF-8 decoding, with deflate above 256 B
and encryption enabled. Each player has at most the stated number of requests in flight.

CPU and memory cover the child proxy only, excluding driver and backend work on the same host. CPU includes
the measured intervals, draining and sample collection; 100% is one core. Resident memory is sampled after each
case and peak memory covers the lifetime of that destination's proxy. The separate queue benchmark measures
allocation counts. These short loopback measurements do not establish network capacity or a speedup.
Production packet handling and the native ABI are unchanged.

The same command and workload also passed on WSL2 Ubuntu, Linux 6.6.87.2-microsoft-standard-WSL2, x86_64,
12 logical CPUs and Zig 0.17.0. The compiler cache was placed on the Linux filesystem with
`--cache-dir /tmp/bifrost-injection-cache-20261014` after an artifact rename was denied in the OneDrive-backed
Windows cache. All sixteen Linux cases verified exact delivery, order and content.

| target | packet bytes | load | replies/s median [min-max] | p50 us | p95 us | p99 us | proxy CPU % | resident KiB | peak resident KiB |
|---|---|---|---|---|---|---|---|---|---|
| player | 32 | 1x1 | 10,222 [9,704-10,234] | 77 | 124 | 228 | 82.1 | 6,912 | 6,912 |
| player | 32 | 8x32 | 56,170 [55,880-56,636] | 4,346 | 5,925 | 8,615 | 92.0 | 7,168 | 7,168 |
| player | 1,024 | 1x1 | 3,438 [3,416-3,492] | 242 | 329 | 505 | 65.3 | 7,168 | 7,168 |
| player | 1,024 | 8x32 | 14,698 [14,086-14,920] | 16,000 | 27,819 | 40,866 | 85.4 | 8,064 | 8,064 |
| player | 16,384 | 1x1 | 914 [898-980] | 997 | 1,273 | 1,494 | 58.0 | 8,192 | 8,192 |
| player | 16,384 | 8x16 | 1,640 [1,636-1,644] | 69,933 | 110,140 | 127,818 | 93.6 | 9,216 | 9,344 |
| player | 65,536 | 1x1 | 222 [218-226] | 4,345 | 5,022 | 5,182 | 53.7 | 9,472 | 9,472 |
| player | 65,536 | 8x4 | 386 [370-394] | 70,381 | 127,284 | 149,493 | 92.4 | 9,744 | 10,308 |
| backend | 32 | 1x1 | 4,038 [3,830-4,070] | 226 | 319 | 537 | 75.1 | 7,040 | 7,040 |
| backend | 32 | 8x32 | 30,154 [26,546-30,406] | 8,462 | 12,019 | 13,598 | 94.5 | 7,424 | 7,424 |
| backend | 1,024 | 1x1 | 1,934 [1,892-1,970] | 467 | 631 | 867 | 63.4 | 7,424 | 7,424 |
| backend | 1,024 | 8x32 | 12,306 [12,144-12,394] | 19,188 | 31,634 | 39,867 | 94.6 | 8,832 | 8,832 |
| backend | 16,384 | 1x1 | 598 [598-600] | 1,590 | 2,015 | 2,218 | 51.8 | 8,960 | 8,960 |
| backend | 16,384 | 8x16 | 1,256 [1,232-1,320] | 87,234 | 143,431 | 165,172 | 93.1 | 10,624 | 10,624 |
| backend | 65,536 | 1x1 | 136 [134-138] | 7,172 | 7,875 | 8,206 | 44.5 | 10,880 | 10,880 |
| backend | 65,536 | 8x4 | 294 [290-298] | 91,005 | 156,106 | 198,568 | 91.7 | 11,384 | 11,704 |

WSL scheduling, filesystem and networking differ from native Windows and bare-metal Linux. These separate
platform runs do not establish a production throughput advantage. Multi-worker transport throughput and
isolated callback latency remain unmeasured by this scenario.

Verification: Windows `bench-test` passed all six checks in Debug, ReleaseSafe and ReleaseFast. Linux
`zig build test bench-test -Doptimize=ReleaseSafe --summary all`, using the Linux cache above, passed 255 of
256 checks: 249 repository tests and six benchmark tests. The skipped test checks rejection of multiple workers
on platforms without reuse-port support; Linux reuse-port distribution, admission and shutdown tests passed.
The native C++ filter checks passed on Linux. The benchmark regressions check truncated, reordered, altered and
duplicate replies, exclude drained replies from throughput while retaining their latency, and force allocation
failure at all ten job-initialization positions with the leak-detecting test allocator. Formatting and final
whitespace checks passed.

## Injection across Linux workers

Recorded 2026-10-14 on WSL2 Ubuntu, Linux 6.6.87.2-microsoft-standard-WSL2, x86_64, 12 logical CPUs,
Zig 0.17.0, ReleaseFast, eight driver threads and work-stealing scheduling.
Command: `zig build bench -Doptimize=ReleaseFast --cache-dir /tmp/bifrost-injection-cache-20261014 -- injection-workers --quick --driver-threads 8`.

Each destination uses a fresh proxy and encrypted echo backend for each worker count. All rows use the same
32 players, one request in flight per player, deflate above 256 B, and the existing validated native injection
queue. The kernel chooses each connection's reuse-port worker. The benchmark verifies that every configured
worker owns at least one of the 32 connections and every player completes a verified exchange in every measured
iteration, including drain. Throughput counts only replies received before that iteration's timed deadline.
Per-player tags in the sequence stamp detect misrouting even in the smallest 32-byte packet. The sequence is
bounded before its 24-bit counter can wrap. Production packet handling and the ABI are unchanged.

| workers | target | packet bytes | replies/s median [min-max] | p50 us | p95 us | p99 us | proxy CPU % | resident KiB | peak resident KiB | players per worker |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | player | 32 | 15,431 [15,198-15,651] | 2,058 | 2,371 | 2,612 | 94.2 | 11,904 | 11,904 | 32 |
| 1 | player | 1,024 | 8,857 [8,733-8,942] | 3,577 | 3,987 | 4,246 | 92.0 | 11,904 | 11,904 | 32 |
| 1 | player | 16,384 | 1,878 [1,852-1,895] | 8,182 | 55,553 | 172,473 | 88.5 | 13,568 | 13,568 | 32 |
| 1 | player | 65,536 | 394 [392-395] | 64,751 | 197,807 | 268,477 | 89.0 | 15,260 | 15,700 | 32 |
| 1 | backend | 32 | 8,663 [8,182-8,895] | 3,680 | 4,966 | 5,545 | 94.1 | 12,032 | 12,032 | 32 |
| 1 | backend | 1,024 | 5,886 [4,893-6,216] | 5,476 | 7,617 | 9,739 | 93.8 | 12,160 | 12,160 | 32 |
| 1 | backend | 16,384 | 1,235 [1,189-1,335] | 14,563 | 105,203 | 178,863 | 86.5 | 14,848 | 14,848 | 32 |
| 1 | backend | 65,536 | 307 [304-309] | 84,071 | 228,004 | 389,916 | 90.1 | 20,216 | 20,748 | 32 |
| 2 | player | 32 | 28,857 [27,955-32,561] | 828 | 2,074 | 2,953 | 148.8 | 13,312 | 13,312 | 16 / 16 |
| 2 | player | 1,024 | 18,567 [18,096-18,596] | 1,637 | 2,331 | 2,686 | 187.8 | 13,312 | 13,312 | 16 / 16 |
| 2 | player | 16,384 | 3,623 [3,606-3,670] | 7,732 | 9,730 | 18,755 | 176.4 | 14,848 | 14,848 | 16 / 16 |
| 2 | player | 65,536 | 746 [744-778] | 36,086 | 84,063 | 192,886 | 175.7 | 18,132 | 18,840 | 16 / 16 |
| 2 | backend | 32 | 16,207 [15,560-16,878] | 1,793 | 3,715 | 4,855 | 167.4 | 13,184 | 13,184 | 10 / 22 |
| 2 | backend | 1,024 | 10,727 [10,647-10,764] | 2,852 | 5,242 | 6,189 | 162.9 | 13,312 | 13,312 | 10 / 22 |
| 2 | backend | 16,384 | 1,796 [1,692-1,876] | 14,316 | 28,194 | 167,872 | 126.8 | 16,128 | 16,128 | 10 / 22 |
| 2 | backend | 65,536 | 346 [316-361] | 81,763 | 175,359 | 264,293 | 124.5 | 21,788 | 22,216 | 10 / 22 |
| 4 | player | 32 | 60,542 [60,232-65,739] | 419 | 1,016 | 1,525 | 317.8 | 14,848 | 14,848 | 10 / 4 / 8 / 10 |
| 4 | player | 1,024 | 30,699 [30,266-31,423] | 956 | 1,834 | 2,513 | 346.6 | 14,848 | 14,848 | 10 / 4 / 8 / 10 |
| 4 | player | 16,384 | 5,803 [5,641-5,894] | 5,815 | 8,332 | 11,996 | 370.2 | 16,256 | 16,256 | 10 / 4 / 8 / 10 |
| 4 | player | 65,536 | 1,273 [1,242-1,335] | 21,007 | 47,593 | 110,314 | 367.6 | 22,656 | 23,288 | 10 / 4 / 8 / 10 |
| 4 | backend | 32 | 21,305 [19,940-23,438] | 1,387 | 2,613 | 3,861 | 294.7 | 14,720 | 14,720 | 12 / 11 / 7 / 2 |
| 4 | backend | 1,024 | 9,094 [8,985-11,051] | 3,109 | 5,280 | 8,513 | 263.7 | 14,848 | 14,848 | 12 / 11 / 7 / 2 |
| 4 | backend | 16,384 | 1,665 [1,631-1,777] | 12,057 | 60,695 | 123,124 | 178.6 | 18,176 | 18,176 | 12 / 11 / 7 / 2 |
| 4 | backend | 65,536 | 357 [347-370] | 76,488 | 158,747 | 238,934 | 144.6 | 23,280 | 24,160 | 12 / 11 / 7 / 2 |

Rates are medians of three two-second intervals after 300 ms warmup. CPU, memory, latency and drain accounting
use the same definitions as the transport benchmark above. The worker scenario uses at least two seconds per
interval even with `--quick`. Preliminary 500 ms runs exposed an overly strict progress check that rejected
players whose valid replies arrived during drain. Progress now requires a verified exchange per player per
iteration, including drain, while late replies remain excluded from throughput. The comparison bounds request
packets in flight to 2 MiB at the largest size. All 24 recorded cases passed order, content, identity and delivery checks.

The direct-player 32-byte rate rose from 15,431 replies/s with one worker to 60,542 with four in this run.
Backend scaling was mixed: the 1 KiB result was lower with four workers than with two. Kernel-selected connection
distribution, WSL scheduling and the shared driver/echo-backend host are part of this workload; their individual
effects are not isolated. These are measurements of this setup, not a general capacity or speedup claim.
Isolated callback latency remains unmeasured.

Verification: all seven benchmark checks passed in Debug, ReleaseSafe and ReleaseFast on Windows and in
ReleaseSafe on Linux. They cover missing/empty workers, incorrect or overflowing connection totals, wrong-player
replies including the 32-byte case, order/content/duplicate checks, drained-only reply accounting and allocation
failure cleanup. The existing single-worker transport matrix also passed all sixteen Windows ReleaseFast cases
after the drain-accounting correction, and the worker scenario explicitly skipped its unsupported Windows mode.
The full repository test suite was not rerun for this benchmark-only change. Formatting and final whitespace
checks passed.
