#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p marketing
# Frames (about 1 GB) and the compiled renderer live in a temp dir, removed on exit.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/frames"
swiftc -O -module-name promo scripts/make-promo.swift -o "$TMP/promo"
"$TMP/promo" marketing "$TMP/frames"

if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
    VCODEC=(-c:v libx264 -crf 18)
else
    VCODEC=(-c:v h264_videotoolbox -b:v 8M)
fi
for pair in frames:reel frames-land:twitter; do
    ffmpeg -y -loglevel error -framerate 30 -i "$TMP/${pair%%:*}/%04d.png" "${VCODEC[@]}" \
        -pix_fmt yuv420p -an -movflags +faststart "marketing/${pair##*:}.mp4"
done
echo "wrote marketing/reel.mp4 marketing/post.png marketing/social-preview.png marketing/twitter.png marketing/twitter.mp4"
