#!/usr/bin/env bash
set -euo pipefail

# This script generates the Apple Icon Image format (.icns) from AppIcon.png
# It uses built-in macOS tools (sips and iconutil) to create the various resolutions required.

ICON_SRC="AppIcon.png"
ICON_SET="AppIcon.iconset"
ICON_DEST="AppIcon.icns"

if [ ! -f "$ICON_SRC" ]; then
    echo "Error: $ICON_SRC not found."
    exit 1
fi

echo "Converting $ICON_SRC to $ICON_DEST..."

# Create the temporary iconset directory
mkdir -p "$ICON_SET"

# Generate all required resolutions using sips
sips -z 16 16     "$ICON_SRC" --out "$ICON_SET/icon_16x16.png" > /dev/null
sips -z 32 32     "$ICON_SRC" --out "$ICON_SET/icon_16x16@2x.png" > /dev/null
sips -z 32 32     "$ICON_SRC" --out "$ICON_SET/icon_32x32.png" > /dev/null
sips -z 64 64     "$ICON_SRC" --out "$ICON_SET/icon_32x32@2x.png" > /dev/null
sips -z 128 128   "$ICON_SRC" --out "$ICON_SET/icon_128x128.png" > /dev/null
sips -z 256 256   "$ICON_SRC" --out "$ICON_SET/icon_128x128@2x.png" > /dev/null
sips -z 256 256   "$ICON_SRC" --out "$ICON_SET/icon_256x256.png" > /dev/null
sips -z 512 512   "$ICON_SRC" --out "$ICON_SET/icon_256x256@2x.png" > /dev/null
sips -z 512 512   "$ICON_SRC" --out "$ICON_SET/icon_512x512.png" > /dev/null
sips -z 1024 1024 "$ICON_SRC" --out "$ICON_SET/icon_512x512@2x.png" > /dev/null

# Compile the iconset into the final .icns file
iconutil -c icns "$ICON_SET" -o "$ICON_DEST"

# Clean up
rm -rf "$ICON_SET"

echo "Successfully created $ICON_DEST!"
