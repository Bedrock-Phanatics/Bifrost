# Plugin packages

Bifrost only loads compiled native plugins, and only from packages. A package is a directory holding a
`plugin.toml` and the shared library it names:

```
plugins/
  Greeter/
    plugin.toml
    Greeter.dll        Greeter.so on Linux, Greeter.dylib on macOS
  Maintenance/
    plugin.toml
    Maintenance.dll
```

```toml
name = "Greeter"
version = "1.0.0"
description = "Logs a welcome for every player"
library = "Greeter.dll"
```

The library talks to Bifrost through the C ABI in [`plugin-abi.md`](plugin-abi.md); C, C++ and Zig all work.
Nothing is compiled, interpreted or run from source.

## plugin.toml

| key | rule |
|---|---|
| `name` | 1 to 64 bytes of printable UTF-8; must equal the `name` the library reports |
| `version` | 1 to 64 bytes of printable UTF-8; must equal the library's `plugin_version` |
| `description` | 1 to 256 bytes of printable UTF-8; logged at startup, replaces anything set with `set_description` |
| `library` | a file name in the package ending in `.dll`, `.so` or `.dylib` for the platform (case-insensitive except on Linux); no `/`, `\` or `:` |

All four are required strings. Unknown keys, invalid TOML, invalid UTF-8 and files over 4096 bytes are refused.
Names are unique ignoring ASCII case: a second package with a loaded name is refused before its library is opened.

## Discovery

At startup Bifrost reads `[plugins] directory` (default `plugins`, relative to the working directory) and loads
every package in it, sorted by directory name byte order. A missing directory means no plugins. Entries starting
with `.` and files that aren't libraries are ignored. Bifrost refuses to start if it finds:

- a library directly in the directory, outside a package
- a package that is a symlink
- a package with no `plugin.toml`, or one that fails any check below
- more than 64 packages

```toml
[plugins]
directory = "plugins"
disabled = ["Maintenance"]    # package directory names, ASCII case ignored; up to 16
```

A disabled package isn't read at all, so its manifest may be broken.

For each package Bifrost reads and checks `plugin.toml`, opens the library, checks it is a regular file whose
header is a shared library for this OS and CPU, checks its canonical path is directly inside the package (a symlink
pointing out is refused), loads it by that absolute path, looks up `bifrost_plugin_init` and initializes it as
described in [`plugin-abi.md`](plugin-abi.md#loading). The plugin is registered only once all of that succeeds;
until then nothing it registered is kept. Every failure is logged with the package path and the reason.

Libraries a plugin depends on resolve with the platform's normal rules, minus the unsafe ones where Bifrost can
avoid them: on Windows the plugin's own directory, Bifrost's directory and System32, but never the working
directory or `PATH`; on Linux and macOS through `dlopen`, so bundle dependencies next to the plugin and set an
`$ORIGIN` (`@loader_path` on macOS) rpath.

Packaging is not a sandbox. A plugin runs inside the proxy with its full privileges; only install ones you trust.

## Migrating from `[[plugin]] path`

`[[plugin]] path = "..."` is no longer accepted, and Bifrost won't start with it. For each old entry, make a
directory under `plugins/`, move the library into it and write a `plugin.toml` whose `name` and `version` match what
the plugin reports (Bifrost logs both when a mismatch refuses it). Load order is now the directory names' order.

## A C++23 plugin

[`examples/greeter/Greeter.cpp`](../examples/greeter/Greeter.cpp) is a complete plugin. `zig build` builds it and
the Zig example into ready-to-copy packages under `zig-out/plugins/`. By hand, from the repository root:

```sh
# Linux
mkdir -p plugins/Greeter
clang++ -std=c++23 -shared -fPIC -Iinclude examples/greeter/Greeter.cpp -o plugins/Greeter/Greeter.so
# Windows (MSVC)
cl /std:c++latest /EHsc /LD /Iinclude examples\greeter\Greeter.cpp /Fe:plugins\Greeter\Greeter.dll
# or with Zig anywhere
zig c++ -std=c++23 -shared -Iinclude examples/greeter/Greeter.cpp -o plugins/Greeter/Greeter.dll
```

then put the `plugin.toml` above next to it, with `library` set to the file you built.
