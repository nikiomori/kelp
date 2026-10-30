#!/bin/zsh
# Publish dist/nightly/Kelp-Nightly.dmg (`scripts/bundle.sh nightly`: signed + notarized) as the `nightly` pre-release in
# place of the last one, with the update feed Kelp Nightly reads (SUFeedURL: releases/download/nightly/appcast.xml).
# A pre-release is never GitHub's "latest", whose feed Kelp itself reads: stable users never get a nightly.
# CI runs it daily (.github/workflows/nightly.yml); by hand:  make publish-nightly
# Signed with the nightly update key: SPARKLE_KEY_FILE (CI's secret) or the login keychain's account kelp-nightly.
set -euo pipefail
cd "$(dirname "$0")/.."
URL=https://github.com/nikiomori/kelp; D=dist/nightly; DMG=$D/Kelp-Nightly.dmg
key() { plutil -extract "$1" raw "$D/Kelp Nightly.app/Contents/Info.plist"; }
V=$(key CFBundleShortVersionString); C=$(key KelpCommit)
spctl -a -t open --context context:primary-signature "$DMG"   # notarized, or Gatekeeper blocks it
if [ -n "${SPARKLE_KEY_FILE:-}" ]; then KEY=(--ed-key-file "$SPARKLE_KEY_FILE"); else KEY=(--account kelp-nightly); fi
SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update "${KEY[@]}" "$DMG")   # sparkle:edSignature="…" length="…"
cat > $D/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Kelp Nightly</title>
    <item>
      <title>$V</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$(key CFBundleVersion)</sparkle:version>
      <sparkle:shortVersionString>$V</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(key LSMinimumSystemVersion)</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$URL/releases/tag/nightly</sparkle:fullReleaseNotesLink>
      <enclosure url="$URL/releases/download/nightly/Kelp-Nightly.dmg" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
EOF
# What's new since the last nightly: main's commits, each subject cut to a line.
git fetch -q --force origin 'refs/tags/nightly:refs/tags/nightly' 2>/dev/null || true
LAST=$(git rev-parse -q --verify 'refs/tags/nightly^{commit}' || true)
NOTES=$(git log -n 60 --no-merges --format=$'%s\t%h' ${LAST:+$LAST..}$C | while IFS=$'\t' read -r s h; do
  (( ${#s} <= 110 )) || s="${s[1,109]}…"; print -r -- "- $s ($h)"; done)
# The rolling tag moves to the commit built; the release is made again on it (its download URLs stay the same).
gh release delete nightly --yes 2>/dev/null || true
git tag -f nightly "$C" && git push -qf origin refs/tags/nightly
gh release create nightly "$DMG#Kelp Nightly $V for macOS (download this)" "$D/appcast.xml#Update feed (read by the app, not a download)" \
  --verify-tag --prerelease --latest=false --title "Kelp Nightly $V" --notes "$(cat <<EOF
Main's build of $(date -u +%Y-%m-%d): **[Kelp-Nightly.dmg]($URL/releases/download/nightly/Kelp-Nightly.dmg)** (macOS 14+).
Kelp Nightly installs beside Kelp, as an app of its own (its settings, projects and agents in ~/.kelp-nightly), and
updates itself every day. It can break: for work, use [Kelp]($URL/releases/latest).

${NOTES:-No changes since the last nightly.}
EOF
)"
echo "published Kelp Nightly $V"
