# Build the application in release mode and package it into a .app bundle
build-release version="1.0.0":
    ./scripts/build-release.sh "{{version}}"

# Regenerate AppIcon.icns from AppIcon.png
generate-icon:
    ./scripts/generate-icon.sh
