# Kelp on your phone

Settings › Phone puts your agents in a phone's browser: the list, what each said, Allow and Deny, a reply, Stop, and
a notification when one needs you. It's a web page, not an app from a store, and Kelp serves it itself.

## How a phone gets to your Mac

kelpd serves the page and answers its calls on a port of localhost (47611, `phone.port` in settings.json). Nothing
outside the Mac reaches that port by itself; one of these brings the phone there:

- **Tailscale.** Kelp has Tailscale serve the port at your Mac's name in your tailnet
  (`https://<mac>.<tailnet>.ts.net:8443`). The phone, signed in to the same tailnet, reaches the Mac directly.
  It needs HTTPS certificates turned on for the tailnet (Tailscale's admin console, DNS).
- **Your own address.** A tunnel or a proxy of yours (Tailscale Funnel, Cloudflare Tunnel, nginx) that shows the port
  at an HTTPS address; you give Kelp that address. It has to stay the same: a phone keeps its pairing for the address
  it paired at.
- **A relay.** A server with a public address the Mac keeps a connection open to (`relay/`). Kelp's own runs at
  `phone.kelpide.com`; you can run yours. The relay serves the page, so choose one you trust (below).

Push doesn't take any of these roads: the Mac sends it to the phone's browser's push service (Apple's, Google's,
Mozilla's, Microsoft's), encrypted for that browser (RFC 8291) and signed as the Mac's (VAPID).

## Pairing

Settings › Phone › Show Pairing Code gives a link with a QR code: `<address>/#pair=<mac id>.<key>`. The key is 32
random bytes, good for one phone and ten minutes, and sits in the fragment, which a browser never sends anywhere.
The phone seals its first call under it, names a key of its own inside, and from then on is known by that key only:
the link opens nothing afterwards, even if it stayed in a Home Screen app's address or on a clipboard.

Settings › Phone lists the phones paired; Remove forgets one, and its key stops opening anything.

## What's sealed

Every call is `POST /api/call {mac, device, box}`. `box` is base64url of AES-256-GCM's nonce (12 bytes),
ciphertext and tag (16), JSON inside, with what it is as additional data: `q` a request, `r<n>` its answer,
`e<n>.<i>` the i-th event of the stream request `n` opened. So nothing can be swapped between directions or streams.

`n` is the phone's clock in 1/4096 ms and never repeats. The Mac refuses one it saw, one more than five minutes behind
the newest, and after a restart anything that could have been seen (the newest it wrote down and a second over it).

Refusals go unsealed: 401 a phone that isn't paired or a box that doesn't open, 409 a number seen before.

The code: `Sources/Daemon/Phone/` (the Mac), `Sources/Daemon/Resources/phone/js/api.js` (the phone).

## What a paired phone may do

Read the agents and their conversations, mark one read, answer Allow or Deny to the question the phone was shown
(and only that one), type a reply, press Esc to stop one. Starting a new agent is off until Settings › Phone turns
it on, and then only the agents found on this Mac, in the projects Kelp lists.

A phone acts as you: what it does goes through the same calls Kelp's window makes.

## What each party sees

| | sees | doesn't see |
| --- | --- | --- |
| Tailscale, your tunnel | that a phone talks to your Mac, how much | anything said: it's sealed |
| A relay | which Mac and which phone (random ids), how much | anything said |
| The push service | that a notification went to this browser | its words: encrypted for the browser |
| Kelp's authors | nothing, unless you choose Kelp's relay; then what a relay sees | |

## What it doesn't guard against

- **A server that serves the page.** The page runs the code that holds the key. A relay that served another page
  could take the key from a pairing link. With Tailscale or your own address, kelpd serves the page from inside Kelp,
  and only what passes is on the way.
- **A phone that's unlocked in someone else's hands.** The pairing lives in the browser's storage on the phone.
  Remove the phone in Settings › Phone.
- **This Mac.** Whoever runs code on it can read the keys from your keychain.

## Check it yourself

- `swift test --filter 'PhoneBridgeTests|PhoneServerTests|PhonePushTests'`: boxes sealed by another implementation
  opened here, the replay rules, RFC 8291's Appendix A as the push vector, a phone pairing and allowing end to end.
- `curl http://127.0.0.1:47611/` with Settings › Phone on: the page, as the phone gets it.
- `relay/README.md`: running a relay of your own.
