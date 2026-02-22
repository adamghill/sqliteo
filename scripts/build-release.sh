#!/usr/bin/env bash
set -euo pipefail

VERSION=${1:-"1.0.0"}

echo "Building release mode for version $VERSION..."
swift build -c release

echo "Packaging SQLiteo.app..."
rm -rf SQLiteo.app
mkdir -p SQLiteo.app/Contents/MacOS
mkdir -p SQLiteo.app/Contents/Resources
cp .build/release/SQLiteo SQLiteo.app/Contents/MacOS/SQLiteo

echo "Copying resource bundles..."
cp -R .build/release/*.bundle SQLiteo.app/Contents/Resources/

# Generate Info.plist dynamically
cat << EOF > SQLiteo.app/Contents/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SQLiteo</string>
    <key>CFBundleIdentifier</key>
    <string>com.adamghill.sqliteo</string>
    <key>CFBundleName</key>
    <string>SQLiteo</string>
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
    cp AppIcon.icns SQLiteo.app/Contents/Resources/AppIcon.icns
else
    echo "Warning: AppIcon.icns not found! Run 'just generate-icon' first if you need it."
fi

echo "Signing application ad-hoc..."
codesign --force --deep -s - SQLiteo.app

echo "Creating zip archive with ditto..."
ditto -c -k --keepParent SQLiteo.app SQLiteo-macOS.zip

echo "Successfully created SQLiteo-macOS.zip!"
