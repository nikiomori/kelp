# Review rubric

A review scores Kelp against this list, not against an impression: every reviewer checks the same items, so a score
moves when an item does and stays when nothing changed. Each dimension has ten items; an item is met (1), half met
(0.5) or not (0), and the dimension's score is their sum. A reviewer reports each item with its evidence (a file and
line, or a number from `scripts/metrics.py`), may add findings outside the list (they don't change the score; they
are proposals for the list), and never scores from memory of an earlier review.

Run `scripts/metrics.py` first: the items marked **(m)** are read off its output.

## Architecture
1. The app reaches the daemon only through typed RPC: no string-named call, no raw `client.call` (ArchitectureTests).
2. Built-ins are modules the shell can't import, and no built-in imports another.
3. Daemon handlers are handed one service, never the daemon.
4. **(m)** The shell is thin: `shell_share` ≤ 0.45 (1), ≤ 0.55 (0.5).
5. Each feature lives in its built-in: Git sync and commit, CI and PR row marks, limits and usage, server cards, the
   run menu, the agent strip: none of them in KelpKit (1), at most two (0.5).
6. **(m)** Settings are typed: a key and its default are declared once and read by that declaration in the app and the
   daemon; `settings_key_literals` ≤ 10 (1), ≤ 40 (0.5). The settings window names no built-in's key.
7. **(m)** No god service: `sessions_extensions` ≤ 10 and no service answers more than 40 handlers
   (`sessions_handlers`, `workspaces_handlers`) (1); one of the two (0.5).
8. **(m)** AppModel is the daemon's mirror only: `appmodel_extension_files` ≤ 5 and no feature's behaviour on it (1);
   ≤ 9 (0.5).
9. One way to do each thing: no second path for an action (two ways to commit, to read a PR, to refresh after an
   action), checked across the shell and built-ins.
10. **(m)** The shell's surface for built-ins is small: `kelpkit_package` ≤ 250 (1), ≤ 300 (0.5); the ratchets that
    hold these numbers fail both ways (a count that falls lowers its ceiling).

## Maintainability
1. **(m)** Lines read at a glance: `lines_over_120` ≤ 500 (1), ≤ 2000 (0.5).
2. **(m)** Names say what they hold: `one_letter_names` ≤ 300 (1), ≤ 1500 (0.5).
3. **(m)** One statement a line: `joined_statement_lines` ≤ 200 (1), ≤ 1000 (0.5).
4. **(m)** Files are small: `files_over_400` ≤ 10 (1), ≤ 25 (0.5).
5. Comments and commit messages are plain English a newcomer reads without decoding (sample ten of each: nine or more
   plain (1), six or more (0.5)).
6. No comment contradicts its code (sample twenty: none (1), one (0.5)).
7. No dead code: no unused type, function or setting key (sample the shell and the daemon).
8. A typical change touches few files: adding a setting, a panel, an RPC method each take at most three files (1),
   five (0.5).
9. docs/architecture.md and docs/extensions.md describe the code as it is (sample ten claims).
10. **(m)** Changes land designed, not patched: `fix_commits_14d` under 35 % (1), under 50 % (0.5).

## Tests
1. Every module has tests, built-ins included (`builtins_without_tests` empty **(m)**).
2. **(m)** `flaky_listed` ≤ 3 (1), ≤ 8 (0.5); each listed with its reason.
3. **(m)** Waits are for events, not time: `sleeps_in_tests` ≤ 30 (1), ≤ 70 (0.5), and no "nothing happened" check after
   a fixed sleep (sample them).
4. A wait that runs out fails where it waited (one `waitFor`, no silent loops; `inline_wait_loops` ≤ 2 **(m)**).
5. Fixes come with a test that fails without them (sample the last ten `fix` commits).
6. The agent rules are one table test that a rule's removal fails (`whoMayDoWhat`).
7. **(m)** The VM runtimes are tested as state machines: `kelpvm_tests_per_kloc` ≥ 10 (1), ≥ 5 (0.5).
8. CI runs the whole suite, release build and UI smoke on every push, TSan on the daemon.
9. ArchitectureTests' ratchets can fail: each counts what it claims (sample five against the code).
10. The suite passes on a quiet machine in one run, nothing retried.

## Security
1. The agent fence is an allowlist of methods; everything else is the user's.
2. Every session an agent's call names, in any field, is one it started.
3. Every workspace an acting call names is one the agent works in; a project it makes one in is its own.
4. An agent never answers a question: not by write, send, attach or comment, said or on screen.
5. The caller is found from the process, never from params; what can't be told is held to an agent's rules.
6. Untrusted text reaches an agent framed whole (comments, reports, issue text).
7. Repo config (`.kelp.yaml`), extensions and language servers run only once trusted.
8. URLs from pages open through one door; a link out of a project asks.
9. Settings an agent may set exclude the user's own (accounts, phone, keys, extensions, trust).
10. docs/architecture.md says plainly what the fence doesn't stop, and the code matches it.

## Data safety
1. Removing a workspace refuses unmerged or dirty work unless forced, and checks again after pausing its sessions.
2. Discard keeps an undo first and refuses if it can't.
3. File writes check the version they were shown (a stamp) and are atomic.
4. settings.json is written atomically, merges hand edits, keeps a last good copy, never overwrites one that won't parse.
5. Store migrations only add; a newer store isn't broken by an older daemon.
6. A hot upgrade can fall back when the new daemon can't start, and loses no reply in flight.
7. Undo of an agent's turn keeps what the user staged.
8. A check-then-write window is either closed or written down where it is.
9. Folders go to the Trash, not away.
10. Agents can't force, drop commits, push, discard or stash.

## Correctness
1. Agent status: a hook's word wins over the screen; a question read off the screen is marked as such.
2. Session lifecycle: start, pause, wake, restart, end each have a test of their transitions.
3. The VM runtimes' states are an enum with one place for transitions (no flags that mean two things).
4. Comment, report and send paths agree on who may type into a session.
5. Paths are compared as they really are (one helper: realpath, `..`, links), never by prefix of the raw string.
6. No state written after an `await` without looking again (sample the daemon and KelpVM).
7. Event handlers in the app react to the event that came, not to everything stored.
8. Every RPC method has a test that calls it (RPC coverage).
9. Time-based behaviour (pause, sleep, idle) is tested with a clock that can be moved, not by waiting.
10. No known bug left open in the last review's findings.

## Error handling
1. One error path in the app (`call`, `tryCall`, `quiet`); no `try?` around a call.
2. **(m)** `try_question` ≤ 250 (1), ≤ 350 (0.5), each a probe, not a write.
3. A refusal says why and what to do instead.
4. Failures are never answered as success (a resume that failed, a sleep that didn't save).
5. Every call has a deadline that fits the work behind it.
6. A store error doesn't end a user's typing or attach.
7. Background failures are logged with what failed.
8. A put-back after a failure doesn't hide the first error.
9. The daemon never blocks the cooperative pool (git, gh, ssh through `offload`).
10. A failed hot upgrade or exec leaves the old daemon running.

## Concurrency
1. `@unchecked Sendable` types document their lock; their count doesn't grow.
2. Session input is applied in order (lanes), checked again after a wake.
3. Locks are taken in one order; none is held across a program run.
4. No TOCTOU between a check and the write it guards (sample).
5. Main-thread code does no file or process work.
6. Two concurrent RPCs for the same thing don't double its effect (sends, creates).
7. Timers and observers have owners and end with them.
8. TSan is clean on the daemon suite.
9. Async VM state is touched on one actor only.
10. Watches coalesce; no event storm re-renders everything.

## Reliability
1. A daemon restart or hot upgrade keeps agents running.
2. A VM never leaves an emulator, simulator or VM process behind (SIGTERM, failed boot, sleep).
3. A wedged child is killed after a grace period.
4. Reconnects resume watches and streams.
5. Leaked processes and fds are tested for (PTY, LSP, usage probes).
6. Idle and pause logic counts real use (commands through adb, simctl, ssh).
7. A failed step leaves the machine in a state the next request can recover from.
8. Disk-full and permission errors are reported, not crashed on.
9. The memory budget never sleeps a machine in use.
10. Hand-over between daemons loses no session.

## Performance
1. Nothing polls the daemon from the app (clocks listed in ArchitectureTests).
2. Hot lookups are indexed (sessions by id).
3. No O(n²) on per-event paths (sample the sidebar and AppModel).
4. Process spawns in loops are bounded and off the main thread.
5. Watches back off with jitter.
6. Large files are read in the background (tree-sitter, diffs).
7. The ticker does nothing when there's nothing to do.
8. Memory doesn't grow with history (ring buffers, pruned records).
9. Agent rule checks don't scan all sessions per call.
10. Launch and workspace switch times are measured and held.
