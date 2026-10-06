# Bifrost

A Minecraft: Bedrock Edition reverse proxy written in Zig 0.17.0.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/bifrost
```

Settings live in [`config/bifrost.toml`](config/bifrost.toml).

## Session modes

`passthrough` (the default) relays each player's own encrypted session byte for byte.

`managed` ends the player's session at Bifrost and opens a separate one to the backend:

- Players must pass Microsoft authentication (`[auth] mode = "verify"`) before Bifrost speaks for them.
- Bifrost logs in to backends with a certificate chain signed by its proxy key (`proxy_key_file`, created on first
  start and logged). The identity carries the player's name and UUID, `online = false` and no XUID: it never claims
  to be Microsoft-authenticated, and the player's Microsoft token never reaches a backend.
- A backend must trust exactly that key as its issuer and keep offline logins disabled. A backend that does not
  will refuse managed players.

Managed players can be moved between backends with `Proxy.requestTransfer` or from a plugin. Bifrost logs in to the
target while the player stays on the old backend, and only switches once the target has started the game. Anything
that fails before the switch leaves the player where they were. The switch clears what the old backend left on the
client and moves it across with a dimension change, so the new world arrives without stale chunks.

`[transfer] content = "initial"` keeps the packs the player accepted from their first backend for the whole session;
Bifrost answers each target's pack negotiation itself. `"match"` also refuses targets whose packs differ.

## Plugins

Native plugins are shared libraries listed under `[[plugin]] path = "..."`. They load at startup, in order, and
unload in reverse once every worker has stopped. A plugin exports `bifrost_plugin_init` and talks to Bifrost only
through the C ABI in [`include/bifrost_plugin.h`](include/bifrost_plugin.h); Zig plugins can use the `bifrost_plugin`
module instead. [`examples/maintenance.zig`](examples/maintenance.zig) is built with `zig build` and keeps players
off any backend named `maintenance`.

Plugins get lifecycle and transfer events, can cancel or redirect a transfer before it starts, and can request
transfers themselves. In managed mode they can also hook individual packets (pass, cancel or replace), register
commands, send players chat messages and run slow work on task threads. Callbacks run on worker threads and must not
block; callbacks slower than `[limits] slow_plugin_callback_ms` are logged. Player handles stop working once the
player leaves.

## Development

```sh
zig build test                        # unit and integration tests
zig build test -Doptimize=ReleaseSafe
```

| path | contents |
|---|---|
| `src/` | the proxy, one folder per subsystem |
| `include/`, `examples/` | the plugin C header and an example plugin |
| `tests/integration/` | end-to-end tests against real RakNet peers |
| `tests/support/` | fake players, backends and fixtures shared by tests and benchmarks |
| `tests/bench/` | the benchmark suite and its baseline |

## Benchmarks

```sh
zig build bench -Doptimize=ReleaseFast                          # full suite, about 5 minutes
zig build bench -Doptimize=ReleaseFast -- relay workers --quick # pick scenarios, shorter runs
zig build bench -Doptimize=ReleaseFast -Dscheduling=pinned      # proxy without ZIO work stealing
zig build bench -Doptimize=ReleaseFast -- managed               # passthrough vs managed sessions
```

[`tests/bench/baseline.md`](tests/bench/baseline.md) records the numbers later changes are compared against.

The suite starts the real proxy (`Workers` on the same runtime as `bifrost`) as a child process, and drives it with
RakNet clients and echo backends from the parent. Scenarios: `relay`, `managed`, `handshake`, `connections`, `workers`,
`backends`, `plugins`.
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
