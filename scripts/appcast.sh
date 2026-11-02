#!/bin/zsh
# The Sparkle feed for one release, on stdout: appcast.sh <title> <Info.plist> <release page> <dmg url> <sign_update's output>
set -euo pipefail
TITLE=$1; PLIST=$2; PAGE=$3; DMG=$4; SIG=$5
key() { plutil -extract "$1" raw "$PLIST"; }
cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>$TITLE</title>
    <item>
      <title>$(key CFBundleShortVersionString)</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$(key CFBundleVersion)</sparkle:version>
      <sparkle:shortVersionString>$(key CFBundleShortVersionString)</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$(key LSMinimumSystemVersion)</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>$PAGE</sparkle:fullReleaseNotesLink>
      <enclosure url="$DMG" type="application/octet-stream" $SIG/>
    </item>
  </channel>
</rss>
EOF
