#!/bin/zsh
# Resources/AppIcon.svg → Resources/AppIcon.icns, AppIconDev.svg → AppIconDev.icns (Kelp Dev's, `make dev`),
# Resources/DMGBackground.svg → Resources/DMGBackground.tiff (1x + 2x). Renders with Chrome (headless) for a transparent
# background.  scripts/icon.sh AppIconDev   renders only that one.
set -euo pipefail
cd "$(dirname "$0")/.."
T=$(mktemp -d)
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
for name in ${@:-AppIcon AppIconDev}; do
  SET=$T/$name.iconset; mkdir "$SET"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=1 \
    --default-background-color=00000000 --window-size=1024,1024 --screenshot="$T/1024.png" "file://$PWD/Resources/$name.svg" 2>/dev/null
  for s in 16 32 128 256 512; do
    sips -z $s $s "$T/1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$T/1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$SET" -o Resources/$name.icns
  echo "wrote Resources/$name.icns"
done
[ $# -eq 0 ] || exit 0
for x in 1 2; do
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --force-device-scale-factor=$x --window-size=660,400 \
    --screenshot="$T/bg$x.png" "file://$PWD/Resources/DMGBackground.svg" 2>/dev/null
done
tiffutil -cathidpicheck "$T/bg1.png" "$T/bg2.png" -out Resources/DMGBackground.tiff   # LZW, a Retina pair
echo "wrote Resources/DMGBackground.tiff"
