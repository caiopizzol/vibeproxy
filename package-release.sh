#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_PATH="$PROJECT_DIR/VibeProxy.app"
ARCH="${TARGET_ARCH:-$(uname -m)}"
DIST_DIR="${OUTPUT_DIR:-$PROJECT_DIR/dist}"
ARCHIVE_NAME="VibeProxy-${ARCH}.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"

if [ ! -d "$APP_PATH" ]; then
    echo "VibeProxy.app is missing. Run 'make app' first." >&2
    exit 1
fi

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE_PATH" "$ARCHIVE_PATH.sha256"

plutil -lint "$APP_PATH/Contents/Info.plist"
codesign --verify --deep --strict "$APP_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

(
    cd "$DIST_DIR"
    shasum -a 256 "$ARCHIVE_NAME" > "$ARCHIVE_NAME.sha256"
)

echo "Created $ARCHIVE_PATH"
echo "Created $ARCHIVE_PATH.sha256"
