# Bifrost

A high-performance Minecraft: Bedrock Edition proxy written in Zig, designed for efficiency, extensibility, and low-latency networking.

Bifrost speaks NetherNet, the WebRTC transport Bedrock uses for direct connections, on both sides: players join it
like any server, and it reaches its backends the same way. It is built on
[nethernet-zig](https://github.com/Bedrock-Phanatics/nethernet-zig) and [bedwire](https://github.com/Bedrock-Phanatics/bedwire).

Built with **Zig 0.17.0**.

## Features

- **High Performance** — Event-driven workers, no thread per player, zero-copy relaying where the session allows it.
- **Multi-Backend Support** — Connect players to multiple backend servers.
- **Seamless Transfers** — Move players between backends without reconnecting.
- **Session Modes** — Passthrough and managed session handling.
- **Native Plugins** — Extend functionality using Zig, C, or C++.
- **Packet Handling** — Intercept, modify, and filter packets through plugins.
- **Configurable** — Simple TOML configuration.

## Getting Started

### Requirements

- Zig 0.17.0
- Git, CMake and a C/C++ toolchain, to build libdatachannel once
- Linux or Windows, x86_64

### Build

```bash
git clone https://github.com/Bedrock-Phanatics/Bifrost.git
cd Bifrost
sh tools/setup-native.sh                                          # Linux
powershell -ExecutionPolicy Bypass -File tools/setup-native.ps1   # Windows
zig build -Doptimize=ReleaseSafe
```

The setup script builds nethernet-zig's patched libdatachannel into `.deps/native`. Pass `-Dnative-prefix=<path>`
to use one built elsewhere. On Windows `libdatachannel.dll` is installed next to `bifrost.exe`; on Linux point
`LD_LIBRARY_PATH` at `.deps/native/lib` or install the library system-wide.

### Run

```bash
./zig-out/bin/bifrost
```

Configure the proxy through [`config/bifrost.toml`](config/bifrost.toml). [Resource limits](docs/limits.md)
explains the timeouts, budgets and rate limits. Set `metrics = "127.0.0.1:9100"` under `[server]` to serve
Prometheus metrics at `/metrics`.

### Networking

| Port | Protocol | Purpose |
| --- | --- | --- |
| `[server] bind`, 19132 by default | TCP | HTTP signaling, what "Add Server" points at |
| `[nethernet] port_min` to `port_max`, any when unset | UDP | WebRTC for players and backends |

Players confirm the proxy's key (`[nethernet] identity_file`) the first time they join, so keep that file. Behind
NAT, add a STUN server to `ice_servers` so the proxy can offer its public address.

## Session Modes

| Mode | Description |
|------|-------------|
| `passthrough` | Relays the player's own session with minimal overhead, checking only the Login. |
| `managed` | Terminates the session, enabling packet processing, backend transfers, and advanced plugin functionality. |

NetherNet has no Minecraft-level encryption, DTLS covers the transport instead. With `[auth] mode = "verify"`
Bifrost checks that each Login is signed by the key the player proved during the WebRTC handshake, which is what
stops a captured Login being replayed.

### Backends

Backends must accept NetherNet over HTTP signaling, as vanilla servers and Quark v6 do. The player's identity
can't be carried across a proxy hop, so a backend has to trust Bifrost for it:

- **managed** logs in to the backend with a Login re-signed by the proxy key. The backend must trust that key.
- **passthrough** forwards the player's own Login, which no longer matches the key Bifrost proves to the backend.
  The backend must skip that check for Bifrost's connection.

Quark v6 has neither yet: with `xbox-auth = true` it rejects both, and with `xbox-auth = false` managed mode
works but players have no XUID. See [Backend support](docs/backends.md).

## Plugin Development

Bifrost supports compiled native plugins through a stable C ABI.

Plugins are distributed as shared libraries (`.so`, `.dll`, or `.dylib`) with embedded `plugin.toml` metadata.

- [Plugin Development](docs/plugins.md)
- [Plugin ABI Reference](docs/plugin-abi.md)
- [Example Plugins](examples/)

## Development

```bash
zig build test
zig build bench -Doptimize=ReleaseFast
```

`-Dtracy=true` builds with [Tracy](https://github.com/wolfpld/tracy) v0.13 profiler zones. Leave it off for
production; disabled zones compile to nothing and Tracy isn't fetched.

## License

Licensed under the [GNU AGPLv3](LICENSE).

---

Maintained by [Bedrock Phanatics](https://github.com/Bedrock-Phanatics).
