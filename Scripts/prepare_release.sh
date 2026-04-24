#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="MyUsage"
SOURCE_PLIST="${PROJECT_DIR}/MyUsage/Resources/Info.plist"
APP_PLIST="${PROJECT_DIR}/${APP_NAME}.app/Contents/Info.plist"
UPDATE_PLIST=1
VERSION=""
BUILD_NUMBER=""

usage() {
    echo "Usage: $0 --version <x.y.z> [--build <n>] [--no-update-plist]"
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            shift 2
            ;;
        --build)
            BUILD_NUMBER="${2:-}"
            shift 2
            ;;
        --no-update-plist)
            UPDATE_PLIST=0
            shift
            ;;
        *)
            usage
            ;;
    esac
done

if [ -z "$VERSION" ]; then
    usage
fi

if [ ! -f "$SOURCE_PLIST" ]; then
    echo "Missing source Info.plist: $SOURCE_PLIST"
    exit 1
fi

if [ -z "$BUILD_NUMBER" ]; then
    BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$SOURCE_PLIST")"
fi

if [ "$UPDATE_PLIST" -eq 1 ]; then
    echo "==> Updating source Info.plist to ${VERSION} (${BUILD_NUMBER})"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "$SOURCE_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER}" "$SOURCE_PLIST"
fi

echo "==> Packaging app bundle"
MYUSAGE_VERSION="$VERSION" MYUSAGE_BUILD="$BUILD_NUMBER" "${SCRIPT_DIR}/package_app.sh"

ACTUAL_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PLIST")"
ACTUAL_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_PLIST")"

if [ "$ACTUAL_VERSION" != "$VERSION" ] || [ "$ACTUAL_BUILD" != "$BUILD_NUMBER" ]; then
    echo "Version mismatch after packaging:"
    echo "  expected: ${VERSION} (${BUILD_NUMBER})"
    echo "  actual:   ${ACTUAL_VERSION} (${ACTUAL_BUILD})"
    exit 1
fi

ZIP_NAME="${APP_NAME}-${VERSION}.zip"
ZIP_PATH="${PROJECT_DIR}/${ZIP_NAME}"

echo "==> Creating zip archive"
rm -f "$ZIP_PATH" "${ZIP_PATH}.sha256"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "${PROJECT_DIR}/${APP_NAME}.app" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "${ZIP_PATH}.sha256"

echo "==> Release artifacts ready:"
echo "    ${ZIP_PATH}"
echo "    ${ZIP_PATH}.sha256"
