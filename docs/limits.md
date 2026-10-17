# Resource limits

Bifrost enforces these itself, before and independently of plugins. Everything here is in `[limits]` of
`config/bifrost.toml` unless noted. "Per worker" limits multiply by `[server] workers`.

## Connection stages

A player's stage is checked about once a second. Entering a new stage restarts its clock.

| stage | ends when | limit | default |
|---|---|---|---|
| login | the player and backend handshakes are both done (passthrough: the handshake is no longer visible) | `login_timeout_ms` | 30 s |
| resource packs | the client finishes the pack stack | `resource_pack_timeout_ms` | 10 min |
| joining | the client is in game | `join_timeout_ms` | 2 min |

Login includes backend dialing and the backend's own handshake, so a slow or retried dial counts against it.
Each dial is also bounded by `connect_timeout_ms`, and transfers keep their own `[transfer]` phase and total
timeouts. A player that runs out of time gets a "Timed out" disconnect (managed mode) and its link, backend
connection and queues are freed. Passthrough can't see past encryption, so after login only RakNet's idle timeout
applies.

## Memory

| what | scope | limit | default |
|---|---|---|---|
| packets waiting for a backend dial, the managed login or a transfer target | per player | `pending_packets` / `pending_bytes` | 64 / 1 MiB |
| the same queues, all players together | whole proxy | `total_pending_bytes` | 256 MiB |
| RakNet player sessions | per worker | fixed | 512 MiB |
| RakNet send queue to one peer | per session | fixed | 1024 packets / 16 MiB |
| Bedwire buffer pools | per worker | fixed, sized by the packet limits | 2.5 MiB for the passthrough observer |
| plugin messages, posts, actions and injections | whole proxy / per plugin | fixed | 1024 / 256 items |
| copied injection payloads | whole proxy / per plugin | fixed | 4 MiB / 1 MiB |
| plugin tasks | whole proxy / per plugin | fixed | 128 / 32 |
| tracked entities | per player | fixed | 1024, about 100 KiB |

`total_pending_bytes` is a reservation taken before each copy and given back exactly once when the queue is
flushed, cleared or freed. A player that would go over it is disconnected; a transfer that would go over it fails
before commit and the player stays where they were. Refusals are counted and reported every minute.

A held player costs about 270 KiB of heap in passthrough. Backend RakNet clients are bounded per connection by
RakNet's own limits but share no proxy-wide quota.

## CPU

| work | scope | limit | default |
|---|---|---|---|
| login signature checks (`[auth] mode = "verify"`) | per worker | `logins_per_second`, burst 2x | 100/s |
| decompressed bytes from a player | per player | `player_bytes_per_second`, burst 4x or at least 4 MiB | 8 MiB/s |
| concurrent transfers | per worker | `[transfer] max_concurrent` | 64 |

A throttled login is told the server is busy (managed mode) before any signature is checked. A player over their
byte rate is disconnected as a flood; in passthrough this only applies while the handshake is still being read.
Batches relayed without decompressing, and anything the backend sends, are not metered. The opaque relay never
inflates a compressed batch. Plugin transfer and action calls past `max_concurrent` get `BUSY`.

## Backpressure

When a player's RakNet send queue holds 256 packets or 4 MiB, Bifrost stops reading that player's backend until
the queue drains to half. The backend then slows down through RakNet's own flow control, so nothing is dropped and
reliable ordering is kept. Plugin injections to a peer that far behind get `BUSY`. A player still that far behind
after `slow_player_timeout_ms` (5 s) is disconnected with "Connection too slow".

Player to backend traffic is not paused. It is small in practice, and RakNet's per-session limits still apply.

## Diagnostics

Rejected connections log at most one warning every 10 s per worker, with a count of the ones skipped. The minute
report adds a line with rejections, timeouts, throttled logins, floods, slow players, queue refusals and queued
bytes whenever any of them is non-zero. The same counters are in `Stats`.

## Plugins

Native plugins run inside the proxy process. The limits above cover what they can ask Bifrost to queue or send,
but a plugin can still allocate, block or crash on its own; there is no sandbox. Only load plugins you trust.
