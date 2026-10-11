#!/bin/zsh
# Builds Scan.app (Release) and installs it into the local applications folder.
#
#   scripts/install.sh              build and install to /Applications
#   INSTALL_DIR=/somewhere scripts/install.sh
#   DERIVED_DATA=/path scripts/install.sh   reuse an existing DerivedData folder

set -euo pipefail

INSTALL_DIR="${INSTALL_DIR:-/Applications}"
PROJECT_DIR="${0:A:h:h}"
DERIVED_DATA="${DERIVED_DATA:-${TMPDIR:-/tmp}/Scan-DerivedData}"
APP="$DERIVED_DATA/Build/Products/Release/Scan.app"

xcodebuild -project "$PROJECT_DIR/Scan.xcodeproj" -scheme Scan -configuration Release \
    -derivedDataPath "$DERIVED_DATA" -destination 'platform=macOS,arch=arm64' -quiet build

if pgrep -xq Scan; then
    echo "Scan is running. Quit it first, then run this script again." >&2
    exit 1
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/Scan.app"
ditto "$APP" "$INSTALL_DIR/Scan.app"
codesign --verify --deep --strict "$INSTALL_DIR/Scan.app"

echo "Installed $INSTALL_DIR/Scan.app ($(defaults read "$INSTALL_DIR/Scan.app/Contents/Info" CFBundleShortVersionString), build $(defaults read "$INSTALL_DIR/Scan.app/Contents/Info" CFBundleVersion))"
