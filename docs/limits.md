# Resource limits

Bifrost enforces these itself, before and independently of plugins. Everything here is in `[limits]` of
`config/bifrost.toml` unless noted. "Per worker" limits multiply by `[server] workers`.

## Connection stages

A player's stage is checked about once a second. Entering a new stage restarts its clock.

| stage | ends when | limit | default |
|---|---|---|---|
| login | the player's Login is through and the backend accepted the proxy's (passthrough: the Login was seen) | `login_timeout_ms` | 30 s |
| resource packs | the client finishes the pack stack | `resource_pack_timeout_ms` | 10 min |
| joining | the client is in game | `join_timeout_ms` | 2 min |

Login includes backend dialing and the backend's own login, so a slow or retried dial counts against it. Each
dial is also bounded by `connect_timeout_ms`, and transfers keep their own `[transfer]` phase and total timeouts.
A player that runs out of time gets a "Timed out" disconnect (managed mode) and its link, backend connection and
queues are freed. Passthrough stops reading the Bedrock session after the Login, so from then on only the
transport notices a dead peer.

## Signaling

| what | scope | limit | default |
|---|---|---|---|
| NetherNet handshakes in flight | whole proxy | `[nethernet] max_negotiations` | 32 |
| the same, from one IP | whole proxy | `[nethernet] max_negotiations_per_ip` | 4 |
| one HTTP signaling request | per request | fixed | 15 s, 1 MiB offer |
| finished handshakes waiting for a worker | per worker | fixed | 64 |

A handshake over these limits gets HTTP 503 before any WebRTC state is created. ICE and DTLS must finish within
`connect_timeout_ms` of the answer. Players behind one NAT share the per-IP count.

## Memory

| what | scope | limit | default |
|---|---|---|---|
| packets waiting for a backend dial, the managed login or a transfer target | per player | `pending_packets` / `pending_bytes` | 64 / 1 MiB |
| room past that for the batch a transfer target already has in flight | per transfer | fixed | 1024 packets / 4 MiB |
| the same queues, all players together | whole proxy | `total_pending_bytes` | 256 MiB |
| one NetherNet message | per connection | fixed | 2 MiB |
| received messages not yet read | per connection | fixed | 512 KiB / 512 messages |
| messages sent but not yet taken by the peer | per connection | fixed | 1 MiB, then reading stops (see below) |
| what SCTP had accepted when the peer closed while reading was paused | per connection | fixed | 1 MiB / 1024 messages |
| Bedwire buffer pools | per worker | fixed, sized by the packet limits | 2.5 MiB for the passthrough observer |
| plugin messages, posts, actions and injections | whole proxy / per plugin | fixed | 1024 / 256 items |
| copied injection payloads | whole proxy / per plugin | fixed | 4 MiB / 1 MiB |
| plugin tasks | whole proxy / per plugin | fixed | 128 / 32 |
| tracked entities | per player | fixed | 1024, about 100 KiB |

`total_pending_bytes` is a reservation taken before each copy and given back exactly once when the queue is
flushed, cleared or freed. A player that would go over it is disconnected; a transfer that would go over it fails
before commit and the player stays where they were. Refusals are counted and reported every minute.

Every link holds two NetherNet connections, one to the player and one to the backend. Their receive queues and
scratch buffers are reserved up front but only touched as they fill, so an idle player costs far less than the
limits above.

## CPU

| work | scope | limit | default |
|---|---|---|---|
| login signature checks (`[auth] mode = "verify"`) | per worker | `logins_per_second`, burst 2x | 100/s |
| decompressed bytes from a player | per player | `player_bytes_per_second`, burst 4x or at least 4 MiB | 8 MiB/s |
| concurrent transfers | per worker | `[transfer] max_concurrent` | 64 |
| messages handled per link per turn | per worker | fixed | 64 each way |
| ICE, DTLS and SCTP | whole proxy | `[nethernet] threads` | one per core, up to 4 |

A throttled login is told the server is busy (managed mode) before any signature is checked. A player over their
byte rate is disconnected as a flood; in passthrough this only applies until the Login is through. Batches
relayed without decompressing, and anything the backend sends, are not metered. The opaque relay never inflates a
compressed batch. Plugin transfer and action calls past `max_concurrent` get `BUSY`.

## Backpressure

Once 1 MiB is waiting to go out to a player, Bifrost stops reading that player's backend until it drains to half.
The backend's receive queue then fills and SCTP stops taking from it, so its own flow control slows it down and
nothing is dropped or reordered. Plugin injections to a peer that far behind get `BUSY`. A player still that far
behind after `slow_player_timeout_ms` (5 s) is disconnected with "Connection too slow".

The other way works the same: a backend that falls 1 MiB behind stops Bifrost reading from its player. Sends
never fail for lack of room, because reading always stops before the native send buffer could fill. A link
waiting on one side is woken by the transport the moment that side drains to half, nothing polls for it.

During a transfer, what the target sends waits until the client is in its dimension. Once that hold reaches
`pending_bytes` the target isn't read either, so its own flow control slows it down instead of the transfer
failing, and the batch already on its way still fits.

Closing a connection waits, for up to 2 s, until the far end has acknowledged everything already sent, so a
Disconnect reason or a player's last packets still arrive at the proxy and go on to the backend. A receive queue
with less than 256 KiB free stops SCTP reading; if the far end closes meanwhile, what SCTP had already accepted is
handed over on the close and read before the connection is let go, so a peer's last packets never go down with it.
Stopping the proxy tells managed players "Proxy shutting down" and gives every connection the same 2 s to
drain before it is closed.

## Diagnostics

Rejected connections log at most one warning every 10 s per worker, with a count of the ones skipped. The minute
report adds a line with rejections, timeouts, throttled logins, floods, slow players, queue refusals and queued
bytes whenever any of them is non-zero. The same counters are in `Stats`.

## Plugins

Native plugins run inside the proxy process. The limits above cover what they can ask Bifrost to queue or send,
but a plugin can still allocate, block or crash on its own; there is no sandbox. Only load plugins you trust.
