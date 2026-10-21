# Running Bifrost in front of Quark

The recommended setup is **managed mode with auth on**. Bifrost checks each player's Xbox login, then logs in to
Quark on their behalf with a key Quark trusts. Quark gets the player's name, UUID, XUID, skin and real IP.

```
player ──NetherNet──> Bifrost (public, verifies Xbox) ──NetherNet──> Quark (private, trusts Bifrost's key)
```

## 1. Bifrost

Download Microsoft's signing keys and save them next to the config:

```sh
curl -o minecraft-keys.json https://authorization.franchise.minecraft-services.net/.well-known/keys
```

Microsoft rotates these keys, so refresh the file now and then (a daily cron job is plenty).

In `config/bifrost.toml`:

```toml
[auth]
mode = "verify"
keys_file = "minecraft-keys.json"

[session]
mode = "managed"
proxy_key_file = "bifrost-proxy.key"

[[backend]]
name = "lobby"
address = "10.0.0.2:19132"   # Quark's private address
```

Start Bifrost once. It creates the key and logs it:

```
managed sessions; backends must trust proxy key MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE...
```

## 2. Quark

Quark v6 needs `acad4380b` or newer, or `a2cf1f81e` or newer to get players' real IPs. In `server.toml`:

```toml
[server]
xbox-auth = true

[network]
trusted-proxy-keys = ["MHYwEAYHKoZIzj0CAQYFK4EEACIDYgAE..."]
```

Quark logs `Trusting 1 proxy key(s)` at startup. With several Bifrost instances, list each one's key.

## 3. Lock it down

- **Firewall Quark.** Only Bifrost should reach Quark's signaling port and its UDP ports. Otherwise players can
  join Quark directly and skip the proxy's plugins and limits. Their logins are still checked, so this isn't an
  impersonation risk.
- **Guard `bifrost-proxy.key`.** Whoever has it can join Quark as any player. Keep it readable only by the account
  Bifrost runs as and out of backups you share. If it leaks, delete it, restart Bifrost, and replace the key in
  `trusted-proxy-keys`.
- **Keep `bifrost-identity.der` too.** Players confirm it the first time they join, so losing it makes them
  confirm a new one.
- **Only list proxies you run** in `trusted-proxy-keys`.

## Other modes

| setup | use it for | what Quark sees |
| --- | --- | --- |
| managed + `auth = "verify"` | **production** | name, UUID, XUID, skin, real IP |
| passthrough + `auth = "verify"` | when Quark must check every Xbox login itself | name, UUID, XUID, skin, Bifrost's IP |
| passthrough + `auth = "off"` | local testing | offline players only, with `xbox-auth = false`. Bifrost dials with a throwaway key, so Quark can't be made to trust it |

In passthrough, the key to trust is the one Bifrost logs, which comes from `identity_file`. IP forwarding isn't
available there, so IP bans and per-IP limits in Quark see every player as Bifrost.

## What the trust covers

- Quark honours a Bifrost-signed login only on a NetherNet connection that proves it holds a trusted key. A
  captured login can't be replayed from anywhere else, and never over RakNet.
- Bifrost signs logins for 60 seconds at most, so a stolen one goes stale quickly.
- A trusted proxy is believed about who the player is. That's the point of trusting it, and it's why the key
  must stay private.

Not yet tested: a real Bedrock client joining Quark through Bifrost end to end. The pieces were checked
separately, including a bedwire-built login verified by Quark's own code.
