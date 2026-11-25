#!/bin/bash
# Builds TaxiMeter.app (ad-hoc signed) and TaxiMeter.zip. Not notarized: buyers approve first launch in System Settings.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Taxi Meter.app"
BIN="$APP/Contents/MacOS/TaxiMeter"
RES="$APP/Contents/Resources"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$RES"
swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos13 TaxiMeter.swift -o "$BIN"
"$BIN" --selftest

python3 sounds.py "$RES"

# icon: the app renders its own 1024px icon, sips makes the sizes
"$BIN" --icon build/icon.png
SET=build/TaxiMeter.iconset && mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o "$RES/TaxiMeter.icns"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Taxi Meter</string>
<key>CFBundleIdentifier</key><string>app.taximeter.mac</string>
<key>CFBundleExecutable</key><string>TaxiMeter</string>
<key>CFBundleIconFile</key><string>TaxiMeter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
codesign --force --sign - "$APP"
(cd build && ditto -c -k --keepParent "Taxi Meter.app" TaxiMeter.zip)
echo "built $APP and build/TaxiMeter.zip"
