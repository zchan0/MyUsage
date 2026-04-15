#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="MyUsage"
BUNDLE_ID="com.zchan0.MyUsage"
VERSION="0.1.0"
BUILD_DIR="${PROJECT_DIR}/.build/release"
APP_BUNDLE="${PROJECT_DIR}/${APP_NAME}.app"

cd "$PROJECT_DIR"

echo "==> Building release…"
swift build -c release

echo "==> Assembling ${APP_NAME}.app…"
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Copy Info.plist if it exists, otherwise generate one
if [ -f "${PROJECT_DIR}/MyUsage/Resources/Info.plist" ]; then
    cp "${PROJECT_DIR}/MyUsage/Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
else
    cat > "${APP_BUNDLE}/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
PLIST
fi

# Ensure CFBundleExecutable is set (the copied plist may not have it)
if ! /usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "${APP_BUNDLE}/Contents/Info.plist" &>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string ${APP_NAME}" "${APP_BUNDLE}/Contents/Info.plist"
fi
if ! /usr/libexec/PlistBuddy -c "Print :CFBundlePackageType" "${APP_BUNDLE}/Contents/Info.plist" &>/dev/null; then
    /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "${APP_BUNDLE}/Contents/Info.plist"
fi

# Ad-hoc code sign
SIGNING="${MYUSAGE_SIGNING:-adhoc}"
if [ "$SIGNING" = "adhoc" ]; then
    echo "==> Ad-hoc signing…"
    codesign --force --deep --sign - "$APP_BUNDLE"
else
    echo "==> Signing with identity: $SIGNING"
    codesign --force --deep --sign "$SIGNING" "$APP_BUNDLE"
fi

echo "==> Done: ${APP_BUNDLE}"
echo "    Run: open ${APP_BUNDLE}"
