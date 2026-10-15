# Native plugins

Each plugin is one normal native shared library containing its code and embedded `plugin.toml`:

```text
plugins/
  Maintenance.so
  Greeter.so
  PacketFilter.so
```

Use `.dll` on Windows and `.dylib` on macOS. Copy only the binary into the configured directory.
Directory packages are rejected. There are no archives, extraction caches or runtime manifest files.

## Embedded metadata

Keep this as a source file named `plugin.toml`:

```toml
name = "Greeter"
version = "1.0.0"
description = "Logs a welcome for every player"
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

[`examples/maintenance.zig`](../examples/maintenance.zig) is a complete working example. A minimal plugin is:

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

The SDK exports both functions and preserves the manifest name/version defaults. Optional `name` and
`version` declarations are still supported and checked. A raw ABI plugin can use
`bifrost.manifest(@embedFile("plugin.toml"))` as its manifest export.

Run `zig build` with the repository's Zig 0.17.0 toolchain. It compiles the Zig and C++23 examples and
installs only their libraries under `zig-out/plugins/`. Windows output is `Maintenance.dll`, `Greeter.dll`
and `PacketFilter.dll`. Third-party builds can import the dependency's `bifrost_plugin` module and use
`addLibrary` with `.linkage = .dynamic`, as in [`build.zig`](../build.zig). No Zig runtime files are needed.

## C++23 and CMake

[`examples/greeter`](../examples/greeter) contains a complete C++23 CMake project:

```sh
cmake -S examples/greeter -B build/greeter -DCMAKE_BUILD_TYPE=Release
cmake --build build/greeter --config Release
cmake --install build/greeter --config Release --prefix ./stage
```

Copy `stage/plugins/Greeter.so`, `.dll` or `.dylib` into `plugins/`. Use a compiler and standard library
with C++23 `std::format` support.

For another project, include [`cmake/BifrostPlugin.cmake`](../cmake/BifrostPlugin.cmake), create a shared
library target and call `bifrost_embed_manifest(MyPlugin plugin.toml)`. Include the generated
`bifrost_manifest.h` in exactly one translation unit. It embeds the actual TOML bytes with no section or
linker tricks and exports the C ABI getter. Manifest changes trigger CMake reconfiguration.
The Zig build uses the same header template and also tracks manifest content changes.

MSVC, Clang and GCC can use this interface. Keep classes, containers, allocators and exceptions inside
the binary. All exports and callbacks use the existing C ABI, with `extern "C"` and `noexcept` in C++.
Catch exceptions inside callbacks where recovery is possible. The Greeter uses PascalCase classes
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

Link private dependencies statically where licensing and platform support permit. The CMake Greeter
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

[`examples/packets/PacketFilter.cpp`](../examples/packets/PacketFilter.cpp) is a C++23 native plugin that drops
client chat over 512 bytes, replaces chat authors with the player name Bifrost reports, and caps requested and
maximum chunk radius at 12. Negative radius requests are canceled. Change the two constants to suit the server;
these are example policies, not Bedrock protocol limits.

Oversized chat also queues a raw Text warning to the player through `send_packet`. The warning bypasses packet
listeners and is sent after the current callback finishes; a full queue simply drops the warning.

The plugin subscribes to client Text in-game and RequestChunkRadius in any permitted phase. It decodes fields
through the host API and re-encodes changed packets and chat warnings. Forwarded message bodies and other text fields are
preserved. Failed decoding, player-name lookup or encoding cancels the packet. Bifrost validates packet headers,
direction, phase and size limits, and applies its normal compression/encryption and transfer handling.

The plugin has no owned state, heap allocation or shutdown work. Each callback uses stack storage and borrowed
packet fields; the callback's host pointer remains valid for the plugin's lifetime. Changed packets and warnings use the
replacement buffer. The `packet-dispatch` benchmark measures raw-text and chat pass paths, including the actual
player-name lookup. This example limits client requests; backend view-distance policy remains the backend's
responsibility.

## Player information and actions

The [Greeter](../examples/greeter/Greeter.cpp) feature-checks copied player information and posts a networking
query to the player's worker. The C ABI also offers queued disconnect and backend-transfer actions from any
thread. Zig uses `host.playerInfo`, `host.networkStats`, `host.disconnect` and `host.requestTransfer`.
Networking fields carry availability bits; unsupported measurements are never presented as zero measurements.
See [the player API contract](plugin-abi.md#copied-player-information) for lifetimes, statuses, transfer semantics,
disconnect-reason limitations and the phase-change event. Run `zig build bench -Doptimize=ReleaseFast -- players --quick`
to measure information lookups, transport collection, snapshots, rate sampling, action scheduling and event dispatch.
