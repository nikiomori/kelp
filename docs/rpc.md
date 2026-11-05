# Kelp's daemon API

`kelpd`, the background service that runs your agents, answers JSON-RPC 2.0 on a Unix socket. Kelp's window, the `kelp`
CLI and agents' scripts all use it; so can your own tools: a status bar item, a phone bridge, a script that starts an agent
on every new issue.

## Connecting

- The socket: `~/.kelp/kelp.sock` (`$KELP_SOCKET` inside a Kelp terminal). Only your user can open it.
- One JSON message a line, each way. Replies carry the request's `id` and may come back in any order.
- Events come as notifications (no `id`): `event.session` whenever an agent's record changes (status, title, unread),
  `event.repo`, `event.worktree`, `event.removed`. Others (`event.git`, `event.ci`, …) come after `watch.start`, which is
  Kelp's own and may change.

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"session.list"}' | nc -U ~/.kelp/kelp.sock
```

```python
import json, os, socket
s = socket.socket(socket.AF_UNIX); s.connect(os.path.expanduser("~/.kelp/kelp.sock"))
s.sendall(b'{"jsonrpc":"2.0","id":1,"method":"session.send","params":{"id":"<session>","text":"Run the tests","enter":true}}\n')
print(s.makefile().readline())
```

## What's there

`kelp schema` lists every method and event with its parameters and result; `kelp schema session.send` shows one;
`kelp schema --openrpc` prints the whole OpenRPC document (`Sources/Core/Resources/rpc.json`). The ones most tools need:

| Method | Does |
| --- | --- |
| `repo.list`, `worktree.list` | projects and their workspaces |
| `session.list` | agents and terminals, with status (`working`, `waiting`, `done`, …), title, unread |
| `session.create` | starts an agent (`agent`, `worktreeId`, `prompt`, `model`) |
| `session.send` | types text into a session, Return after it with `enter` |
| `session.read` | what its screen shows now, as text |
| `session.choose` | answers its question: `allow` or `deny` |
| `session.kill` | stops it |

## The promise

The API's version is `info.version` in the schema, now **1.0.0**.

1. **Nothing public goes or changes.** A method, an event, a parameter or a field of a result, once in a release, keeps its
   name and type. A test (`rpcSchemaOnlyGrows`) fails the build when one would.
2. **Things are only added.** New methods, new optional parameters, new fields in results. A client should ignore fields it
   doesn't know.
3. **`x-internal` is outside the promise.** Those methods are for Kelp's window and tools (layouts, watches, the UI relay)
   and may change in any release.
4. **What a session may do is limited by where it runs.** A program inside an agent's session acts only on that agent and the
   agents it started; an agent's question is answered only from outside every agent's session (your terminal, the window).
   See `docs/architecture.md`.

A change that has to break this would be version 2.0.0, said in the release notes, with the old shape kept for a release.
