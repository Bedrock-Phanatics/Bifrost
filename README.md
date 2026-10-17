
# Bifrost

A high-performance Minecraft: Bedrock Edition proxy written in Zig, designed for efficiency, extensibility, and low-latency networking.

Built with **Zig 0.17.0**.

## Features

- **High Performance** — Efficient networking with low memory overhead.
- **Multi-Backend Support** — Connect players to multiple backend servers.
- **Seamless Transfers** — Move players between backends without reconnecting.
- **Session Modes** — Passthrough and managed session handling.
- **Native Plugins** — Extend functionality using Zig, C, or C++.
- **Packet Handling** — Intercept, modify, and filter packets through plugins.
- **Configurable** — Simple TOML configuration.

## Getting Started

### Requirements

- Zig 0.17.0
- Linux or Windows

### Build

```bash
git clone https://github.com/Bedrock-Phanatics/Bifrost.git
cd Bifrost
zig build -Doptimize=ReleaseSafe
```

### Run

```bash
./zig-out/bin/bifrost
```

Configure the proxy through [`config/bifrost.toml`](config/bifrost.toml). [Resource limits](docs/limits.md)
explains the timeouts, budgets and rate limits.

## Session Modes

| Mode | Description |
|------|-------------|
| `passthrough` | Relays encrypted sessions with minimal overhead. |
| `managed` | Enables packet processing, backend transfers, and advanced plugin functionality. |

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

## License

Licensed under the [GNU AGPLv3](LICENSE).

---

Maintained by [Bedrock Phanatics](https://github.com/Bedrock-Phanatics).
