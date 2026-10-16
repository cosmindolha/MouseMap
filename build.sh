#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/build/MouseMap.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swift scripts/make_icon.swift "$PWD/build/MouseMap.iconset"
iconutil -c icns "$PWD/build/MouseMap.iconset" -o "$APP/Contents/Resources/MouseMap.icns"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macosx14.0" Sources/*.swift Tests/SelfTests.swift -lsqlite3 -o "$APP/Contents/MacOS/MouseMap"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.cosmindolha.MouseMap</string>
<key>CFBundleName</key><string>MouseMap</string>
<key>CFBundleDisplayName</key><string>MouseMap</string>
<key>CFBundleExecutable</key><string>MouseMap</string>
<key>CFBundleIconFile</key><string>MouseMap</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>3</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>LSUIElement</key><true/>
<key>NSInputMonitoringUsageDescription</key><string>Read your Logitech mouse buttons and gestures to run your app-specific shortcuts.</string>
</dict></plist>
PLIST
# Ad-hoc signing needs no credentials. Use your own Keychain identity for a stable
# development signature across rebuilds.
codesign --force --sign "${MOUSEMAP_SIGNING_IDENTITY:--}" --identifier com.cosmindolha.MouseMap "$APP"
"$APP/Contents/MacOS/MouseMap" --self-test
echo "$APP"
