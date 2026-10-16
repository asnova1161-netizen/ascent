#!/bin/bash
set -e

cd "$(dirname "$0")"

# Generate Xcode project
xcodegen generate

# Build
xcodebuild -project Ascent.xcodeproj -scheme Ascent -configuration Release -destination generic/platform=iOS CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Create Payload
rm -rf Payload Ascent.tipa
mkdir -p Payload
cp -R build/Release-iphoneos/Ascent.app Payload/

# Sign with ldid if available
if command -v ldid &> /dev/null; then
    ldid -SAscent/Ascent.entitlements Payload/Ascent.app/Ascent 2>/dev/null || true
fi

# Create tipa
zip -r Ascent.tipa Payload

echo "Built: $(pwd)/Ascent.tipa"
