#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/DeployBar"

APP="build/DeployBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DeployBar"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>one.tijarah.deploybar</string>
    <key>CFBundleName</key><string>DeployBar</string>
    <key>CFBundleExecutable</key><string>DeployBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDisplayName</key><string>DeployBar</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Murtaza</string>
    <key>LSUIElement</key><true/>
    <key>NSAppSleepDisabled</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST

codesign --force -s - "$APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p "$HOME/Applications"
    pkill -x DeployBar || true
    sleep 1
    rm -rf "$HOME/Applications/DeployBar.app"
    cp -R "$APP" "$HOME/Applications/DeployBar.app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/DeployBar.app"
    open "$HOME/Applications/DeployBar.app"
fi
