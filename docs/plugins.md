# Native plugins

Each plugin is one normal native shared library containing its code and embedded `plugin.toml`:

```text
plugins/
  Maintenance.so
  ChatGuard.so
  PacketFilter.so
```

Use `.dll` on Windows and `.dylib` on macOS. Copy only the binary into the configured directory.
Directory packages are rejected. There are no archives, extraction caches or runtime manifest files.

## Embedded metadata

Keep this as a source file named `plugin.toml`:

```toml
name = "ChatGuard"
version = "1.0.0"
description = "Blocks chat with banned words, warns the sender and removes repeat offenders"
```

All three fields are required strings. Name and version must each be 1 to 64 bytes, and description 1 to
256 bytes, of printable UTF-8. The whole manifest must be 1 to 4096 bytes of UTF-8 TOML. Invalid TOML,
duplicate keys and unknown keys are refused. The old `library` key is no longer accepted.

The library exports both functions from [`bifrost_plugin.h`](../include/bifrost_plugin.h):

```c
bifrost_status bifrost_plugin_get_manifest(bifrost_str *out);
bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin);
```

`get_manifest` returns `INVALID_ARGUMENT` for null `out`. Otherwise it returns `OK` and a non-null pointer
plus explicit byte length. The bytes have static lifetime until unload. No allocation or terminator is
needed. Bifrost retrieves and parses the manifest once per load at startup, then keeps validated metadata
in host-owned storage. There is no metadata processing in packet callbacks.

The existing C ABI v1 structures and initialization function are unchanged. Bifrost fills `plugin->name`
and `plugin->plugin_version` from the manifest before initialization. Plugins may leave them unchanged.
If a plugin writes them, they must match the manifest exactly. The manifest description takes precedence
over `set_description`. Existing plugins need the new export and must be rebuilt.

## Discovery and disabling

```toml
[plugins]
directory = "plugins"
disabled = ["Maintenance"]
```

The directory defaults to `plugins`, relative to the working directory. A missing directory means no
plugins. Candidates are sorted by filename byte order, with at most 64 enabled libraries. Hidden entries
and unrelated files are ignored. Directories and symlinked candidate libraries are rejected. Only the
current platform's extension is scanned, case-sensitive on Linux and case-insensitive on Windows and macOS.

Disabled entries are filename stems, compared ignoring ASCII case: `Maintenance` skips `Maintenance.dll`
before opening it. A renamed binary must be disabled using its new stem. Loaded identity comes from the
manifest and may differ from the stem. Manifest names are unique ignoring ASCII case. A duplicate is
rejected before initialization, though its library has already been opened.

Bifrost checks the native header and architecture, resolves an absolute path inside the configured
directory, opens the library, validates its manifest, resolves initialization, checks ABI compatibility
and commits registrations only after success. Errors fail startup. Shutdown settles tasks and removes
callbacks before shutdown hooks and library unloading, in reverse load order.

## Zig

[`examples/maintenance/src/maintenance.zig`](../examples/maintenance/src/maintenance.zig) is a complete working example. A minimal plugin is:

```zig
const bifrost = @import("bifrost_plugin");

pub const manifest = @embedFile("plugin.toml");

comptime {
    bifrost.exportPlugin(@This());
}

pub fn init(host: bifrost.Host) !void {
    host.log(.info, "plugin started", .{});
}
```

Every example keeps `plugin.toml` at the top of its directory and the code under `src/`. Zig can't embed a
file above the module's own directory, so the build hands the manifest in as an import:

```zig
plugin.root_module.addAnonymousImport("plugin.toml", .{ .root_source_file = b.path("plugin.toml") });
```

The SDK exports both functions and preserves the manifest name/version defaults. Optional `name` and
`version` declarations are still supported and checked. A raw ABI plugin can use
`bifrost.manifest(@embedFile("plugin.toml"))` as its manifest export.

Run `zig build` with the repository's Zig 0.17.0 toolchain. It compiles the Zig and C++23 examples and
installs only their libraries under `zig-out/plugins/`. Windows output is `Maintenance.dll`, `ChatGuard.dll`
and `PacketFilter.dll`. Third-party builds can import the dependency's `bifrost_plugin` module and use
`addLibrary` with `.linkage = .dynamic`, as in [`build.zig`](../build.zig). No Zig runtime files are needed.

## C++23 and CMake

[`examples/chatguard`](../examples/chatguard) contains a complete C++23 CMake project:

```sh
cmake -S examples/chatguard -B build/chatguard -DCMAKE_BUILD_TYPE=Release
cmake --build build/chatguard --config Release
cmake --install build/chatguard --config Release --prefix ./stage
```

Copy `stage/plugins/ChatGuard.so`, `.dll` or `.dylib` into `plugins/`. Use a compiler and standard library
with C++23 `std::format` support.

For another project, include [`cmake/BifrostPlugin.cmake`](../cmake/BifrostPlugin.cmake), create a shared
library target and call `bifrost_embed_manifest(MyPlugin plugin.toml)`. Include the generated
`bifrost_manifest.h` in exactly one translation unit. It embeds the actual TOML bytes with no section or
linker tricks and exports the C ABI getter. Manifest changes trigger CMake reconfiguration.
The Zig build uses the same header template and also tracks manifest content changes.

MSVC, Clang and GCC can use this interface. Keep classes, containers, allocators and exceptions inside
the binary. All exports and callbacks use the existing C ABI, with `extern "C"` and `noexcept` in C++.
Catch exceptions inside callbacks where recovery is possible. ChatGuard uses PascalCase classes
and camelCase members.

## C

The generated header also works with C99:

```c
#include "bifrost_manifest.h"

BIFROST_EXPORT bifrost_status bifrost_plugin_init(const bifrost_host *host, bifrost_plugin *plugin) {
    (void)plugin;
    return host->abi_version == BIFROST_ABI_VERSION
        ? BIFROST_STATUS_OK : BIFROST_STATUS_INCOMPATIBLE;
}
```

Use a CMake shared library target and the same `bifrost_embed_manifest` call. The
[working C test plugin](../tests/plugin/fixture.c) also demonstrates event callbacks and shutdown.

## Dependencies and trust

Link private dependencies statically where licensing and platform support permit. The CMake ChatGuard
uses the static MSVC runtime and static GCC/C++ runtimes on MinGW. System libraries, platform runtimes
and some private dependencies still require external installation.

Bifrost preserves the existing loader's dependency search rules. Windows uses the library directory,
application directory and configured safe default directories, excluding the working directory and
`PATH`. Linux and macOS use the platform loader. Install external dependencies in trusted system
locations and avoid relative or writable dependency search paths and rpaths.

Native plugins are fully trusted code. Loading a library can run constructors or `DllMain` **before
Bifrost reads its manifest**, including for rejected libraries. Manifest validation is neither a sandbox
nor proof that a library is safe. Bifrost cannot validate arbitrary native pointers or recover from a
crashing export. Install only trusted binaries.

To migrate a directory package, remove `library`, embed the TOML during compilation, add the manifest
export and copy the rebuilt binary directly into `plugins/`. Remove the old package directory.
Legacy `[[plugin]] path` configuration is also rejected.

## Packet filtering

[`examples/packets/src/PacketFilter.cpp`](../examples/packets/src/PacketFilter.cpp) is a C++23 native plugin that drops
client chat over 512 bytes, replaces chat authors with the player name Bifrost reports, and caps requested and
maximum chunk radius at 12. Negative radius requests are canceled. Change the two constants to suit the server;
these are example policies, not Bedrock protocol limits.

Oversized chat also queues a raw Text warning to the player through `send_packet`. The warning bypasses packet
listeners and is sent after the current callback finishes; a full queue simply drops the warning.

The plugin subscribes to client Text in-game and RequestChunkRadius in any permitted phase. It decodes fields
through the host API and re-encodes changed packets and chat warnings. Forwarded message bodies and other text fields are
preserved. Failed decoding, player-name lookup or encoding cancels the packet. Bifrost validates packet headers,
direction, phase and size limits, and applies its normal compression and transfer handling.

The plugin has no owned state, heap allocation or shutdown work. Each callback uses stack storage and borrowed
packet fields; the callback's host pointer remains valid for the plugin's lifetime. Changed packets and warnings use the
replacement buffer. The `packet-dispatch` benchmark measures raw-text and chat pass paths, including the actual
player-name lookup. This example limits client requests; backend view-distance policy remains the backend's
responsibility.

## A complete C++23 plugin

[`examples/chatguard/src/ChatGuard.cpp`](../examples/chatguard/src/ChatGuard.cpp) uses most of the API in about 150 lines:

- Name, version and description come from the embedded `plugin.toml`; `shutdown` logs totals.
- `PLAYER_AUTHENTICATED` and `PLAYER_DISCONNECTED` events, with a copied `player_info` snapshot on join.
- An in-game client Text subscription with `BIFROST_PACKET_FIELDS`, decoded through `decode_packet`.
- Chat containing a banned word is canceled. The sender gets a raw Text warning built with `encode_packet`
  and queued with `send_packet`, which copies the bytes before the callback cancels.
- The third strike queues `disconnect` with a reason.

Strike counts live in one map per worker, because a player's packets and events always arrive on that
player's worker, so no lock is needed. Allocation failures are caught inside the callback. The integration
test `the C++ chat guard example warns, cancels and finally removes a player` loads the built library
through the managed proxy.

## Player information and actions

The C ABI offers copied player information from any thread, networking snapshots on the player's worker
(post to get there) and queued disconnect and backend-transfer actions from any thread. Zig uses
`host.playerInfo`, `host.networkStats`, `host.disconnect` and `host.requestTransfer`.
Networking fields carry availability bits; unsupported measurements are never presented as zero measurements.
See [the player API contract](plugin-abi.md#copied-player-information) for lifetimes, statuses, transfer semantics,
disconnect-reason limitations and the phase-change event. Run `zig build bench -Doptimize=ReleaseFast -- players --quick`
to measure information lookups, transport collection, snapshots, rate sampling, action scheduling and event dispatch.
