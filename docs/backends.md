# Backend support

Bifrost reaches every backend over NetherNet, the same way a player does. A backend needs:

1. **HTTP signaling.** `POST /v1/join/<id>` with an `application/sdp` offer on the address in `[[backend]]`,
   answered with the SDP answer, as vanilla servers do. Bifrost uses a random decimal `<id>`. `GET /v1/join`
   should answer with the server-list JSON; its `players` field feeds the player count Bifrost shows, and any
   2xx counts as healthy.
2. **A `ReliableDataChannel`** carrying Bedrock batches without the `0xfe` header and without Minecraft's
   ServerToClientHandshake, since DTLS already encrypts the connection. The backend answers the Login with
   PlayStatus straight away. Bifrost sends nothing on the unreliable channel in managed mode and forwards it
   untouched in passthrough.
3. **A way to trust the proxy.** Bifrost proves its own key when it dials (`[nethernet] identity_file`, a
   self-signed ES384 identity in the SDP). It can't prove the player's key, because that needs the player's private
   key. So:
   - in **managed** mode the backend gets a Login re-signed by the proxy key (`[session] proxy_key_file`, logged at
     startup) and must accept that key as an issuer;
   - in **passthrough** mode the backend gets the player's own Login and must skip comparing its key with the
     NetherNet identity for connections from Bifrost's key. Bifrost has already made that comparison itself.

Without the third point, a backend that checks the Login against the transport identity (gophertunnel and
Quark v6 both do for Xbox logins) turns every proxied player away. That is deliberate: the check is what stops a
replayed Login, and Bifrost doesn't try to work around it.

## Quark v6

Quark v6 serves NetherNet from `src/network/mcpe/nethernet` using the PHP `webrtc` extension, with HTTP signaling
on `server-port`. Framing, the missing encryption handshake and the status endpoint all match. What it lacks:

| needed | Quark v6 today |
| --- | --- |
| trust a proxy's Login signer | none; a Login not signed by Microsoft is treated as self-signed and only allowed with `xbox-auth = false`, and then the player gets no XUID |
| skip the Login-to-transport key check for a trusted proxy | none; with an authenticated Login the check always runs, and the player is kicked before any plugin event |
| verify the dialing identity's issuer | none; any well-formed, unexpired ES384 token is accepted, so pinning Bifrost's key would need new code |

So today, with Quark v6:

- **managed** works only with `xbox-auth = false`. Players get in, but without a XUID, and `player.verify-xuid`
  then kicks anyone whose saved data has one.
- **passthrough** doesn't work. With Xbox auth on, the forwarded Login fails the key check against Bifrost's
  identity. With it off, Quark still validates the Login and runs the same check.

Closing the gap needs a trusted-proxy option in Quark: a list of proxy keys whose NetherNet connections may
present a Login signed by that key (managed) or skip the transport key check (passthrough), keeping the XUID from
the Login. Until then, run Bifrost in front of Quark only for offline or testing setups.

## Other backends

gophertunnel-based servers (`minecraft.NetherNet`) behave like Quark here: they check the Login key against the
NetherNet identity whenever the Login is authenticated, and have no proxy trust either. How vanilla BDS treats a
proxied connection wasn't checked. Bifrost was tested against its own in-process backends built on bedwire and
nethernet-zig, not against any of these servers.
