# Bifrost

A Minecraft: Bedrock Edition reverse proxy written in Zig 0.16.0.

Bifrost reads the cleartext handshake (RequestNetworkSettings, NetworkSettings, Login,
ServerToClientHandshake), then relays the encrypted session byte-for-byte. It doesn't
terminate encryption or rewrite packets yet.

## Layers

| Library | Role |
| --- | --- |
| [raknet-zig](https://github.com/Bedrock-Phanatics/raknet-zig) | Transport: RakNet listener, backend clients, socket readiness |
| [bedwire](https://github.com/Bedrock-Phanatics/bedwire) | Bedrock protocol: batch framing, compression, Login verification |
| Bifrost | Proxy: routing, player lifecycle, limits, policy |

```
src/
  net/       readiness watches over raknet sockets
  protocol/  per-player handshake observer (bedwire Tap)
  proxy/     worker loop, player links, scheduler, admission, stats
  backend/   backend dialing and round-robin routing
  config/    TOML config and validation
```

Each worker is a single-owner loop: only its task touches its raknet objects, so the
packet path takes no locks and never copies an encrypted payload.

## Running

```sh
zig build -Doptimize=ReleaseSafe
cp bifrost.example.toml bifrost.toml
./zig-out/bin/bifrost --config bifrost.toml
```

See [`bifrost.example.toml`](bifrost.example.toml) for every option. Notable ones:

- `server.workers`: independent loops sharing the port through `SO_REUSEPORT`.
  More than one is Linux-only; other platforms refuse the config.
- `server.max_players`: a global cap across all workers.
- `auth.mode = "verify"`: reject players whose Xbox Live login doesn't verify.
  Needs Microsoft's signing keys saved to `auth.keys_file`.

## Development

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
```
