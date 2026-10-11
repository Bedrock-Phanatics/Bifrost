# Plugin ABI v1

The contract between Bifrost and native plugins, as declared in
[`include/bifrost_plugin.h`](../include/bifrost_plugin.h). Zig plugins get the same thing through the
`bifrost_plugin` module. v1 is frozen: nothing below changes meaning, moves or disappears; it can only grow in the
ways listed under [Versioning](#versioning).

## Trust

Plugins are native code loaded into the proxy's process. They are trusted completely: a crash, an infinite loop or
memory corruption in a plugin takes the whole proxy down. There is no sandbox or process isolation.

## Loading

`bifrost_plugin_init(host, plugin)` is called once, on the main thread, before any player connects. Fill in
`plugin` (`name`, `plugin_version`, `capabilities`, optionally `state` and `shutdown`) and register everything you
need; subscriptions and commands can't be added later. Returning anything but `OK` unloads the plugin and fails
startup. Bifrost refuses a plugin whose `abi_version` differs from `BIFROST_ABI_VERSION`, whose `struct_size` is
smaller than it knows, or that asks for a capability bit it doesn't know. It also refuses one that subscribes to
events, hooks packets or registers commands without declaring `EVENTS`, `PACKETS` or `COMMANDS`, and `spawn_task`
returns `UNSUPPORTED` without `TASKS`. Whatever a refused plugin registered is dropped with it. `spawn_task` and
`post` also return `UNSUPPORTED` during `bifrost_plugin_init`, so no work can outlive a plugin that is then refused.

`name` (up to 64 bytes) and `plugin_version` (up to 64 bytes) are required and must be printable UTF-8: no control
characters, and no `NULL` pointer with a non-zero length. A plugin can also call `set_description` with up to 256
bytes of the same. Bifrost checks and copies all three when `bifrost_plugin_init` returns, so they only have to stay
valid until then, and logs them as the plugin loads.

`shutdown(state)` runs once, after every worker has stopped and every task has finished or been canceled, newest
plugin first. Stop any threads you started before it returns; Bifrost unloads the library right after. It also
runs if `bifrost_plugin_init` returned `OK` and Bifrost then refused the plugin, but never after a failed init.

## Threads

Callbacks run on Bifrost's worker threads, several at once, so they must be quick and thread-safe. Never block in
one; anything slower than `slow_plugin_callback_ms` is logged. Player events, packet hooks, commands and task
completions for a player always run on that player's worker. `PROXY_STARTED` runs on whichever worker starts first,
and `PROXY_STOPPING` on whichever thread stops the proxy.

Callbacks for one player never overlap. Bifrost holds no lock while it calls a plugin, so callbacks may call host
functions, including ones that queue more work for the same player; that work runs after the callback returns,
never inside it.

| host function | where it may be called |
|---|---|
| `log`, `worker_count`, `backend_count`, `backend_name`, `player_name`, `send_message`, `post` | any thread |
| `transfer`, `spawn_task` | inside a callback Bifrost is running |
| `subscribe`, `subscribe_packet`, `register_command`, `register_command_info`, `set_description` | inside `bifrost_plugin_init` |

A restricted call made from your own thread returns `WRONG_THREAD` and does nothing. To act on a player from your
own thread, `post` to their worker and make the call from the `done` callback.

## Memory

Everything Bifrost passes in (events, packets, commands, task results and the strings inside them) is borrowed and
only valid until the callback returns; copy what you keep. Strings and buffers you pass to Bifrost are copied before
the call returns. `backend_name` returns a string that lives as long as the proxy. `user` and `state` pointers are
yours; Bifrost only hands them back.

## Host functions

Every function returning `bifrost_status` returns `OK` or one of the codes listed, plus `FAILED` if Bifrost runs out
of memory.

| function | does | statuses |
|---|---|---|
| `log(level, message)` | logs under the plugin's name | none |
| `subscribe(kind, callback, user)` | calls `callback` for every event of `kind` | `INVALID_ARGUMENT` for an unknown kind, no callback or a duplicate; `TOO_LATE` after init |
| `subscribe_packet(direction, id, phase, flags, callback, user)` | hooks one packet id in one direction, managed mode only | `UNSUPPORTED` in passthrough; `INVALID_ARGUMENT` for a bad direction, id or phase, an unknown flag, no callback or a duplicate; `TOO_LATE` |
| `register_command(name, callback, user)` | same as `register_command_info` with no description and permission `ANY` | as below |
| `register_command_info(info)` | claims a `/command` and advertises it to clients, managed mode only | `UNSUPPORTED` in passthrough; `INVALID_ARGUMENT` for a name outside `[A-Za-z0-9_-]{1,32}`, a name already taken, a description over 256 bytes or not UTF-8, an unknown permission, no callback or a short `struct_size`; `TOO_LATE` |
| `set_description(description)` | sets the description shown when the plugin loads; calling it again replaces it | `INVALID_ARGUMENT` for over 256 bytes, not printable UTF-8 or a `NULL` pointer with a length; `TOO_LATE` |
| `backend_count()` | number of configured backends | none |
| `backend_name(backend, name)` | name of a backend | `INVALID_ARGUMENT` for an unknown backend or no `name` |
| `player_name(player, out, capacity, len)` | copies up to `capacity` bytes of the name and sets `len` to its full length | `STALE_HANDLE` after the player left (before authentication the name is empty); `INVALID_ARGUMENT` for no `len` or no `out` with a capacity |
| `transfer(player, backend)` | asks to move a player; the outcome arrives as `TRANSFER_COMPLETED` or `TRANSFER_FAILED` | `INVALID_ARGUMENT` for an unknown backend; `STALE_HANDLE`; `BUSY` when the worker's transfer mailbox is full |
| `worker_count()` | number of workers | none |
| `spawn_task(player, run, done, user)` | runs `run` on a shared task thread, then `done` once | `UNSUPPORTED` without `TASKS` or during init; `INVALID_ARGUMENT` for no `run` or `done`; `BUSY` past 128 tasks in total or 32 per plugin |
| `send_message(player, text)` | sends the player a chat message, managed mode only | `UNSUPPORTED` in passthrough or while shutting down; `INVALID_ARGUMENT` for empty, over 1024 bytes or not UTF-8; `STALE_HANDLE`; `BUSY` past 1024 queued messages and posts |
| `post(player, done, user)` | runs `done` once on the player's worker | `INVALID_ARGUMENT` for no `done`; `STALE_HANDLE`; `BUSY` as for `send_message`; `UNSUPPORTED` during init or while shutting down |

`done` from `spawn_task` and `post` always runs exactly once. Its `bifrost_task_result.status` is `OK` on the
player's worker, `STALE_HANDLE` if the player left or the proxy stopped while it ran, or `CANCELED` if the proxy stopped before `run` started. A task
spawned with no player (`id` 0) finishes with `OK` on the task thread itself. Task threads run nothing but `run`, so
`run` may block, but a stuck task holds a thread and delays shutdown.

## Callbacks

- **Events** get a `bifrost_event`. Only `TRANSFER_REQUESTED` passes a `bifrost_transfer_decision`; set `action` to
  `CANCEL`, or to `REDIRECT` with a `backend`. Other events pass `NULL`.
- **Packets** get the whole packet, header included, in `bytes`. Return `PASS`, `CANCEL` or `REPLACE` after writing
  a whole replacement packet into `replacement` (up to `replacement_capacity`, 64 KiB) and setting
  `replacement_len`. A replacement that doesn't decode is dropped and counted as an error. With
  `BIFROST_PACKET_VALIDATED` the hook only sees packets that decode.
- **Commands** get the lowercase `name` and the trimmed `args`. A plugin command replaces a backend command with the
  same name, both in autocomplete and when run. `permission` only changes what clients show; check who is allowed
  in the callback.

## Player handles

A `bifrost_player` is valid from `PLAYER_CONNECTED` until `PLAYER_DISCONNECTED` returns. After that every call with
it returns `STALE_HANDLE`, even if a new player gets the same slot. `id` 0 is never a player.

## Versioning

- `BIFROST_ABI_VERSION` changes only for a breaking change. Each side checks the other's `abi_version` and refuses
  a mismatch: Bifrost returns an error for the plugin, a plugin should return `INCOMPATIBLE`.
- `bifrost_host` only grows at the end. A plugin must not compare `host->struct_size` with its own
  `sizeof(bifrost_host)`, or it would refuse older v1 hosts for no reason. Check the functions it needs with
  `BIFROST_HOST_HAS(host, fn)` (`host.has(.fn)` in Zig) and skip the optional ones that are missing.
  `set_description` is the first function added this way.
- Structs Bifrost passes in (`bifrost_event`, `bifrost_packet`, `bifrost_command`, `bifrost_task_result`) can grow
  at the end too: read a field newer than your header only when `struct_size` covers it.
- Structs a plugin writes into (`bifrost_plugin`, `bifrost_transfer_decision`, `bifrost_packet`) never grow in v1,
  because a newer plugin writing a field into an older host's smaller struct would corrupt it. New outputs arrive as
  new host functions instead.
- Structs you pass in (`bifrost_command_info`) carry `struct_size` so Bifrost knows which fields you set; fill it in.
- Enums and status codes can gain values; treat unknown ones as "not for me" rather than as errors.
