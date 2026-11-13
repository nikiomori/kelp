# A phone relay of your own

Kelp's phone page is served by Kelp itself (Settings › Phone), and a phone usually reaches the Mac over Tailscale
or a tunnel of your own. A relay is for when neither fits: a server with a public HTTPS address that the Mac keeps a
connection open to, so no Mac needs an address of its own. This is the whole of it: one file, Node 26, no
dependencies.

```sh
PORT=8080 node relay/server.mjs           # serves ../Sources/Daemon/Resources/phone and passes the phone's calls
docker compose -f relay/docker-compose.yml up -d
```

Put HTTPS in front of it (Caddy, nginx, Cloudflare): browsers give a page's encryption and push only to a secure
origin. Then in Kelp, Settings › Phone › Kelp's Relay, or `phone.relay` in settings.json, names your address.

## What it sees

- Which Mac a call is for and which phone sends it: random ids, made by the Mac and the phone.
- Nothing of what's said. Each call and answer is AES-256-GCM, sealed under a key the phone took from its pairing
  code, which never leaves the phone and the Mac (`Sources/Daemon/Phone/PhoneSeal.swift`,
  `Sources/Daemon/Resources/phone/js/api.js`).
- Push doesn't pass here: the Mac sends it to the phone's push service itself.

`data/macs.json` keeps each Mac's id and the hash of the secret it first came with, so nobody else can come as it.
A Mac not seen for 180 days is forgotten.

## What it doesn't guard against

It serves the page. A relay that served another page could take the key from a pairing link. That's why Kelp
serves the page itself by default; run a relay only where you trust the server it runs on.

## Limits

One process, everything in memory: 3000 connected Macs measured at about 25 KB each. One address may hold 20 Macs'
connections; a Mac may have 32 calls waiting; a phone's call is at most 128 KB and waits 20 s for its Mac.
