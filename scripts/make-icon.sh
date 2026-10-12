#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# assets/icon.png is the master artwork (1024x1024, tile inset to 824 px per the macOS icon grid).

# Iconset lives in a fresh temp dir (left for the OS to clean up).
SET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s assets/icon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) assets/icon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/AppIcon.icns
echo "wrote assets/AppIcon.icns"
