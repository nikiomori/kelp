# Releasing

## Channels

| | Kelp | Kelp Beta | Kelp Dev |
| --- | --- | --- | --- |
| What | a release, `vX.Y.Z` | a build of main, to try ahead of a release | your working tree |
| Made by | `make release` + `make publish` | `make beta` + `make publish-beta` | `make dev` |
| Download | [releases/latest](https://github.com/nikiomori/kelp/releases/latest) | [releases/tag/beta](https://github.com/nikiomori/kelp/releases/tag/beta) | — |
| Updates | Sparkle, `releases/latest/download/appcast.xml` | Sparkle, `releases/download/beta/appcast.xml` | `make dev` again |
| App id · home | `dev.kelp.app` · `~/.kelp` | `dev.kelp.app.beta` · `~/.kelp-beta` | `dev.kelp.app.dev` · `~/.kelp-dev` |

The three install side by side and never share a daemon, settings, projects or agents: each is an app of its own (id,
name, Login Items entry, home; `scripts/bundle.sh <channel>`). Beta and Dev wear the blueprint icon. `kelp://` links
open Kelp. `scripts/dev-home.sh [beta]` copies Kelp's projects, workspaces and sessions into Dev's (or Beta's) home.

A beta is a GitHub pre-release under the tag `beta`, made again each time: GitHub's "latest" release, whose feed Kelp
reads, never points at it, so Kelp's users never get a beta.

## Branches

`main` is where work lands (pull requests go there); betas are built from it. A release is a tag on main, `vX.Y.Z`. A
fix that can't wait for the next release goes to main first, then to a `release/X.Y` branch cut from the tag, released
as the next patch. The tag `beta` moves to each beta's commit; don't build on it.

## Versions

Kelp: `CFBundleShortVersionString` (semver) and `CFBundleVersion` (1, 2, 3…; Sparkle compares it) in
`Resources/Info.plist`, bumped before each release. Kelp Beta: the next minor version and the day, `0.8.0-beta.20261030`,
numbered by main's commit count.

## A release

1. main's CI is green.
2. Bump both versions in `Resources/Info.plist`, commit, push.
3. `make release` (signed and notarized with `local.mk`'s `SIGN_ID` and `NOTARY_PROFILE`), then `make publish`: tag,
   GitHub release, update feed. Build in a clean worktree at the commit, so nothing uncommitted ships.

## A beta

1. Commit and push what it should have (`make beta` refuses uncommitted changes in Sources or Resources, `make
   publish-beta` a commit GitHub doesn't have).
2. `make beta` (signed and notarized as a release is), then `make publish-beta`: the `beta` pre-release with the commits
   since the last one, and its update feed.

## Keys

Two signatures make a download open and update:

- **Developer ID** (Keychain Access, login keychain): macOS opens only apps signed by a registered developer and checked
  by Apple (notarization). Kelp, Kelp Beta and the DMGs are signed with it on this Mac; it never leaves it.
- **Update keys** (login keychain, Sparkle's accounts `kelp` and `kelp-beta`): an update installs only if it's signed
  with the key whose public half the app carries (`SUPublicEDKey` in `Resources/Info.plist`,
  `Resources/BetaUpdateKey.pub`). Lose one and that channel's users can't update any more: keep a copy in a password
  manager. `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account kelp-beta -x <file>` writes it to a file (as
  text), `-f <file>` puts it back.
