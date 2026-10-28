#!/bin/bash
# Wraps mac-rdp-server in build/mac-rdp-server.app so macOS privacy permissions
# (Screen Recording, Accessibility) belong to mac-rdp-server rather than to
# whatever terminal or editor launched it.
#
#   SIGN_IDENTITY="Apple Development: ..." ./scripts/bundle.sh
#
# Without SIGN_IDENTITY it uses the identity from make-signing-identity.sh if
# this Mac has one. Otherwise the app is ad-hoc signed, and macOS forgets its
# permissions every time it is rebuilt.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
swift build -c "$CONFIG"

APP=build/mac-rdp-server.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp ".build/$CONFIG/mac-rdp-server" "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>io.github.m-mutti.mac-rdp-server</string>
    <key>CFBundleName</key><string>mac-rdp-server</string>
    <key>CFBundleDisplayName</key><string>mac-rdp-server</string>
    <key>CFBundleExecutable</key><string>mac-rdp-server</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.6</string>
    <key>CFBundleVersion</key><string>9</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF
LOCAL_KEYCHAIN="$HOME/Library/Keychains/mac-rdp-server-signing.keychain-db"
LOCAL_PASSWORD="$HOME/Library/Application Support/mac-rdp-server-signing/keychain-password"
if [ -z "${SIGN_IDENTITY:-}" ] && [ -f "$LOCAL_KEYCHAIN" ] && [ -f "$LOCAL_PASSWORD" ]; then
    security unlock-keychain -p "$(cat "$LOCAL_PASSWORD")" "$LOCAL_KEYCHAIN"
    codesign --force --keychain "$LOCAL_KEYCHAIN" --sign "mac-rdp-server Local Signing" "$APP"
else
    codesign --force --sign "${SIGN_IDENTITY:--}" "$APP"
fi
echo "$APP"
