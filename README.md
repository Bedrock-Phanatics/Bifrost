# Bifrost

A Minecraft: Bedrock Edition reverse proxy written in Zig 0.16.0.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/bifrost
```

Settings live in [`config/bifrost.toml`](config/bifrost.toml).

## Benchmarks

```sh
zig build bench -Doptimize=ReleaseFast                          # full suite, about 4 minutes
zig build bench -Doptimize=ReleaseFast -- relay workers --quick # pick scenarios, shorter runs
```

The suite starts the real proxy (`Workers` on the same runtime as `bifrost`) as a child process, and drives it with
RakNet clients and echo backends from the parent. Scenarios: `relay`, `handshake`, `connections`, `workers`, `backends`.
RSS, CPU and kernel drop counts need Linux; elsewhere only the single-worker numbers are meaningful.

Representative results from one run: WSL2 Ubuntu on 12 logical CPUs, ReleaseFast, loopback, with the clients and
backends on the same machine as the proxy. Treat them as relative numbers, not capacity planning.

| workload | result |
|---|---|
| raw relay, 512 B, 1 message in flight | 8.8k round trips/s, p50 89 us, p99 213 us |
| raw relay, 512 B, 8 players x 32 in flight, 1 worker | 41k round trips/s (20 MiB/s each way), proxy at one full core |
| raw relay, 20 KiB fragmented, 8 players x 12 in flight | 3.0k round trips/s, 59 MiB/s each way |
| workers 1 / 2 / 4 / 8, 64 players, 512 B | 29k / 61k / 103k / 153k round trips/s |
| handshake observer (16 KiB Login) | +0.8 ms per join at p50, 1.34x relaying the same bytes raw |
| joins (connect + handshake + echo), 64 in flight | about 1,000 to 1,600 per second |
| reconnect churn, 32 clients | about 1,700 cycles/s; live heap identical after every round |
| memory per connected player | about 225 KiB RSS; heap is 85 KiB RakNet session + 181 KiB backend client, Link and Tap |
| idle proxy | 3.6 MiB RSS, 0% CPU with connected but silent players |
| backend hangs after its health check | first player joins in 1.0 s (one timed-out dial), the rest in 1.4 ms |

On Linux, `net.core.rmem_max` (often 208 KiB) silently caps the 4 MiB receive buffer RakNet asks for. Bursts of joins
or leaves then overflow it: the bench reports these drops, and they show up as about 500 ms RakNet retries on joins
and leaves only cleaned up by the 10 s idle timeout. Raise `net.core.rmem_max` on real deployments.
