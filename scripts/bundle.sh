#!/bin/bash
# Wraps openconnect-host in build/OpenConnect.app so macOS privacy permissions
# (Screen Recording, Accessibility) belong to OpenConnect rather than to
# whatever terminal or editor launched it.
#
#   SIGN_IDENTITY="Apple Development: ..." ./scripts/bundle.sh
#
# Without SIGN_IDENTITY the app is ad-hoc signed, and macOS forgets its
# permissions every time it is rebuilt.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"

APP=build/OpenConnect.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/openconnect-host" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.openconnect.host</string>
    <key>CFBundleName</key><string>OpenConnect</string>
    <key>CFBundleExecutable</key><string>openconnect-host</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
echo "$APP"
