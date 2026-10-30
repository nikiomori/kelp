#!/bin/zsh
# Publish dist/beta/Kelp-Beta.dmg (`make beta`: signed + notarized) as the `beta` pre-release in place of the last one,
# with the update feed Kelp Beta reads (SUFeedURL: releases/download/beta/appcast.xml). One command:  make publish-beta
# A pre-release is never GitHub's "latest", whose feed Kelp itself reads: Kelp's users never get a beta.
# Signed with the beta update key, in the login keychain (generate_keys --account kelp-beta); keep a backup of it:
# .build/artifacts/sparkle/Sparkle/bin/generate_keys --account kelp-beta -x <file>
set -euo pipefail
cd "$(dirname "$0")/.."
URL=https://github.com/nikiomori/kelp; D=dist/beta; DMG=$D/Kelp-Beta.dmg
key() { plutil -extract "$1" raw "$D/Kelp Beta.app/Contents/Info.plist"; }
V=$(key CFBundleShortVersionString); C=$(key KelpCommit)
git fetch -q origin main
git merge-base --is-ancestor "$C" origin/main || { echo "${C:0:7} isn't on GitHub's main yet: git push first"; exit 1; }
spctl -a -t open --context context:primary-signature "$DMG"   # notarized, or Gatekeeper blocks it
SIG=$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account kelp-beta "$DMG")   # sparkle:edSignature="…" length="…"
cat > $D/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Kelp Beta</title>
    <item>
      <title>$V</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$(key CFBundleVersion)</sparkle:version>
      <sparkle:shortVersionString>$V</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(key LSMinimumSystemVersion)</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$URL/releases/tag/beta</sparkle:fullReleaseNotesLink>
      <enclosure url="$URL/releases/download/beta/Kelp-Beta.dmg" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
EOF
# What's new since the last beta: main's commits, each subject cut to a line.
git fetch -q --force origin 'refs/tags/beta:refs/tags/beta' 2>/dev/null || true
LAST=$(git rev-parse -q --verify 'refs/tags/beta^{commit}' || true)
NOTES=$(git log -n 60 --no-merges --format=$'%s\t%h' ${LAST:+$LAST..}$C | while IFS=$'\t' read -r s h; do
  (( ${#s} <= 110 )) || s="${s[1,109]}…"; print -r -- "- $s ($h)"; done)
# The tag `beta` moves to the commit built; the release is made again on it (its download URLs stay the same).
gh release delete beta --yes 2>/dev/null || true
git tag -f beta "$C" && git push -qf origin refs/tags/beta
gh release create beta "$DMG#Kelp Beta $V for macOS (download this)" "$D/appcast.xml#Update feed (read by the app, not a download)" \
  --verify-tag --prerelease --latest=false --title "Kelp Beta $V" --notes "$(cat <<EOF
What's coming in Kelp, ahead of a release: **[Kelp-Beta.dmg]($URL/releases/download/beta/Kelp-Beta.dmg)** (macOS 14+).
Kelp Beta installs beside Kelp, as an app of its own (its settings, projects and agents in ~/.kelp-beta), and updates
itself with each new beta. It can break: for work, use [Kelp]($URL/releases/latest).

${NOTES:-No changes since the last beta.}
EOF
)"
echo "published Kelp Beta $V"
