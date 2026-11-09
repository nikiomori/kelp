#!/bin/zsh
# Publish dist/Kelp.dmg (`make release`: signed + notarized) as GitHub release v<version>, with the Sparkle appcast
# the app reads (SUFeedURL: the latest release's appcast.xml). One command:  make publish
# First bump CFBundleShortVersionString and CFBundleVersion in Resources/Info.plist: Sparkle compares CFBundleVersion.
# The update key is in the login keychain (generate_keys --account kelp); without it no update installs, so keep a
# backup: .build/artifacts/sparkle/Sparkle/bin/generate_keys --account kelp -x <file>
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=https://github.com/nikiomori/kelp
key() { plutil -extract "$1" raw Resources/Info.plist; }
V=$(key CFBundleShortVersionString)
spctl -a -t open --context context:primary-signature dist/Kelp.dmg   # notarized, or Gatekeeper blocks it
SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account kelp dist/Kelp.dmg)   # sparkle:edSignature="…" length="…"
scripts/appcast.sh Kelp Resources/Info.plist "$REPO/releases/tag/v$V" "$REPO/releases/download/v$V/Kelp.dmg" "$SIG" > dist/appcast.xml
git tag "v$V" && git push -q origin "v$V"   # the commit the DMG was built from
# Labels on the page (the URLs keep the file names): appcast.xml sorts first, and people took it for the app.
gh release create "v$V" "dist/Kelp.dmg#Kelp $V for macOS (download this)" "dist/appcast.xml#Update feed (read by the app, not a download)" \
  --verify-tag --title "Kelp $V" --notes "**Download: [Kelp.dmg]($REPO/releases/download/v$V/Kelp.dmg)** (macOS 14+)." --generate-notes
# The Homebrew cask (nikiomori/homebrew-tap, `brew install --cask nikiomori/tap/kelp`) points at this release.
CASK=repos/nikiomori/homebrew-tap/contents/Casks/kelp.rb
SUM=$(shasum -a 256 dist/Kelp.dmg | cut -d' ' -f1)
gh api "$CASK" --jq .content | base64 -d \
  | sed -E "s/^  version \".*\"/  version \"$V\"/; s/^  sha256 \".*\"/  sha256 \"$SUM\"/" > dist/kelp.rb
gh api -X PUT "$CASK" -f message="kelp $V" -f content="$(base64 < dist/kelp.rb)" -f sha="$(gh api "$CASK" --jq .sha)" > /dev/null
