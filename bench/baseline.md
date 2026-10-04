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

## ReleaseSafe

`-- --quick`, Zig 0.17, work_stealing: relay 512 B 1x1 8554 round trips/s (p50 91 us, p99 221 us), 8 KiB 8x32 23.8 MiB/s,
observed handshake p50 9456 us, 400 joins/s at 500 players, churn 582 to 732 cycles/s with no failures,
328 KiB RSS per held player at 500 players, workers 1 / 2 / 4 / 8 at 27k / 55k / 105k / 144k round trips/s.

## Windows

Windows 11, same machine, ReleaseFast, Zig 0.17: relay 512 B 1x1 5076 round trips/s (p50 155 us, p99 303 us),
1149 joins/s with 1 healthy backend, churn 307 to 836 cycles/s. RSS, CPU and multiple workers are Linux only.
