# Kelp architecture

Kelp is a thin native shell around two things: a **daemon** that owns everything stateful
(agent sessions/PTYs, git, integrations, settings) and **extensions** that contribute almost
everything you see. The app itself only provides the window, the layout, a registry of
contributions, the command palette and settings.

```
┌ Sidebar ────────┐┌ Editor area ─────────────────────────────┐┌ Inspector ──────┐
│ Project       + ││ [Claude ●][Terminal][app.ts][Browser]    ││ ▤  ⎇  ☰  …      │
│  ▾ Workspace 1  ││ ┌──────────────────┬──────────────────┐  ││ Files / Source  │
│     ✻ Claude ⚙  ││ │ agent terminal   │ file / browser / │  ││ Control / Issues│
│     ✻ Codex ?   ││ │                  │ diff / ext view  │  ││ + extension     │
│  ▸ Workspace 2 ✓││ └──────────────────┴──────────────────┘  ││   panels        │
│ Limits          ││   groups split freely, tabs of any kind  ││                 │
└─────────────────┘└──────────────────────────────────────────┘└─────────────────┘
```

## Concepts
- **Project**: a folder, usually a git repository; one added without git still has files, terminals and agents (`repo.*` RPCs).
- **Workspace**: a desk in the project's folder — its own tabs, splits and agents, nothing on disk
  (`workspace.create`, stored as worktree records whose path is the repo path). "+" opens a new one instantly,
  named "Workspace N" until its first agent prompt names it; several desks share the folder.
  Closing one ends its agents and leaves the files. (Workspaces from older versions may be git worktrees.)
- **Agent**: a session in a workspace (`session.*`). Status: working · needs input · done · idle · paused · ended.
  `kelp why <session>` says where its status came from and what led there (`history/<id>.trail`, kept with the session).
- **Tab**: anything shown in the editor area, addressed by a URI:
  `session:<id>`, `file:<path>#L12`, `diff:<path>`, `https://…`, `ext:<extension>/<view>`.
  Groups of tabs split right/down; drag tabs between groups or onto an edge to split.
  The model (`WorkspaceLayout`, `TabURI`) is in WorkbenchKit, a library with tests and no AppKit, like VS Code's `common/`.
- **tmux session**: a terminal tab running `tmux new-session -A -s <name>` (`terminal:?tmux=<name>`, `session.create`'s
  `tmux`), picked from the sessions tmux has on the workspace's machine (`tmux.list`; a remote project's host) in
  File › Attach to tmux Session or "+". tmux keeps the session: after the daemon restarts the tab comes back paused and
  attaches again when shown, and closing it only detaches. With `terminal.tmux` on, every new terminal runs in a tmux
  session of its own (`kelp-tab-…`, left out of the picker), which ends when its tab is closed.
- **Remote agents** run in a tmux session of their own on the host when it has tmux (`Session.tmux`,
  `RemoteHost.command(_:inTmux:)`): the agent keeps working through a dropped connection or a daemon restart, a wake or
  Restart attaches to it again ("Connection lost" › Reconnect), closing the tab ends it. Their status comes from the
  screen (hooks are files on this Mac); after attaching, tmux's redraw doesn't count as a turn.

## Contribution points (built-in Swift extensions and `extension.json` folders use the same ones)
| Point | Where it shows |
| --- | --- |
| panels | right inspector (selector icons) |
| editors | center tab types, listed in each pane's "+" menu and the empty workspace |
| commands | command palette (⇧⌘P), menus, key bindings, `kelp run <id>` |
| settings | Settings window (generated forms) and `~/.kelp/settings.json` |
| themes | Appearance settings; build the window round the terminal and editor, and color all three |
| agents | agent CLIs offered in the "+" menu and the empty workspace |
| languages | file tabs: completion and jump to definition from the language server; Run File, Test at Cursor and Format Document (⌘R / ⌘U without project commands) (built in: Swift, TS/JS, Python, Go, Rust) |

Every action of the app is a command with an id (`workbench.toggleSidebar`, `editor.saveAll`, `agents.new`…), as in
VS Code and Zed: the menu bar is laid out by id (`AppDelegate.buildMenu`), settings.json `keys` rebinds by id, and agents
run the same ids with `kelp run`.

Built-ins (Agents, Files, Git, Issues, Browser, Activity) can be turned off like any other extension. Each is a
module of its own (`Sources/Builtins/<Feature>`, target `Builtin<Feature>`) that depends on KelpKit — the shell — and on
no other built-in. It sees only what KelpKit declares `package`: the contribution types (`TabContent`, `PanelSpec`,
`CommandSpec`…), `AppModel` and its one error path, `app.workbench` (open a URI, show a panel), shared views and
helpers. The window, the sidebar and the inspector stay the shell's, so the compiler, not a convention, keeps a
feature from reaching into them, and the shell can't name a built-in either: the app's target alone lists them
(`Builtins.all`, handed to `runApp`). Kelp ships no example
extensions: user extensions live in `~/.kelp/extensions/<id>/` — see [extensions.md](extensions.md) — and can be
turned off or removed.

What every view is drawn with is DesignKit, a module the shell, EditorKit and the built-ins share (AppKit only, so it
doesn't count against KelpKit's `package` ceiling): the design system's sizes (`Metrics`, `Motion`: `Motion.duration` is
0 under Reduce Motion), text that follows Settings › Appearance › Text size (`TextSize`, `NSFont.ui` / `uiDigits` /
`uiMono`: everything but code), colours (the text shades of the status colours, `gitLetter`, the three grey fills,
`NSColor(hex:)`) and the parts views are built from — a panel's header or a tab's toolbar (`Bar.panel`, `Bar.content`),
`IconButton`, the inspector's row (`ListRowView`), `EmptyStateView` (an error is one too), `FloatingCard` for what floats
over a tab, and the find bar's ↑ ↓ (`NSSegmentedControl.steps`). A panel takes these instead of measuring its own, so
every panel looks like one; the rules behind them are in the Kelp design system.

## Source Control
The Git built-in is a VS Code-style Source Control panel (`Sources/Builtins/Git/SourceControl.swift`): branch menu, commit box
(Commit / Commit & Push / Amend), Merge / Staged / Changes sections with stage, unstage and discard, and a history graph
whose lanes GitKit computes (`GitKit/History.swift`). Rows open `diff:` tabs, side by side or inline with hunk staging.
Git runs in the daemon (`Daemon/GitHandlers.swift`: `git.branches`, `git.switch`, `git.graph`, `git.commitFiles`,
`git.discard`, `git.remote`, `git.stash` …), never on the main thread.

## Settings
`~/.kelp/settings.json`, owned by the daemon (`settings.get` / `settings.set`, `event.settings`
on change, also when the file is edited by hand). Flat dotted keys, VS Code style.

## AI agents and the IDE: skills
Every agent session gets `KELP_SOCKET` and the `kelp` CLI on PATH (open files/URLs, settings, extensions,
`ui state`). What an agent should *do* with it comes from two skills the app writes as Claude Code plugins in
`~/.kelp/agent-skills/` (`AgentSkills`): **kelp-extensions** (this repo's docs/extensions.md: where an extension
goes, its format, how to reload) and **kelp-settings** (every setting key, generated from the registry, and how to
change it). The daemon loads that folder per Claude session with `--plugin-dir`; turning a skill off in
Settings › Agents removes it. Nothing is written to the agent's own config. The app reloads extensions when their
files change.

## UI ↔ daemon
The app talks to the daemon only through JSON-RPC. IDE actions requested by agents go
`kelp` → daemon `ui.*` → `event.ui` to the app. The app publishes what it shows with
`ui.publish` so agents can ask (`ui.state`).
What it restores that names the daemon's records — each workspace's layout (`layout/<id>`), the sidebar's order, pins
and folds, the last workspace — is in the daemon's database (`state.get` / `state.set`, the app's `UIState`), like Zed's
workspace DB: each `KELP_HOME` has its own, and removing a workspace removes its layout. Per-Mac view preferences
(panel sizes, inline diffs…) stay in UserDefaults.

The app doesn't ask the daemon again and again: it watches. Records come as they change — `event.session`,
`event.repo`, `event.worktree`, `event.removed` (every write of the store reports itself, `Store.changed`; a deleted
session too) — and the lists are read once, at connect. The client decodes each event once, on its reader thread, as
its type (`RPCClient.onEvent`); the main actor gets the value. Its writes are queued, so the main thread never waits on
the socket. A new connection hears no broadcast until its first request: it may be `kelp attach`'s byte stream.
What has no record of its own is a topic a view watches while it's on screen (`watch.start` / `watch.stop`, `WatchTopic`): a workspace's git (read when its files change, FSEvents in the daemon), its
ports, every session's CPU and memory, the branch's CI runs and pull request, an agent's context, the plan limits, a
file's version (its stamp only: `event.file`) and a workspace's file list (`event.files`). The
daemon reads a topic once for all its watchers, only while someone watches, and pushes it (`event.git`, `event.ports`…)
only when it changed; the app counts its watchers (`AppModel.watch`, `Watched`) and keeps what came in observed state
(`AppModel.git`, `.ports`…). Watching what's watched again (`watchAgain`) reads it now: after a commit or a push.
Clocks left in the app are its own (relative times, "still loading" hints, reconnecting) — ArchitectureTests lists them.
A project's files are the daemon's too: the Files panel's tree is the pushed list, and its moves, trashes, copies and
new files are `files.*` calls (a remote project's refused there, with why). What the app still reads or checks itself
(its own folders, a viewer's bytes, whether a path is there) ArchitectureTests lists with why.

Inside the app there is one way to learn that something changed, like Zed's observed entities: state — anything with
a current value (sessions, settings, text size, the editor theme, the tab on screen) — is `@Observable`, and AppKit code
follows the parts it reads with `track { value } changed: { … }` (once now, then after each change, on the next
run-loop turn; `owner:` ends it with a tab). Events that carry data and have no value to re-read (a clone's progress
line, a dev server's URL, an agent's status change as it happens) are direct calls when their one receiver is reachable,
else a `NotificationCenter` name.

## Concurrency and ordering (the daemon)
- **Parts.** `Daemon` is the connections, the method registry (`Daemon.methods`) and the services it puts together,
  each keeping its own state under its own locks and given what it uses at init (none names `Daemon`):
  `AgentUsage` (what agents leave on disk: conversations, token usage, context windows, plan limits), `Forges` (pull
  requests by branch, running clones, the trackers' clients and their keychain secrets), `Workspaces` (desks, the
  branches they follow, the `.kelp.yaml` files the user trusts), `Watches` (what clients watch, read through a hook the
  daemon sets), `Sessions` (which run, starting, waking, pausing and deleting them, their tmux, keeping the Mac awake).
  A method's handler is handed one service (`Handled.Service`: `handle(_ sessions: Sessions)`), never the daemon, so it
  reaches only what that service holds; each service's projection from the daemon is in one place (`DaemonService`).
  Its home (`Daemon(root:)`) is all the daemon takes from outside: its paths, which project folders are remote ones
  (`Remotes`) and how their ssh connections are shared come from it, never from the environment or a static
  (`theDaemonKeepsNoProcessGlobals`).
- **Threads.** Each connection has a reader thread. A request runs in a task of its own; one that blocks (git, gh, ssh,
  files) moves to a thread of its own through `offload`, so a slow host never holds Swift's cooperative pool; at most
  128 run at once, the rest wait their turn. A quick one (`Handled.quick`: `session.hook`, `session.report`,
  `state.get`…) takes no turn: it starts no program (`Subprocess.quickOnly` fails one that would). Store writes and the
  events they push go one at a time, in commit order. Accepting connections and the 2 Hz ticker (session ticks, keep-awake, pausing idle agents, restarting finished ones into a Claude Code update; settings.json is watched with FSEvents) have their own
  queues.
- **Ordering.** Replies to one connection can come back in any order, as in JSON-RPC and LSP; clients match them by id.
  What is only right in the order it was sent says so on its type (`Answered.inOrder`: keystrokes `session.write`,
  `session.resize`, `state.set`, `ui.publish`, `settings.set`, `session.send`, `watch.start`, `lsp.change`…; the list is
  pinned by `theInOrderMethodsAreTheKnownOnes`) and runs on the reader thread, one after another, call or notification; a
  call's reply goes out in that order. A method is one of three by its type: in order, quick or blocking, never two. A session's status changes run in order on its
  own queue (`LiveSession.inOrder`). `session.stream`, the one method the reader knows by name, turns its connection into
  a raw byte pipe; `session.attach` of a live session answers itself, its history queued under the session's lock, so no
  live output gets ahead of it. Every method is in one registry (`Daemon.methods`); a result is encoded once, straight
  into its reply, and the client decodes it as its type from the reply's bytes. Events (`event.*`) are typed too
  (`RPCEvent` in Core), one encode each; a connection that asked for none (`client.events`, `kelp attach`'s control
  connection) gets no broadcasts.
- **Writes to a client** leave in order from that connection's own queue. A client whose writes make no progress for
  30 s is hung up on, and so is one more than 256 MiB behind.
- **Locks**, outermost first: a session's wake lock (`Sessions.wakeLocks`; several are taken in id order) → `Sessions.live` →
  `Clients` → a session's own lock → a `Connection`'s. A session's lock is never held while another session's is taken.
  Everything about a session that changes is one struct (`LiveSession.State`) under that lock, touched only inside
  `withLock`, so the compiler checks it; what it tells the daemon (`LiveSession.Callbacks`) is fixed at launch.
  `Workspaces.deskLock` makes listing desks and adding a missing one a single step (taken once, never again inside),
  and its `trustLock` guards trusted-configs.json.
- **Deadlines.** Every git, gh and ssh run has a time limit (300 s by default) and is stopped with its children
  (`Subprocess`). A call waits for its reply as long as its method says (`RPCMethod.timeout`: 330 s, just past that;
  `repo.clone` waits for good, its Cancel stops it), so a reply that never comes fails the call instead of hanging it.
  Language-server requests time out.
- **Checked by** DaemonTests, which run against a real daemon with real PTYs and git, also under Thread Sanitizer in CI.

## Updates
An update replaces the app bundle while kelpd keeps running the old binary. The relaunched app sees that
(`daemon.info`'s `binaryMTime`) and calls `daemon.upgrade`: kelpd stops serving, saves each running session's record,
and runs the new kelpd at the same path in the same process (`posix_spawn` with `POSIX_SPAWN_SETEXEC`). The new kelpd gets
the listening socket, the home's lock and each session's terminal fd (`Handover`, `kelpd --adopt`). The agents stay this
process's children and keep working, and their output waits in the terminal for the few hundred milliseconds this takes.
Connections drop; the app reconnects and its terminals attach again, the history read back from each session's log. The
new kelpd also reaps the old run's other programs (a git still running) once they end. Restart Background Service works
the same way, with the same binary. A kelpd from before `daemon.upgrade` existed is restarted instead, which ends the
sessions; the app asks first when any are running.

## When the daemon misbehaves
- **Its log:** `log stream --predicate 'subsystem == "dev.kelp.daemon"'` (or Console.app). It logs what would otherwise
  fail without a trace: startup, store writes that fail (a full disk), failed requests (debug level), refused
  "only Kelp's window" calls with the program that asked, sessions that didn't start. Never terminal output, prompts,
  tokens or file contents.
- **Why it didn't start:** `<KELP_HOME>/kelpd.err` holds the reason (the lock held by another kelpd, a socket path over
  104 bytes, a database it can't open); the app's "background service isn't running" banner shows it, with the fix
  when one is known. The next daemon that starts removes it.

## What Kelp trusts (threat model)
**Trusted: the user and every process running as the user.** The daemon's socket is the user's own (0600 in a 0700
folder, the peer's uid checked); anything that reaches it — the app, the `kelp` CLI, an agent with `KELP_SOCKET`, a
script — can do what the user can: start a session with any command, read terminals, write files. That is by design:
agents run as the user and can run commands anyway. Kelp doesn't try to contain a hostile process of the same user
(it could edit `~/.kelp`, drive the app with synthetic events, or skip Kelp entirely).

What only Kelp's window may do — publish what's on screen (`ui.publish`), trust a project's commands (`scripts.trust`) or
its language servers (`state.set` of `lsp.*`) — each method says itself (`Answered.onlyFromKelp`), and the dispatcher
checks it for every call, by the program at the other end of the socket. A status report (hooks, `kelp report`, herdr's)
from a program running inside a session is for that session only (`Answered.reportsFor`), so one agent can't mark another
done or asking. Every other method is open to any client.

**Not trusted: what came from someone else** — a cloned repository's files and branches, a pull request, an issue or
review comment, a project's `.kelp.yaml`. Kelp keeps that from acting as the user:
- `.kelp.yaml` runs nothing (setup, tabs, shared links, recipes, issueCommand) until the user trusts that exact text,
  shown in Kelp's window; only the KelpApp next to the daemon may grant it (`scripts.trust`, checked by the connecting
  program), so a repository's script or an agent's casual call can't.
- What a project's other files offer to run (package.json scripts, Makefile targets, compose services… `run.detect`)
  runs only when the user picks it in the run list or presses ⌘R after picking it once, with the command shown; opening
  a project runs nothing. `run.start` takes an option's id and runs the command as the file says it now.
- An agent's "trust this folder?" is answered for the user only where the agent already trusts the project and the
  branch doesn't change agent config (`.claude`, `.mcp.json`, …); a launch prompt never answers it or any startup menu.
- Issue, review and CI-log text is typed into the agent, not sent: the user reads it before the agent acts on it.
  Text typed for anyone is stripped of escape sequences and control keys (`LiveSession.typeable`).
- Text sent to a session goes through one gate (`LiveSession.submit`): it waits while the agent is starting, while a
  question or numbered menu is on screen (its Enter would pick the default), and behind an unread draft (its Enter would
  submit the draft). An auto-answer is pressed only if its question is still on screen and nobody typed meanwhile.
- Values go into shell commands as variables, never as command text (`ShellTemplate`); refs from clients that read as
  options are refused; paths go to git as literal pathspecs after `--`.
- The background usage probe only opens folders whose agent config matches the base branch (or has none), and never
  presses anything while its copy of the agent asks a question.
- Language servers run a project's own code (build scripts, `Package.swift`, its `node_modules`' TypeScript), and
  formatters can (rustup takes the toolchain a repo names): neither runs in a project until the user trusts it in
  Kelp's window (a banner on its first file, like VS Code's Workspace Trust), the scratch desk included. Only the window
  can record that trust (`state.set` of `lsp.*` checks the connecting program, as `scripts.trust` does). Language
  servers run in the daemon (`lsp.*`: one per project and server command, shared by every client, stopped a minute after
  its last file closes), which checks that trust itself before it starts one, whoever asks.
- Links clicked in a Markdown, notebook or PDF preview, or ⌘-clicked in a terminal, open web pages, plain files (as tabs) and
  mail only: a link to an app the repo ships (files from `git clone` carry no quarantine), a `.command` file or another
  app's scheme is refused. ⌥⌘ on a path a program printed
  shows it in the Finder rather than opening it with its app.
- A program in a terminal can put text on the clipboard (OSC 52 writes: Claude Code copies that way over ssh), but that
  text can't run on the user's next ⌘V into a Kelp terminal that takes no bracketed pastes: such a paste is refused with a
  banner while the clipboard still holds the program's text. Pastes into other apps aren't guarded. OSC 52 reads and
  Kitty clipboard writes are refused; replayed history drops old OSC 52 copies. The user's own copy is unaffected.
- An extension's `open` action (and `kelp.open` in its page) can't turn data (an issue's fields) into a `terminal:` or
  `agent:` URI; only the extension's own template can name those, and values go into one as into its other actions: a
  command's as shell variables, an agent's prompt typed for the user to send, never into a tmux session's name.
- A repository's own git config (a folder that came as a download carries one) runs nothing on what Kelp runs by
  itself: no fsmonitor, no external diff or textconv in diffs, and its own `filter.*` drivers are off for reads (status,
  diff, log…). What the user does (add, commit, checkout, fetch) runs git as a terminal would, hooks and filters included.
- A remote project's marker counts only under `~/.kelp/remote`; gh/glab don't run for remote projects.

Tests run with their own `KELP_HOME`, agent config dirs, keychain service and git config, set as the test bundle
loads (`Tests/TestSupportC`), so no test reads or writes the user's own. Their sessions start through `kelp __ctty`
as under kelpd, so a test process that crashes or is killed takes its programs with it.
