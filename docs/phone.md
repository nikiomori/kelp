# Kelp on your phone

Settings › Phone puts your agents in a phone's browser: the list, what each said, Allow and Deny, a reply, Stop, and
a notification when one needs you. It's a web page, not an app from a store, and Kelp serves it itself.

## How a phone gets to your Mac

kelpd serves the page and answers its calls on a port of localhost (47611, `phone.port` in settings.json). Nothing
outside the Mac reaches that port by itself; one of these brings the phone there:

- **Tailscale.** Kelp has Tailscale serve the port at your Mac's name in your tailnet
  (`https://<mac>.<tailnet>.ts.net:8443`). Your tailnet's access rules must allow the phone to reach the Mac on port 8443.
  The tailnet needs HTTPS certificates enabled. Settings shows Ready once Kelp owns its local port and Tailscale
  serves the page. Pair the browser separately to give it access to the agents.
- **Your own address.** A tunnel or a proxy of yours (Tailscale Funnel, Cloudflare Tunnel, nginx) that shows the port
  at an HTTPS address; you give Kelp that address. It has to stay the same: a phone keeps its pairing for the address
  it paired at.
- **A relay.** A server with a public address the Mac keeps a connection open to (`relay/`). Kelp's own runs at
  `phone.kelpide.com`; you can run yours. The relay serves the page, so choose one you trust (below).

Kelp records the private Tailscale routes it creates. On restart it checks for a leftover route even if Phone is off
or the local port is occupied. If you already published the same address yourself, Kelp can use it while Phone is on.
That route stays under your control when you switch Phone off. This also applies to matching routes inherited from a
Kelp version that did not record ownership.

Push doesn't take any of these roads: the Mac sends it to the phone's browser's push service (Apple's, Google's,
Mozilla's, Microsoft's), encrypted for that browser (RFC 8291) and signed as the Mac's (VAPID).

## Pairing

Settings › Phone › Show Pairing Code gives a link with a QR code: `<address>/#pair=<mac id>.<key>`. The key is 32
random bytes, good for one phone and ten minutes, and sits in the fragment, which a browser never sends anywhere.
The browser saves its own device key before sending the pairing request. The Mac confirms the pairing once it has
saved that key and the device record. If the connection drops after the Mac accepts it, the browser can recover on
reconnect with the saved device key. A new pairing always requires a browser page that supports device keys.

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
(the Mac checks its ID even when the next question has identical text), type a reply, or press Esc to stop one.
Starting a new agent is off until Settings › Phone turns it on. The phone can then start the agents found on this Mac
in the projects Kelp lists. Projects with a custom sidebar color use it on the phone in both light and dark mode.

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

- `swift test --filter 'aPhone|aBusyPhonePort|phoneStateChanges|onlyKelps|boxesNodeSealedOpen|aPushIs|noNumberCountsTwice'`: boxes sealed by another implementation
  opened here, the replay rules, RFC 8291's Appendix A as the push vector, a phone pairing and allowing end to end.
- Serve the repository on localhost and open `Tests/Phone/access.html` in a fresh browser profile to check interrupted pairing, live updates and push subscription recovery.
- `curl http://127.0.0.1:47611/` with Settings › Phone on: the page, as the phone gets it.
- `relay/README.md`: running a relay of your own.
