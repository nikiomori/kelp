#!/bin/zsh
# Build dist/Kelp.app (+ DMG). One command:  scripts/bundle.sh   (or `make release`)
#   scripts/bundle.sh dev   (`make dev`): a debug build for this Mac in dist/dev/Kelp.app, signed ad hoc, then opens it
# Signing/notarization are opt-in via env:
#   SIGN_ID="Developer ID Application: Name (TEAM)"   sign app + dmg
#   NOTARY_PROFILE=kelp                               notarytool keychain profile (xcrun notarytool store-credentials)
set -euo pipefail
cd "$(dirname "$0")/.."
DEV=${1:-}
CONFIG=${CONFIG:-release}; ARCHS=(--arch arm64 --arch x86_64); APP=dist/Kelp.app
if [ "$DEV" = dev ]; then
  CONFIG=debug; ARCHS=(); APP=dist/dev/Kelp.app
  # Replacing a running app's files can crash it; its daemon (and agents) may keep running.
  if pgrep -qf "$PWD/$APP/Contents/MacOS/KelpApp"; then echo "Quit Kelp (dev) first: ⌘Q"; exit 1; fi
# Finder names disks: with another "Kelp" mounted, the DMG's window layout below would go to that one.
elif [ -d /Volumes/Kelp ]; then echo "Eject the Kelp disk first: hdiutil detach /Volumes/Kelp"; exit 1
fi
# The terminal renders with libghostty (universal static lib, built once into Vendor/).
[ -d Vendor/GhosttyKit.xcframework ] || scripts/build-ghostty.sh
swift build -c "$CONFIG" "${ARCHS[@]}"
BIN=$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)
rm -rf "$APP"; [ "$DEV" = dev ] || rm -f dist/Kelp.dmg
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/KelpApp" "$APP/Contents/MacOS/KelpApp"
# -p: kelpd keeps its build time, which the app compares with the running daemon's; an update that didn't rebuild
# the daemon then doesn't offer to restart it (that ends the running agents). Signing below puts the time back.
cp -p "$BIN/kelpd" "$BIN/kelp" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Library/LaunchAgents"; cp Resources/dev.kelp.kelpd.plist "$APP/Contents/Library/LaunchAgents/"   # BackgroundItem
cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # from AppIcon.svg: scripts/icon.sh
[ -d "$BIN/Sparkle.framework" ] && cp -R "$BIN/Sparkle.framework" "$APP/Contents/Frameworks/" || true
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done
scripts/strings.sh install "$APP/Contents/Resources"   # English and Russian
# The About panel shows Credits.html: the licenses of the code shipped inside, which they ask every copy to carry.
{ print '<pre style="font: 10px Menlo; white-space: pre-wrap">'
  for d in Vendor/GhosttyKit.xcframework .build/checkouts/${^${(f)"$(sed -nE 's|.*"location" : ".*/([^/]+)".*|\1|p' Package.resolved)"}%.git}; do
    for f in $d/LICENSE*(N[1]); do print "<b>${d:t:r}</b>"; sed 's/&/\&amp;/g; s/</\&lt;/g' "$f"; print; done
  done; print '</pre>'; } > "$APP/Contents/Resources/Credits.html"
if [ -n "${SIGN_ID:-}" ]; then
  SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_ID")
  # Sparkle ships its helpers ad-hoc signed; notarization needs every nested binary signed by us, inside out.
  SP="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  if [ -d "$SP" ]; then
    "${SIGN[@]}" "$SP/XPCServices/Installer.xpc"
    "${SIGN[@]}" --preserve-metadata=entitlements "$SP/XPCServices/Downloader.xpc"
    "${SIGN[@]}" "$SP/Autoupdate"
    "${SIGN[@]}" "$SP/Updater.app"
    "${SIGN[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
  fi
  "${SIGN[@]}" "$APP/Contents/MacOS/kelpd"; touch -r "$BIN/kelpd" "$APP/Contents/MacOS/kelpd"
  "${SIGN[@]}" "$APP/Contents/MacOS/kelp"
  codesign --force --options runtime --timestamp --entitlements Resources/Kelp.entitlements --sign "$SIGN_ID" "$APP"
fi
if [ "$DEV" = dev ]; then
  # Ad hoc, inside out; no entitlements, as a debug build runs from Xcode.
  for f in "$APP/Contents/MacOS/kelpd" "$APP/Contents/MacOS/kelp" "$APP"; do codesign --force --sign - "$f"; done
  touch -r "$BIN/kelpd" "$APP/Contents/MacOS/kelpd"
  open "$APP"; echo "built $APP"; exit 0
fi
STAGE=$(mktemp -d); cp -Rp "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
# The window the DMG opens in: its background (Resources/DMGBackground.svg: scripts/icon.sh), where the icons stand, the
# disk's icon. Finder lays it out in a writable copy and keeps it in the disk's .DS_Store.
mkdir "$STAGE/.background"; cp Resources/DMGBackground.tiff "$STAGE/.background/background.tiff"
cp Resources/AppIcon.icns "$STAGE/.VolumeIcon.icns"
hdiutil create -quiet -volname Kelp -srcfolder "$STAGE" -ov -format UDRW "$STAGE.dmg"
MNT=$(hdiutil attach -readwrite -noverify -noautoopen "$STAGE.dmg" 2>/dev/null | sed -n 's|.*\(/Volumes/.*\)|\1|p')
SetFile -a C "$MNT"
osascript - "$MNT" <<'EOF'
on run {mnt}
  tell application "Finder"
    set d to folder (POSIX file mnt as alias)
    open d
    set w to container window of d
    set current view of w to icon view
    set toolbar visible of w to false
    set statusbar visible of w to false
    set pathbar visible of w to false
    set bounds of w to {200, 120, 860, 548} -- 660 × 400 under the title bar
    set o to icon view options of w
    set arrangement of o to not arranged
    set icon size of o to 128
    set text size of o to 13
    set background picture of o to file ".background:background.tiff" of d
    set position of item "Kelp.app" of d to {165, 170}
    set position of item "Applications" of d to {495, 170}
    repeat with f in {".background", ".VolumeIcon.icns", ".fseventsd"} -- out of sight where hidden files show
      try
        set position of item f of d to {165, 900}
      end try
    end repeat
    close w
  end tell
end run
EOF
for _ in {1..50}; do [ -f "$MNT/.DS_Store" ] && break; sleep 0.2; done   # Finder writes it after the window closes
rm -rf "$MNT/.fseventsd"; sync
hdiutil detach -quiet "$MNT"
hdiutil convert -quiet "$STAGE.dmg" -format UDZO -ov -o dist/Kelp.dmg
rm -rf "$STAGE" "$STAGE.dmg"
if [ -n "${SIGN_ID:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_ID" dist/Kelp.dmg
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    OUT=$(xcrun notarytool submit dist/Kelp.dmg --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
    ID=$(print -r -- "$OUT" | plutil -extract id raw -o - -)
    STATUS=$(print -r -- "$OUT" | plutil -extract status raw -o - -)
    echo "notarization $ID: $STATUS"
    if [ "$STATUS" != "Accepted" ]; then
      xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE"   # Apple's reasons, per file
      exit 1
    fi
    xcrun stapler staple dist/Kelp.dmg
    spctl -a -t open --context context:primary-signature -v dist/Kelp.dmg
  fi
fi
echo "built dist/Kelp.dmg"
