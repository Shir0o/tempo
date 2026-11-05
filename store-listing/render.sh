#!/usr/bin/env bash
# Regenerate the Google Play store listing assets from the app's own design.
# Requires Google Chrome (headless screenshots) and Python 3 + Pillow.
set -euo pipefail
cd "$(dirname "$0")"

CHROME="${CHROME:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
if [ ! -x "$CHROME" ]; then
  echo "Google Chrome not found at: $CHROME" >&2
  echo "Set CHROME=/path/to/chrome and retry." >&2
  exit 1
fi

cp ../assets/fonts/SpaceGrotesk-VariableFont_wght.ttf src/SpaceGrotesk.ttf

render() {
  local html="$1" out="$2" w="$3" h="$4"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --no-first-run \
    --no-default-browser-check --allow-file-access-from-files \
    --force-device-scale-factor=1 --virtual-time-budget=3000 \
    --window-size="$w,$h" --screenshot="$out" \
    "file://$(pwd)/src/$html" >/dev/null 2>&1
  echo "rendered $out (${w}x${h})"
}

render watch-quick-log.html   wear-screenshot-1-quick-log-768.png 768 768
render watch-confirmation.html wear-screenshot-2-label-768.png   768 768
render feature-graphic.html   feature-graphic-1024x500.png       1024 500
render icon.html              icon-512.png                       512 512
render phone-1.html           phone-screenshot-1-1080x1920.png   1080 1920
render phone-2.html           phone-screenshot-2-1080x1920.png   1080 1920

# Play asks for a 32-bit PNG app icon; Chrome writes RGB.
python3 - <<'PY'
from PIL import Image
im = Image.open("icon-512.png").convert("RGBA")
im.save("icon-512.png")
print("icon-512.png converted to RGBA")
PY
