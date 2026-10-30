# Releasing

## Channels

| | Kelp | Kelp Nightly | Kelp Dev |
| --- | --- | --- | --- |
| What | a release, `vX.Y.Z` | main's newest commit that passed CI, once a day | your working tree |
| Built by | `make release` + `make publish` | CI (`.github/workflows/nightly.yml`), or `make nightly` + `make publish-nightly` | `make dev` |
| Download | [releases/latest](https://github.com/nikiomori/kelp/releases/latest) | [releases/tag/nightly](https://github.com/nikiomori/kelp/releases/tag/nightly) | — |
| Updates | Sparkle, `releases/latest/download/appcast.xml` | Sparkle, daily, `releases/download/nightly/appcast.xml` | `make dev` |
| App id · home | `dev.kelp.app` · `~/.kelp` | `dev.kelp.app.nightly` · `~/.kelp-nightly` | `dev.kelp.app.dev` · `~/.kelp-dev` |

The three install side by side and never share a daemon, settings, projects or agents: each is an app of its own (id,
name, Login Items entry, home; `scripts/bundle.sh <channel>`). Nightly and Dev wear the blueprint icon. `kelp://` links
open Kelp. `scripts/dev-home.sh [nightly]` copies Kelp's projects, workspaces and sessions into Dev's (or Nightly's) home.

## Branches

`main` is where work lands (pull requests go there) and what Kelp Nightly is built from. A release is a tag on main,
`vX.Y.Z`. A fix that can't wait for the next release goes to main first, then to a `release/X.Y` branch cut from the
tag, released as the next patch. The `nightly` tag moves to each nightly's commit; don't build on it.

## Versions

Kelp: `CFBundleShortVersionString` (semver) and `CFBundleVersion` (1, 2, 3…; Sparkle compares it) in
`Resources/Info.plist`, bumped before each release. Kelp Nightly: the next minor version and the day, `0.8.0-nightly.20261030`,
numbered by main's commit count.

## A release

1. main's CI is green.
2. Bump both versions in `Resources/Info.plist`, commit.
3. `make release` (signed + notarized with `local.mk`'s `SIGN_ID` and `NOTARY_PROFILE`), then `make publish`: tag, GitHub
   release, update feed. Build in a clean worktree at the commit, so no uncommitted work ships.

## Kelp Nightly: setup, once

The nightly job reads its secrets from the repository's `nightly` environment, which only main can use. Until all six are
there it says which are missing and stops.

```sh
R=nikiomori/kelp
# The environment, for main only.
gh api -X PUT repos/$R/environments/nightly --input - <<< '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}'
gh api -X POST repos/$R/environments/nightly/deployment-branch-policies -f name=main -f type=branch

# Its own update key: the stable one never leaves this Mac. The public half is committed, the private half is CI's.
B=.build/artifacts/sparkle/Sparkle/bin
$B/generate_keys --account kelp-nightly                 # makes it, in the login keychain
$B/generate_keys --account kelp-nightly -p > Resources/NightlyUpdateKey.pub
$B/generate_keys --account kelp-nightly -x "$TMPDIR/n" && gh secret set SPARKLE_NIGHTLY_KEY --env nightly < "$TMPDIR/n"; rm -P "$TMPDIR/n"

# The Developer ID certificate: Keychain Access › My Certificates › "Developer ID Application: …" › Export… (.p12, a password).
base64 -i Certificates.p12 | gh secret set DEVELOPER_ID_P12 --env nightly; rm -P Certificates.p12
gh secret set DEVELOPER_ID_P12_PASSWORD --env nightly       # asks for it

# A notarization key: App Store Connect › Users and Access › Integrations › Team Keys › + (Developer). Download the .p8.
base64 -i AuthKey_XXXXXXXXXX.p8 | gh secret set NOTARY_KEY --env nightly
gh secret set NOTARY_KEY_ID --env nightly --body XXXXXXXXXX
gh secret set NOTARY_ISSUER --env nightly --body <Issuer ID from that page>
```

Then commit `Resources/NightlyUpdateKey.pub`, and run the workflow once by hand: `gh workflow run nightly.yml -f force=true`.
