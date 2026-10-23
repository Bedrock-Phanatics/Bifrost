# Known issues

What's open as of 2.0.0-rc.2. Details live in the linked docs.

## Not yet verified

- **No real client has joined through Bifrost.** Every test uses in-process players and backends built on bedwire
  and nethernet-zig. Neither a vanilla Bedrock client joining Bifrost nor a full Bifrost-to-Quark session has
  been run. The Quark login path was checked by verifying a bedwire-built login with Quark's own code.
- **No AddressSanitizer run.** The full suite passes on Windows and Linux in Debug, ReleaseSafe and ReleaseFast,
  and under ThreadSanitizer on Linux (`tools/tsan.sh`), which only instruments the Zig code.
- **`udp_mux` hasn't been tried with vanilla clients** (`config/bifrost.toml`).
- **Other backends:** gophertunnel servers and vanilla BDS have no way to trust a proxy, and neither was tested.
  See [Backend support](backends.md).

## Limits of the design

- **Passthrough doesn't forward the player's IP**, so backends see Bifrost's address. Managed mode does. See
  [Setup](setup.md#other-modes).
- **A leaked proxy key lets anyone join trusting backends as any player.** Managed logins don't carry the
  player's own Xbox token, so a backend can't double-check the XUID with Microsoft.
- **NetherNet is slower than the old RakNet transport.**

  | | NetherNet | RakNet |
  | --- | --- | --- |
  | 512 B round trips (one player) | 2,470/s | 5,076/s |
  | joins | 127/s | 1,149/s |

  Each player also costs about 675 KiB of resident memory. See `tests/bench/baseline.md`.
- **Large plugin packet injections on Linux** pay glibc trim and refault costs, about 10 µs per 16 KiB. That was
  measured on 1.2.1, before the NetherNet switch.
