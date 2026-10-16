# Plugin ABI v1

The contract between Bifrost and native plugins, as declared in
[`include/bifrost_plugin.h`](../include/bifrost_plugin.h). Zig plugins get the same thing through the
`bifrost_plugin` module. v1 is frozen: nothing below changes meaning, moves or disappears; it can only grow in the
ways listed under [Versioning](#versioning).

## Trust

Plugins are native code loaded into the proxy's process. They are trusted completely: a crash, an infinite loop or
memory corruption in a plugin takes the whole proxy down. There is no sandbox or process isolation. Constructors and `DllMain` may run before manifest validation,
including for rejected libraries. Manifest validation does not establish trust.

No exception may cross into Bifrost, from `bifrost_plugin_init` or any callback. With C++17 or newer the header
makes the entry point and every callback type `noexcept`, so passing a function that might throw doesn't compile, and
an exception that escapes anyway calls `std::terminate` instead of unwinding through Bifrost. Catch inside.

## Loading

Plugins are single shared libraries with embedded `plugin.toml` metadata, described in
[`plugins.md`](plugins.md). `bifrost_plugin_init(host, plugin)` is called once, on the main thread, before any player connects. Fill in
`plugin` (`name`, `plugin_version`, `capabilities`, optionally `state` and `shutdown`) and register everything you
need; subscriptions and commands can't be added later. Returning anything but `OK` unloads the plugin and fails
startup. Bifrost refuses a plugin whose `abi_version` differs from `BIFROST_ABI_VERSION`, whose `struct_size` is
smaller than it knows, or that asks for a capability bit it doesn't know. It also refuses one that subscribes to
events, hooks packets or registers commands without declaring `EVENTS`, `PACKETS` or `COMMANDS`, and `spawn_task`
returns `UNSUPPORTED` without `TASKS`. Whatever a refused plugin registered is dropped with it. `spawn_task` and
`post` also return `UNSUPPORTED` until initialization, metadata validation and registration all succeed, including
from `shutdown` when loading fails, so no queued callback can outlive a refused plugin.

`name` (up to 64 bytes) and `plugin_version` (up to 64 bytes) are required and must be printable UTF-8: no control
characters, and no `NULL` pointer with a non-zero length. A plugin can also call `set_description` with up to 256
bytes of the same. Bifrost checks and copies all three when `bifrost_plugin_init` returns, so they only have to stay
valid until then, and logs them as the plugin loads. Bifrost pre-fills `name` and `plugin_version` from the
manifest so plugins may leave them unchanged. Values written by the plugin must equal the embedded
`plugin.toml` exactly, and its `description` replaces whatever `set_description` set. Two plugins can't share a name,
ignoring ASCII case.

`shutdown(state)` runs once, after every worker has stopped and every task has finished or been canceled, newest
plugin first. Stop any threads you started before it returns; Bifrost unloads the library right after. It also
runs if `bifrost_plugin_init` returned `OK` and Bifrost then refused the plugin, but never after a failed init.

Once shutdown begins, valid new messages, posts and tasks return `UNSUPPORTED`; valid packet and transfer submissions return `CANCELED`.
Calls already in progress can still be queued. Messages, posts, tasks and packets are settled during teardown;
a queued transfer can be abandoned when shutdown disconnects its player. When embedding Bifrost, stop and
join workers, unload plugins, then destroy workers before deinitializing the plugin runtime and its I/O runtime.

## Embedded manifest export

Dynamic plugins must also export `bifrost_plugin_get_manifest(bifrost_str *out)`.
Return `INVALID_ARGUMENT` for null `out`, otherwise return `OK` and static UTF-8 TOML bytes with an explicit
length of 1 to 4096 bytes. The bytes remain valid until unload and require no allocation.
Bifrost validates the pointer/length shape before parsing and copies the bounded name, version and
description fields into host-owned storage. Retrieval and parsing happen once per load at startup.
This independent export does not change ABI v1 layouts or packet callback costs.

## Threads

Callbacks may run concurrently, so they must be quick and thread-safe. Never block in
one; anything slower than `slow_plugin_callback_ms` on a worker is logged. Player events, packet hooks, commands and task
completions for a live player run on that player's worker. Completions without a live player can run on a task
thread or the teardown thread and report `BIFROST_NO_WORKER`. `PROXY_STARTED` runs on whichever worker starts first,
and `PROXY_STOPPING` on whichever thread stops the proxy.

Callbacks for one live player never overlap. Bifrost holds no lock while it calls a plugin, so callbacks may call host
functions, including ones that queue more work for the same player; that work runs after the callback returns,
never inside it.

| host function | where it may be called |
|---|---|
| `log`, `worker_count`, `backend_count`, `backend_name`, `player_name`, `player_info`, `send_message`, `send_packet`, `post`, `disconnect`, `request_transfer` | any thread |
| `network_stats` | a callback on this player's worker, use `post` from other threads |
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
| `transfer(player, backend)` | asks to move a player; while running, the outcome arrives as `TRANSFER_COMPLETED` or `TRANSFER_FAILED` | `INVALID_ARGUMENT` for an unknown backend; `STALE_HANDLE`; `BUSY` when the worker's transfer mailbox is full; `UNSUPPORTED` during init; `CANCELED` while shutting down |
| `worker_count()` | number of workers | none |
| `spawn_task(player, run, done, user)` | runs `run` on a shared task thread, then `done` once | `UNSUPPORTED` without `TASKS`, during init or while shutting down; `INVALID_ARGUMENT` for no `run` or `done`; `BUSY` past 128 tasks in total or 32 per plugin |
| `send_message(player, text)` | sends the player a chat message, managed mode only | `UNSUPPORTED` in passthrough or while shutting down; `INVALID_ARGUMENT` for empty, over 1024 bytes or not UTF-8; `STALE_HANDLE`; `BUSY` past 1024 queued messages and posts |
| `post(player, done, user)` | runs `done` once on the player's worker | `INVALID_ARGUMENT` for no `done`; `STALE_HANDLE`; `BUSY` as for `send_message`; `UNSUPPORTED` during init or while shutting down |

`done` from `spawn_task` and `post` always runs exactly once. Its `bifrost_task_result.status` is `OK` on the
player's worker, `STALE_HANDLE` if the player left or the proxy stopped while it ran, or `CANCELED` if the proxy stopped before `run` started. A task
spawned with no player (`id` 0) finishes with `OK` on the task thread itself. Its `done` is a Bifrost callback and
may call `transfer` and `spawn_task`, subject to their usual limits and shutdown checks. The callback scope belongs
to the current thread and ends when `done` returns. `run` cannot make callback-only calls. Task threads execute `run` and
completions without a live player. `run` may block, but a stuck task holds a thread and delays shutdown.

## Callbacks

- **Events** get a `bifrost_event`. Only `TRANSFER_REQUESTED` passes a `bifrost_transfer_decision`; set `action` to
  `CANCEL`, or to `REDIRECT` with a `backend`. Other events pass `NULL`.
- **Packets** get the whole packet, header included, in `bytes`. Return `PASS`, `CANCEL` or `REPLACE` after writing
  a whole replacement packet into `replacement` (up to `replacement_capacity`, 64 KiB) and setting
  `replacement_len`. A replacement that doesn't decode or changes the packet id or either split-screen sub-client
  index is dropped and counted as an error. Later hooks on the same packet see the latest replacement;
  a `CANCEL` stops the rest. Proxy state, such as
  what gets cleaned up on a transfer and the transition into game, follows what was actually delivered.
  Headers must use the protocol's canonical varint encoding. With `BIFROST_PACKET_VALIDATED` the hook
  only sees packets that decode; validation is shared until an accepted replacement changes the packet.
- **Commands** get the lowercase `name` and the trimmed `args`. A plugin command replaces a backend command with the
  same name, both in autocomplete and when run.

### Typed packet fields

Check `BIFROST_HOST_HAS(host, decode_packet)` and `BIFROST_HOST_HAS(host, encode_packet)` before using the
extension. ABI version 1 and the existing packet layout are unchanged. Subscribe with `BIFROST_PACKET_FIELDS`
to enable these functions for that callback; this flag does not decode the packet automatically. Raw access,
replacement and cancellation continue to work as before.

Raw-only callbacks can inspect the whole packet without requesting fields or calling the decoder:

```cpp
#include <span>

bifrost_packet_action onRaw(void *, bifrost_packet *packet) noexcept {
    const std::span<const uint8_t> bytes(packet->bytes.ptr, packet->bytes.len);
    return bytes.empty() ? BIFROST_PACKET_CANCEL : BIFROST_PACKET_PASS;
}
```

Register this callback with flags `0`. The bytes include the header and borrow host memory until the callback
returns. A fields-enabled callback has the same raw access and can choose whether to call `decode_packet`.

| type | output | fields |
|---|---|---|
| `BIFROST_PACKET_TYPE_TEXT` | `bifrost_text` | all twelve message types, source, message, localization, XUID, platform ID, optional filtered message, and up to four parameters |
| `BIFROST_PACKET_TYPE_CHUNK_RADIUS` | `bifrost_chunk_radius` | signed radius and unsigned maximum radius |

`decode_packet(context, packet, type, out, capacity)` fills the matching structure. Pass the current callback's
packet pointer and correctly aligned storage of at least `sizeof` that structure. Strings borrow the current
packet and expire when the callback returns; copy them into plugin-owned memory to keep them. Output storage
must not overlap the input packet or replacement buffer. Unsupported packet types remain available as raw bytes.

The first requested decode uses protocol-zig with the managed session's existing limits and phase/direction
checks. Its success or failure is shared across listeners on that packet. Validated subscriptions reuse this
decode, and an accepted replacement supplies a new decoded version. Rejected replacements preserve the current
version. The cache lives only in the worker's dispatch stack, with no allocation or global lock. These accessors
use the same `Current` protocol profile as the managed session; they do not assume a different client version.

`encode_packet(context, packet, type, data, size)` encodes the matching structure into the host's replacement
buffer and sets `replacement_len`. Return `BIFROST_PACKET_REPLACE` to apply it. Fields are checked and the encoded
packet remains staged until the callback returns; decoding again in that callback still reads its input.
The size is measured before writing. Failure preserves the previous replacement bytes and length. Strings and the
input structure must not overlap the output buffer. The packet ID and both sub-client indices are preserved;
the dispatch still validates the bytes after the callback returns. The replacement limit remains 64 KiB.

Both functions return `WRONG_THREAD` outside a fields-enabled callback or for another plugin's context,
`STALE_HANDLE` for a different packet pointer, `UNSUPPORTED` for an unsupported type or mismatching packet ID,
and `INVALID_ARGUMENT` for malformed data, insufficient storage, bad alignment, aliasing, or an invalid session
phase. Native code must provide valid memory for every pointer and declared length.

The Zig SDK exposes `host.decodePacket(packet, sdk.Text)` and `host.encodePacket(packet, text)`, also accepting
`sdk.ChunkRadius`. Older hosts return `error.Unsupported` without reading missing function pointers.
[`PacketFilter.cpp`](../examples/packets/PacketFilter.cpp) demonstrates subscriptions, lazy decoding, cancellation,
typed text replacement and packet injection in C++23.

### Packet injection

Check `BIFROST_HOST_HAS(host, send_packet)` before calling
`send_packet(context, player, target, bytes, done, user)`. The Zig SDK exposes
`host.sendPacket(player, target, bytes, done, user)`. `target` is `BIFROST_PACKET_TO_PLAYER` or
`BIFROST_PACKET_TO_BACKEND`, meaning that player's current backend connection. This requires `PACKETS` and
managed mode, and is available from worker callbacks, task threads and plugin-owned threads after initialization.

`bytes` is one complete packet with its canonical Bedrock header, at most 65536 bytes. Only Text in either
direction and nonnegative RequestChunkRadius to the backend are supported. Both sub-client indices must be zero.
Validation uses the managed session's `Current` protocol profile. Unsupported IDs, login/handshake/resource-pack
packets and world/entity packets are refused. The supported packets contain no entity IDs to translate; backend
radius injection also updates the radius Bifrost replays during transfers. Use protocol-zig to encode raw packets in Zig, or encode modified
fields into a callback's replacement buffer in C++ before submitting it. Input bytes are copied before return.

`OK` means accepted into the owning worker's FIFO queue, not delivered to the peer. A supplied `done` runs once
with a `bifrost_task_result`: `OK` means the normal reliable-ordered channel-0 send accepted the packet;
`STALE_HANDLE` means the player disconnected; `CANCELED` means a backend selection or transfer changed the route,
the queue closed, or shutdown started; `BUSY` means a transfer is active; `TOO_LATE` means the session is not in
game; `FAILED` means encoding or transport failed. Shutdown completions run before plugin shutdown with
`worker == BIFROST_NO_WORKER`. Keep callback state alive until completion. Rejected submissions never call `done`.

Submission returns `INVALID_ARGUMENT` for malformed packets, invalid targets or sizes, `UNSUPPORTED` for an
unsupported packet, missing capability, passthrough mode or initialization, `STALE_HANDLE` for an expired player,
`CANCELED` during shutdown or on a closed queue, `FAILED` on allocation failure, or `BUSY` when either bound is
full. Injections share the 1024-item limit with messages and posts and have a separate 4 MiB copied-payload budget;
reserved bytes and queue items are released on every delivery and failure path. Metadata is bounded by item count.

The worker drains a snapshot of the queue after transfer requests and before its next network service. Calls
accepted in queue order send in that order, after the current callback/batch has finished. Concurrent submitters
have no ordering guarantee before queue insertion. A transfer cancels queued packets even if it is rejected or
rolls back, so an old submission cannot reach a different backend. Delivery checks the live handle and route again.
Injections use the session's normal batching, compression, encryption and reliable ordered transport and bypass
packet listeners in both directions. There is no synchronous listener recursion. A completion may submit another
packet; it waits for a later drain and remains subject to the same bounds. Responses from the backend traverse
packet listeners normally.

### Command permissions

`permission` only decides whether a client lists the command in autocomplete. Bifrost never enforces it: any
client can send any command, whatever it shows, and Bifrost doesn't know which permission level the backend gave a
player, so it has nothing authoritative to check against. A command that needs authorization has to check it in the
callback against something the plugin trusts, such as a list of XUIDs it saw in `PLAYER_AUTHENTICATED`.

## Player handles

A `bifrost_player` is valid from `PLAYER_CONNECTED` until `PLAYER_DISCONNECTED` returns. After that every call with
it returns `STALE_HANDLE`, even if a new player gets the same slot. `id` 0 is never a player.

### Copied player information

API revision 2 adds `player_info(player, out, capacity)`. Check `BIFROST_HOST_HAS(host, player_info)` first,
then pass a `bifrost_player_info` and `sizeof(*out)`. It returns `INVALID_ARGUMENT` for a null or short output
and `STALE_HANDLE` for a retired handle. The output owns its bytes and contains no session pointers or borrowed
strings. It needs no allocation, takes one short handle-table lock, and is safe from any thread.

`name`, `xuid` and `uuid` have explicit byte lengths and no promised terminator. Zero length means unavailable,
including an identity field too large for its fixed buffer. Identity is copied only after successful verification.
`online` distinguishes an online identity from an authenticated offline identity; it is meaningful only when
`authentication` is `AUTHENTICATED`. Authentication may instead be pending, disabled, unavailable or rejected.
An empty name never means an authenticated anonymous player. `player_name` retains its original truncation rules.

`state` reports the connection, session mode, connection phase, current backend and transfer state. `NO_BACKEND`
means no backend has been selected. During the initial dial the selected backend is reported even before it connects.
During transfer the source remains current until commit, then the target becomes current, including inside
`TRANSFER_COMPLETED`. The handle and connection duration survive transfers. Duration uses elapsed awake-clock
milliseconds since handle creation, rather than wall time. A snapshot is coherent at the copy instant and may
immediately become stale. During `PLAYER_DISCONNECTED` it reports disconnected; after that callback the handle is retired.

Managed phases follow the player-facing Bedrock session: settings, login, handshake, resource packs, joining and
in-game. Passthrough phases are `UNKNOWN` because encrypted progress cannot be observed reliably. Both modes
report closing and disconnected. Changes publish at session/batch boundaries, with no lock or copy for unchanged
state. `TRANSFER_REQUESTED` reports requested, then snapshots expose the transfer state machine's current phase.

### Networking snapshots

`network_stats(player, target, out, capacity)` returns a `bifrost_network_stats` for `PACKET_TO_PLAYER` or
`PACKET_TO_BACKEND`. Directions are relative to the proxy: incoming is received by the proxy, outgoing is sent
by it. The backend target means the active transport, which switches at commit. It returns `WRONG_THREAD` outside
this player's worker callback, `STALE_HANDLE` for a retired handle, `TOO_LATE` before the link/backend is ready or
while closing, and `INVALID_ARGUMENT` for an invalid target or null/short output. Check the host function first.
Use `post` to query from another thread and copy the result in its completion. No internal transport pointer escapes.

Only fields whose `available` bit is set are meaningful. An unset bit means unavailable, even if the field is zero.

| availability bit | meaning |
|---|---|
| `RTT` | RakNet's smoothed RTT in milliseconds, absent until an eligible ACK sample exists |
| `RELIABILITY` | MTU, retransmission timeout, cumulative acknowledged, timed-out and retransmitted datagrams, ACK/NACK record counts |
| `QUEUES` | outbound packet/payload bytes and high-water packet count, recovery and ordered-buffer occupancy, in-flight bytes and congestion window |
| `LOSS_ESTIMATE` | `lost / (acknowledged + lost)`, scaled to parts per million, absent with no observations |
| `RATES` | backend UDP datagrams and bytes per second over `rate_interval_ms`, sampled on demand |

The loss estimate counts RakNet retransmission timeouts, which can repeat for one datagram and can result from
delay or ACK loss. It is a timeout ratio, not an end-to-end loss measurement. NACK counts and ordered-buffer
occupancy are measurements, not anomaly or out-of-order traffic counts. Retransmission counts also include
NACK-triggered retries. Byte occupancies are payload accounting, not total allocated memory.

Backend rates reuse the dedicated RakNet socket's existing counters, including control datagrams. The first
query establishes a baseline; a subsequent query at least 250 ms later yields rates for that interval. Queries
closer together report rates unavailable and leave the baseline alone. Samples are shared by plugins on that
player and reset when the active backend changes. `sampled_at_ms` uses the awake clock and has no wall-clock epoch.
Integer rates truncate fractions. There is no timer, per-packet counter, allocation, transport lock or background scan.

Player-side rates are unavailable because its listener socket serves multiple players. Jitter, duplicate traffic,
out-of-order counts and reliability anomalies are unavailable on both legs in the pinned RakNet API. Their bits
remain unset. Bifrost does not synthesize them from unrelated counters.

### Queued actions

`disconnect(player, reason, done, user)` and `request_transfer(player, backend, done, user)` accept calls from any
thread. `OK` means queued, not completed. Both share the existing 1024-item message/post/injection budget and use
one bounded allocation per accepted action. They return `BUSY` before allocation when full, `STALE_HANDLE` for a
retired handle, `UNSUPPORTED` before plugin initialization, `CANCELED` during shutdown, and `FAILED` on allocation
failure. Bad pointer/length shapes, invalid UTF-8, reasons over 1024 bytes and unknown backend indices return
`INVALID_ARGUMENT`. Empty reasons are allowed. Rejected submissions never call `done`.

The worker drains actions in insertion order after the current callback, revalidates the handle, and invokes the
optional completion exactly once. A player leaving before delivery produces `STALE_HANDLE`; shutdown cancels
pending actions with `CANCELED` and `NO_WORKER`. User data must remain alive through completion. Queue insertion
is thread-safe; simultaneous producers have no ordering guarantee before insertion. Plugins must stop their
own submitting threads before shutdown returns, as with existing posts and packet injections.

A disconnect completion reports the close being initiated, not a remote acknowledgment. Repeated attempts
return `TOO_LATE` once closing, or `STALE_HANDLE` after detachment. Managed reasons use a Bedrock Disconnect
packet through normal encryption/compression, bypassing packet listeners, before closing the reliable transport.
Delivery is best effort and depends on the peer and connection phase. `FAILED` can mean the reason failed to encode
or send; the transport still closes. In passthrough, the encrypted session is opaque, so the reason is ignored and
only the RakNet disconnect is sent. It is never sent as unencrypted chat. Disconnect also invalidates queued injections.

A transfer completion reports that the state machine started. Its eventual outcome still arrives through the
existing transfer events. Worker delivery returns `UNSUPPORTED` in passthrough, `BUSY` during another transfer,
`TOO_LATE` outside a connected in-game session or when already on that backend, `CANCELED` if a plugin vetoes,
and `FAILED` for other dial/setup failures. The original callback-only `transfer` mailbox keeps its existing contract.
Use `post` for other short worker-affine work and the existing bounded `send_packet` API for packet injection.

### Phase events and existing hooks

`CONNECTION_PHASE_CHANGED` appends one event kind. `worker`, `phase` and `previous_phase` are appended to
`bifrost_event`; older hosts require a `struct_size` check before reading them. The snapshot is updated before
dispatch. Each observed change emits once, in registration order on the player's worker. Initialization is
reported by `PLAYER_CONNECTED`, not a duplicate phase event. The final disconnected phase precedes
`PLAYER_DISCONNECTED`; the handle remains queryable until that callback returns.

Existing connection, authentication, backend selection and transfer callback ordering remains intact. No movement,
combat, interaction, dimension or respawn events are added: packet subscriptions remain the source for those
notifications and avoid extra decoding or disabling the existing relay fast path. No network anomaly event is
invented from unsupported measurements. Command name validation, autocomplete-only permissions, plugin-attributed
logs and rate-limited slow-callback diagnostics retain their existing behavior; no new permission or alert framework is added.

## Versioning

- `BIFROST_ABI_VERSION` changes only for a breaking change. Each side checks the other's `abi_version` and refuses
  a mismatch: Bifrost returns an error for the plugin, a plugin should return `INCOMPATIBLE`.
- `BIFROST_API_REVISION` identifies the header's additive API revision, currently 2. It is not a host negotiation
  field; use `BIFROST_HOST_HAS` for each optional function. Keep the host pointer rather than copying a newer
  header's entire table from an older host. New player/network snapshot layouts are fixed in v1.
- `bifrost_host` only grows at the end. A plugin must not compare `host->struct_size` with its own
  `sizeof(bifrost_host)`, or it would refuse older v1 hosts for no reason. Check the functions it needs with
  `BIFROST_HOST_HAS(host, fn)` (`host.has(.fn)` in Zig) and skip the optional ones that are missing.
  `set_description` is the first function added this way.
- Structs Bifrost passes in (`bifrost_event`, `bifrost_packet`, `bifrost_command`, `bifrost_task_result`) can grow
  at the end too: read a field newer than your header only when `struct_size` covers it.
- Structs a plugin writes into (`bifrost_plugin`, `bifrost_transfer_decision`, `bifrost_packet`) never grow in v1,
  because a newer plugin writing a field into an older host's smaller struct would corrupt it. New outputs arrive as
  new host functions instead.
- Typed outputs (`bifrost_text`, `bifrost_chunk_radius`) also keep their v1 layouts. New layouts require new packet types.
- Structs you pass in (`bifrost_command_info`) carry `struct_size` so Bifrost knows which fields you set; fill it in.
- Enums and status codes can gain values; treat unknown ones as "not for me" rather than as errors.

## Verification

`zig build test` covers the native ABI layouts and constants, borrowed field access, replacement chains,
phase and direction checks, queue limits, allocation failures, worker ownership, disconnects, transfers and
shutdown. `zig build bench-test` checks benchmark accounting and cleanup separately.

On Linux, `zig build fuzz-test --fuzz=1M` runs the native packet target with LLVM coverage instrumentation.
Its fourteen seeds cover all twelve Text variants and positive and negative chunk radii. Inputs are bounded
to 1024 bytes. Successful native decodes must survive encoding and decoding with the same fields and header.
Accepted injections must have supported types, destinations, sub-client indices and radius values. Normal
test runs replay the seeds. Existing boundary tests exercise the 65536-byte injection limit separately.

Use `zig build bench -Doptimize=ReleaseFast -- packet-dispatch decode injection --quick` for dispatch,
codec and queue costs. The optional `callback-latency`, `injection-transport` and Linux `injection-workers`
scenarios measure callback distributions and verified managed transport. Workloads, results and measurement
limits are recorded in [`tests/bench/baseline.md`](../tests/bench/baseline.md).
