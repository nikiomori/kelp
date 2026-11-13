# Kelp next to Orca, Herdr, cmux, Paradev and Zed

Kelp's author wrote this page. It tries to be fair, and it will go out of date, because all six apps ship every week.
Each fact carries the date it was read and a link to where it was read. If something here is wrong or old, open an
issue or a pull request.

The facts come from each project's README, docs, source code and issue tracker, read between 2 and 5 November 2026.
None of the other apps was run for this page, except for the weight table, which comes from
[Kelp's README](../README.md#how-light-it-is). Star counts are GitHub's on 5 November 2026.

## The short version

- **Kelp** is for one person on a Mac who runs a few CLI agents and still reads the code they write. It is native
  (Swift, AppKit, libghostty), has an editor with language servers, a diff where you stage hunks and comment on lines,
  and can have a second agent review the first. It runs on macOS only.
- **Orca** has the most features of the group, runs on macOS, Windows and Linux, and has a phone app. It is built on
  Electron, and its editor has no language server.
- **Herdr** is a terminal runtime for agents. It runs on Linux, macOS and Windows, keeps several SSH machines in one
  window, uses very little memory, and has the largest plugin ecosystem. Reading and reviewing code comes from plugins.
- **cmux** is a native macOS terminal built on Ghostty, with vertical tabs, notification rings and a browser that agents
  can script. It is a terminal first. It has no code editor.
- **Paradev** is an Electron app with a worktree per task, a pull request pane with review threads, and an iPhone app
  and remote hosts on its paid plan.
- **Zed** is a full code editor for macOS, Linux and Windows. Agents that speak ACP get its review tools. A CLI agent in
  a terminal gets a sidebar entry and bell notifications.

## At a glance

| | Kelp | Orca | Herdr | cmux | Paradev | Zed |
| --- | --- | --- | --- | --- | --- | --- |
| Built with | Swift, AppKit, libghostty | Electron [^weight] | Rust; the app on GPUI [^herdr-files] | Swift, AppKit, libghostty [^cmux-readme] | Electron [^paradev-readme] | Rust |
| Runs on | macOS 14+ | macOS, Windows, Linux [^orca-readme] | Linux, macOS, Windows [^herdr-readme] | macOS [^cmux-readme] | macOS; Linux as an experimental AppImage [^paradev-readme] | macOS, Linux, Windows [^zed-readme] |
| License | MIT | MIT [^orca-readme] | Apache-2.0 [^herdr-readme] | GPL-3.0-or-later [^cmux-license] | MIT [^paradev-license] | GPL-3.0-or-later, some parts Apache-2.0 [^zed-readme] |
| Usage telemetry | none | anonymous, can be turned off [^orca-readme] | on by default in the app's releases, can be turned off [^herdr-app] | not checked | not checked | not checked |
| Sign-in | none | not checked | not checked | not checked | asks for one; a request to drop it is open [^paradev-4894] | not checked |
| Editor with language servers | yes | no [^orca-961] | no; file previews are read-only [^herdr-files] | no | not checked | yes |
| Stage or discard a hunk | yes | not checked | no, in the built-in Changes view [^herdr-changes] | no diff view in the public release [^cmux-next] | not checked | yes, keep or reject an agent's hunks (ACP agents) [^zed-panel] |
| Comment on a diff line, sent to the agent | yes | yes [^orca-readme] | through a plugin (see below) | not in the public release [^cmux-next] | yes [^paradev-readme] | yes, Send Review to Agent [^zed-review] |
| A second agent reviews the first | yes, **Review with** in the diff header [^review-with] | not checked | not checked | not checked | not checked | not checked |
| Pull request with review threads in the app | no: create, CI, merge; threads are read and sent to an agent, not answered | not checked | not checked | not checked | yes [^paradev-readme] | not checked |
| Phone | a web page Kelp serves itself, over Tailscale or your own address (docs/phone.md); `kelp agents` over SSH | iOS and Android apps [^orca-readme] | community apps [^herdr-phone] | not checked | iPhone and iPad, paid plan [^paradev-readme] | not checked |
| Other machines | Open over SSH, branches in worktrees there, tmux on the host | SSH worktrees [^orca-readme] | several SSH machines in one window [^herdr-readme] | `cmux ssh` [^cmux-readme] | remote hosts, paid plan [^paradev-readme] | remote projects [^zed-terminal] |
| GitHub stars | 4 | 115,847 | 48,170 (app: 1,995) | 28,705 | 15,944 | 92,748 |

"Not checked" means this page doesn't know. It doesn't mean "no".

## Weight

From [Kelp's README](../README.md#how-light-it-is), measured on 5 November 2026 on an M4 Max with 48 GB on macOS 27.0.1.
Each app was opened three times with no agents running. Each number is the median of the three, or the range where they
differed widely.

| | Opens a window in | Memory (all its processes) | CPU when idle |
| --- | --- | --- | --- |
| Kelp 0.9.0 (app and background service) | 0.3 s | 81 MB | 0.8 % |
| Orca 1.4.229 (Electron) | 0.9 s | 1.2 GB | 4–19 % |
| Herdr 0.9.5 (in a terminal) | 0.3 s | 17 MB, plus the terminal it runs in | 0.1 % |

Herdr uses less than Kelp. Paradev, cmux and Zed were not measured, and neither was any app with four agents working.

## Herdr plus six plugins = Kelp out of the box

Herdr's plugin index lists 2,053 plugins [^herdr-index]. Sorted by hand into themes, the second most starred one is
reading code in the window: review, files, Source Control, an editor. These six plugins lead it. Kelp has most of what they add
built in. Two rows are only partly true, and they say so.

| Herdr plugin (stars, 5 Nov 2026) | What it adds to Herdr | Where it is in Kelp | Same? |
| --- | --- | --- | --- |
| [herdr-reviewr](https://github.com/persiyanov/herdr-reviewr) (968) | Review the agent's diff in a pane and send comments back to the agent | The diff tab (⇧⌘R): comment on a line, **Send to Agent**. **Review with** has another agent leave its findings there | Yes |
| [herdr-annotate](https://github.com/plannotator/herdr-annotate) (729) | Mark up terminal text, documents and agent replies, and send the notes to the agent | **Send Selection to Agent** in a terminal; **Send to Agent** on a file or its selected lines | Partly: no marks drawn on a document |
| [herdr-file-viewer](https://github.com/smarzban/herdr-file-viewer) (696) | A git-aware, read-only file tree and viewer | The Files panel and the editor, with git letters, and the files can be edited | Yes |
| [herdr-sidebar](https://github.com/alexarthurs/herdr-sidebar) (536) | A VS Code-style sidebar with a file explorer and Source Control | Files and Source Control in the right-hand panel; Source Control works as in VS Code, branch graph included | Yes |
| [herdr-nvim](https://github.com/ChmaraX/herdr-nvim) (329) | Neovim inside the Herdr workspace | Kelp's own editor: language servers, several cursors, VS Code's editing commands | Partly: Kelp's editor has no Vim mode. Neovim still runs in a Kelp terminal |
| [herdr-hunk-diff](https://github.com/jhochenbaum/herdr-hunk-diff) (148) | Review agent changes hunk by hunk and send inline comments to the agent that made them | Stage or discard a hunk in the diff; comments go to the agent that wrote the code, not to a reviewer | Yes |

Without plugins, Herdr's app has a Changes view of 209 lines of JavaScript that lists changed files and shows a file's
diff, with no staging and no comments [^herdr-changes], and a Files view with read-only previews [^herdr-files].

The plugins have something Kelp doesn't: they run wherever Herdr runs, including Linux and other machines over SSH.

## Where the others are ahead

**Orca**
- Runs on Windows and Linux, and has iOS and Android apps [^orca-readme].
- SSH worktrees with file editing, git, terminals and port forwarding on the remote box [^orca-readme].
- Releases come almost daily: v1.4.249 came out on 4 November 2026 [^orca-release].
- Its plugins have trust levels, and its catalog pins each plugin's files by SHA-256 [^orca-plugins].
- Multiple windows are one of its most asked-for features (53 reactions) [^orca-6074]. Kelp has one window.

**Herdr**
- Linux, macOS and Windows [^herdr-readme].
- Several SSH machines in one window, with one list of agents and reconnects of their own. Terminals keep running when
  the client closes or the SSH connection drops [^herdr-readme].
- Lighter than Kelp: 17 MB and 0.1 % CPU when idle, plus the terminal it runs in (table above).
- Far more extensions: 2,053 plugins in its index [^herdr-index] against Kelp's small library. Its community wrote phone
  clients: Ovis, Collie and Heeler have 1,880, 1,573 and 760 stars [^herdr-phone].

**cmux**
- Its browser has a scriptable API ported from agent-browser, and imports cookies and sessions from 20+ browsers
  [^cmux-readme].
- Notification rings on the pane itself, and a panel of all pending notifications [^cmux-readme].
- 28,705 stars: far more people use it and report its bugs.

**Paradev**
- A pull request pane with checks, review threads and merge [^paradev-readme]. Kelp reads a PR's review comments and
  hands them to an agent, but can't answer or resolve a thread, or submit a review.
- An iPhone and iPad app, remote hosts and automations, on its paid plan [^paradev-readme].
- Pages: an agent publishes a document, teammates comment, the agent revises it at the same link [^paradev-readme].

**Zed**
- A mature editor on three platforms, with collaboration [^zed-readme].
- Keep or reject an agent's edits hunk by hunk, also inside the file [^zed-panel].
- Agents through ACP live inside its agent panel [^zed-external].

## Where Kelp is ahead

- **The real CLI, with status and no setup.** Each agent runs as its own CLI in a terminal, with your config and plan.
  Claude Code reports through hooks that Kelp passes with `--settings`, so its config isn't touched. In Zed, a CLI agent
  in a Terminal Thread reports only through the terminal bell, and Claude Code, Amp and OpenCode each need a setting or
  a plugin for it [^zed-terminal]. cmux's status indicators have an open bug report about being unreliable
  [^cmux-1027].
- **Language servers on the agent's code**, in a native editor beside the agent. Orca's request for this has been open
  since April [^orca-961].
- **Reading the diff:** stage and discard hunks, hide whitespace, mark a file viewed, step through changes, comment on
  a line, and see what the agent's last turn changed.
- **A second opinion from another vendor:** **Review with** starts another agent (Codex reviewing Claude, say) on what
  the diff shows. Its findings land on their lines with its name. You tick the ones you agree with and send them to the
  agent that wrote the code [^review-with].
- **Agents outlive the app.** They run in a background service, so quitting or updating Kelp doesn't stop them, as long
  as Kelp stays allowed in Login Items.
- **No account, no cloud, no telemetry.** Paradev has an open request to drop its sign-in [^paradev-4894], and Herdr's
  app sends usage telemetry by default [^herdr-app].
- **Nothing hidden in your agents' setup.** Kelp writes nothing to `~/.claude` or `~/.codex`. For contrast, Paradev
  shipped a hook that blocked Claude's artifact tool on first use, with no setting to turn it off in the app
  [^paradev-8869].

## What Kelp doesn't do

Checked in Kelp's code on 5 November 2026:

- Linux or Windows.
- A phone app. From a phone, `kelp agents` over SSH shows the agents and answers permission requests.
- More than one window.
- One task across several repositories.
- Git blame in the editor.
- Answering or resolving a pull request's review threads, or submitting a review.
- A Vim mode in the editor.

**Review with** and picking findings are on `main` as of 5 November 2026. They are not in v0.9.0 or the 4 November beta.

[^weight]: [Kelp README, "How light it is"](../README.md#how-light-it-is), measured 2026-11-05.
[^herdr-app]: [herdr-app README](https://github.com/herdrdev/herdr-app#readme), read 2026-11-05: Linux, macOS and Windows builds; "Usage telemetry is on by default in releases. Turn it off in Settings → Privacy."
[^herdr-readme]: [herdr README](https://github.com/herdrdev/herdr#readme), read 2026-11-05: Windows install script, "several machines, one window", "detach without stopping work", Apache License 2.0.
[^herdr-index]: [Herdr plugin index](https://assets.herdr.dev/plugins/index.json), generated 2026-11-05: 2,053 plugins; star counts for the six plugins above.
[^herdr-phone]: [Ovis](https://github.com/devswha/ovis), [Collie](https://github.com/AltanS/collie) and [Heeler](https://github.com/ZingerLittleBee/Heeler), star counts from the [Herdr plugin index](https://assets.herdr.dev/plugins/index.json) generated 2026-11-05.
[^herdr-changes]: [herdr-app `defaults/mods/changes/main.js`](https://github.com/herdrdev/herdr-app/blob/e77f112ac2ea136b84fe510efa42d41163bfd776/defaults/mods/changes/main.js) at commit e77f112a, 2026-11-04: 209 lines; runs `git status` and `git diff`, no staging or comments.
[^herdr-files]: [herdr-app `defaults/mods/files/main.js`](https://github.com/herdrdev/herdr-app/blob/e77f112ac2ea136b84fe510efa42d41163bfd776/defaults/mods/files/main.js) at commit e77f112a, 2026-11-04: "A lazy file browser … with bounded read-only previews".
[^orca-readme]: [Orca README](https://github.com/stablyai/orca#readme), read 2026-11-05: macOS, Windows and Linux; iOS and Android companion; SSH worktrees; comments on diff lines sent to the agent; [telemetry docs](https://www.onorca.dev/docs/telemetry) with how to opt out; MIT License.
[^orca-961]: [orca#961](https://github.com/stablyai/orca/issues/961), "Have LSP support", opened 2026-04-23, open on 2026-11-05 with 43 reactions. Related: [orca#7754](https://github.com/stablyai/orca/issues/7754), "Embedded VSCode editor", open, 48 reactions.
[^orca-6074]: [orca#6074](https://github.com/stablyai/orca/issues/6074), "Multiple windows", opened 2026-06-22, open on 2026-11-05.
[^orca-release]: [Orca releases](https://github.com/stablyai/orca/releases), v1.4.249 published 2026-11-04.
[^orca-plugins]: Orca's plugin reference in [`docs/reference`](https://github.com/stablyai/orca/tree/main/docs/reference) (`plugin-*.md`), read 2026-11-02: four execution levels, catalog with commit and SHA-256 content hash.
[^cmux-readme]: [cmux README](https://github.com/manaflow-ai/cmux#readme), read 2026-11-05: "Built with Swift and AppKit", libghostty, macOS download, notification rings and panel, in-app browser with an API ported from agent-browser, browser import, `cmux ssh`.
[^cmux-license]: [cmux LICENSE](https://github.com/manaflow-ai/cmux/blob/main/LICENSE), read 2026-11-05: GPL-3.0-or-later; its server software is licensed separately.
[^cmux-next]: The public release has no diff view. Diff comments and a daemon rewrite are in progress on the `feat-cmux-next` branch of [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux), read 2026-11-02.
[^cmux-1027]: [cmux#1027](https://github.com/manaflow-ai/cmux/issues/1027), "Sidebar 'Running' and 'Needs Input' status indicators are flaky and unreliable", opened 2026-03-06, open on 2026-11-05 with 45 reactions.
[^paradev-readme]: [Paradev README](https://github.com/ParadevAI/Paradev#readme), read 2026-11-05: Electron; macOS, Linux as an experimental x64 AppImage, no Windows; Changes and pull request panes with checks, review threads and merge; selected diff lines sent to an agent; Pages; remote hosts, iPhone and iPad app and automations on the Pro plan.
[^paradev-license]: [Paradev LICENSE.md](https://github.com/ParadevAI/Paradev/blob/main/LICENSE.md), read 2026-11-05: MIT.
[^paradev-4894]: [Paradev#4894](https://github.com/ParadevAI/Paradev/issues/4894), "Drop the sign-in requirement; make it work offline, always, by default", opened 2026-05-23, open on 2026-11-05.
[^paradev-8869]: [Paradev#8869](https://github.com/ParadevAI/Paradev/issues/8869), opened 2026-10-25, open on 2026-11-05. The hook is `packages/agent-setup/templates/artifact-guard.template.sh`; the environment variable `SUPERSET_PAGES_NUDGE=0` turns it off.
[^zed-readme]: [Zed README](https://github.com/zed-industries/zed#readme), read 2026-11-05: macOS, Linux and Windows; "licensed primarily under GPL-3.0-or-later, with Apache-2.0 components where marked".
[^zed-terminal]: [Zed docs, Terminal Threads](https://github.com/zed-industries/zed/blob/main/docs/src/ai/terminal-threads.md), read 2026-11-05: Zed owns the sidebar entry; notifications come from the terminal bell; Claude Code needs `preferredNotifChannel: "terminal_bell"`, Amp needs `AMP_FORCE_BEL=1`, OpenCode needs a plugin.
[^zed-panel]: [Zed docs, Agent Panel](https://github.com/zed-industries/zed/blob/main/docs/src/ai/agent-panel.md), read 2026-11-05: accept or reject each hunk an agent changed, or all of them; `agent.single_file_review` shows the same in the file.
[^zed-review]: Zed's Git diff has **Send Review to Agent (N)** for comments left on hunks: `crates/git_ui/src/project_diff.rs` in [zed-industries/zed](https://github.com/zed-industries/zed), read 2026-11-02; a request for PR-style review, [zed#59157](https://github.com/zed-industries/zed/issues/59157), was open then.
[^zed-external]: [Zed docs, External Agents](https://github.com/zed-industries/zed/blob/main/docs/src/ai/external-agents.md), read 2026-11-05: Claude, Codex, OpenCode and others through the Agent Client Protocol.
[^review-with]: Kelp `Sources/Builtins/Git/DiffReviewWith.swift` and `DiffFindings.swift`, commits 69188e78 and af6057b4 on `main`, 2026-11-05.
