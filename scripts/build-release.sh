#!/usr/bin/env bash
set -euo pipefail

VERSION=${1:-"1.0.0"}

echo "Building release mode for version $VERSION..."
swift build -c release

echo "Packaging SQLitizer.app..."
rm -rf SQLitizer.app
mkdir -p SQLitizer.app/Contents/MacOS
mkdir -p SQLitizer.app/Contents/Resources
cp .build/release/SQLitizer SQLitizer.app/Contents/MacOS/SQLitizer

# Generate Info.plist dynamically
cat << EOF > SQLitizer.app/Contents/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SQLitizer</string>
    <key>CFBundleIdentifier</key>
    <string>com.adamghill.sqlitizer</string>
    <key>CFBundleName</key>
    <string>SQLitizer</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns SQLitizer.app/Contents/Resources/AppIcon.icns
else
    echo "Warning: AppIcon.icns not found! Run 'just generate-icon' first if you need it."
fi

echo "Signing application ad-hoc..."
codesign --force --deep -s - SQLitizer.app

echo "Creating zip archive with ditto..."
ditto -c -k --keepParent SQLitizer.app SQLitizer-macOS.zip

echo "Successfully created SQLitizer-macOS.zip!"
