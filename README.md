# Bifrost

A Minecraft: Bedrock Edition reverse proxy written in Zig 0.17.0.

```sh
zig build -Doptimize=ReleaseSafe
./zig-out/bin/bifrost
```

Settings live in [`config/bifrost.toml`](config/bifrost.toml). More than one `workers` needs Linux (`SO_REUSEPORT`).

## Compatibility

No backend has been checked with a real Bedrock client yet, so none are listed as supported. Backends go here once
they pass that testing; until then the only evidence is the automated tests, which run against Bifrost's own fake
RakNet players and backends.

## Session modes

`passthrough` (the default) relays each player's own encrypted session byte for byte. It works with any game version,
but Bifrost can't see inside the session: there are no transfers, packet hooks, plugin commands or chat messages, and
plugins only hear about connects, backend choices and disconnects.

`managed` ends the player's session at Bifrost and opens a separate one to the backend. It only speaks Minecraft
1.26.51 (protocol 2193), and players on any other version are turned away:

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
player leaves. [`docs/plugin-abi.md`](docs/plugin-abi.md) has the full contract: threads, memory, every host
function and its statuses, and how the frozen v1 ABI may grow. Plugins run in-process, so one that crashes takes
the proxy down.

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
RakNet clients and echo backends from the parent. Scenarios: `relay`, `fairness`, `managed`, `deflate`, `plugins`,
`ids`, `tasks`, `handles`, `handshake`, `connections`, `workers`, `backends`.
RSS, CPU and kernel drop counts need Linux; elsewhere only the single-worker numbers are meaningful.

Results from one run (2026-10-06): WSL2 Ubuntu on 12 logical CPUs, ReleaseFast, 1 worker, loopback, with the clients
and backends on the same machine as the proxy. Treat them as relative numbers, not capacity planning. The baseline
file has the full tables, including plugin dispatch costs and the scheduling and fairness audit.

| workload | result |
|---|---|
| raw relay, 512 B, 1 message in flight | 9.2k round trips/s, p50 85 us, p99 194 us |
| raw relay, 512 B, 8 players x 32 in flight | 47.7k round trips/s (23 MiB/s each way), proxy at one full core |
| raw relay, 20 KiB fragmented, 8 players x 12 in flight | 3.2k round trips/s, 63 MiB/s each way |
| managed relay, 512 B, 1 message in flight | 2.6k round trips/s, p50 350 us, p99 593 us |
| managed relay, 512 B, 8 players x 32 in flight | 11.0k round trips/s |
| joins | 1.4 ms per player passthrough, 14.3 ms managed |
| transfer, one player | p50 33.6 ms, p99 36.9 ms; live heap flat over 200 transfers |
| transfers, 8 players at once | whole batch in p50 80.5 ms, p99 90.8 ms; live heap flat over 50 rounds |
| memory per connected player | 218.5 KiB RSS passthrough; 252.5 KiB heap managed |
| reconnect churn, 32 clients | about 1,400 cycles/s; live heap identical after every round |
| idle proxy | 4.0 MiB RSS, 0% CPU with connected but silent players |

On Linux, `net.core.rmem_max` (often 208 KiB) silently caps the 4 MiB receive buffer RakNet asks for. Bursts of joins
or leaves then overflow it: the bench reports these drops, and they show up as about 500 ms RakNet retries on joins
and leaves only cleaned up by the 10 s idle timeout. Raise `net.core.rmem_max` on real deployments.
