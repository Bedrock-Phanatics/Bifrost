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
   - in **managed** mode Bifrost dials with the proxy key (`[session] proxy_key_file`, logged at startup) and
     re-signs the Login with it, and the backend must accept that key as an issuer;
   - in **passthrough** mode the backend gets the player's own Login and must skip comparing its key with the
     NetherNet identity for connections from Bifrost's key. Bifrost has already made that comparison itself.

Without the third point, a backend that checks the Login against the transport identity (gophertunnel and
Quark v6 both do for Xbox logins) turns every proxied player away. That is deliberate: the check is what stops a
replayed Login, and Bifrost doesn't try to work around it.

## Quark v6

Quark v6 serves NetherNet from `src/network/mcpe/nethernet` using the PHP `webrtc` extension, with HTTP signaling
on `server-port`. Framing, the missing encryption handshake and the status endpoint all match.

Since Quark `acad4380b` (branch `v6.0.0`) it can trust Bifrost. Copy the key Bifrost logs at startup
("backends must trust proxy key ...") into `server.toml`:

```toml
[network]
trusted-proxy-keys = ["MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE..."]
```

- **managed** dials with the proxy key and signs the Login with it, so one key covers both. Quark takes the
  name, UUID and XUID from the Login and counts the player as Xbox authenticated when a XUID is present. With
  `[auth] mode = "off"` there is no XUID, so the player only gets in with `xbox-auth = false`.
- **passthrough** dials with `[nethernet] identity_file`, and that is the key logged. Quark verifies the forwarded
  Xbox Login as usual and only skips comparing it with the NetherNet identity.

Managed Logins also carry a signed `PlayerAddress` claim, which Quark `a2cf1f81e` and newer use as the session
IP. Passthrough has nowhere signed to put it, so Quark sees Bifrost's address there. With `[auth] mode = "off"`
Bifrost dials with a throwaway key, so no backend can be set up to trust Logins nobody verified. See the
[setup guide](setup.md) for the recommended configuration.

Quark honours a proxy-signed Login only on a NetherNet connection whose identity is a trusted key, and the
identity assertion proves the dialer holds that key. A trusted proxy can log in as anyone, so list only proxies
you run. Older Quark builds have none of this: there, managed works only with `xbox-auth = false` and without
XUIDs, and passthrough doesn't work at all.

This was checked by verifying a bedwire-built proxy Login with Quark's own parsing and signature code. A full
Bifrost-to-Quark session with a real client hasn't been run.

## Other backends

gophertunnel-based servers (`minecraft.NetherNet`) behave like older Quark builds: they check the Login key against the
NetherNet identity whenever the Login is authenticated, and have no proxy trust either. How vanilla BDS treats a
proxied connection wasn't checked. Bifrost was tested against its own in-process backends built on bedwire and
nethernet-zig, not against any of these servers.
