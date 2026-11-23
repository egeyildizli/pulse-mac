#!/bin/zsh
set -e
cd "$(dirname "$0")"
VERSION=${VERSION:-0.1.0}
BUN=${BUN:-bun}
(cd ../engine && $BUN build local/main.ts --compile --minify --no-compile-autoload-dotenv --no-compile-autoload-bunfig --no-compile-autoload-tsconfig --no-compile-autoload-package-json --outfile build/pulse-engine)
DEVFLAGS=()
[ -n "${DEV:-}" ] && DEVFLAGS=(-Xswiftc -DPULSE_DEV)
swift build -c release "${DEVFLAGS[@]}"
APP="build/Pulse.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Pulse "$APP/Contents/MacOS/Pulse"
cp ../engine/build/pulse-engine "$APP/Contents/MacOS/pulse-engine"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp ../i18n/en.json "$APP/Contents/Resources/en.json"
mkdir -p "$APP/Contents/Resources/Licenses"
cp ../legal/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"
(cd ../engine && $BUN build local/main.ts --target=bun --minify --outfile build/pulse-engine.js >/dev/null)
cp ../engine/build/pulse-engine.js "$APP/Contents/Resources/Licenses/pulse-engine.js"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Pulse</string>
  <key>CFBundleDisplayName</key><string>Pulse</string>
  <key>CFBundleIdentifier</key><string>com.pulsepanel.app</string>
  <key>CFBundleExecutable</key><string>Pulse</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Appxiom Spark LLC</string>
</dict></plist>
PLIST
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -E "Developer ID Application: Appxiom" | sed -E 's/.*"(.*)"/\1/')}
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -E "Developer ID Application" | sed -E 's/.*"(.*)"/\1/')}
case "$IDENTITY" in *"Developer ID Application"*) ;; *) IDENTITY="-" ;; esac
codesign --force --options runtime --timestamp=none --entitlements engine.entitlements --sign "$IDENTITY" "$APP/Contents/MacOS/pulse-engine"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
mkdir -p ~/Applications
[ -n "$NO_INSTALL" ] && { echo "derlendi: $APP"; exit 0; }
rm -rf ~/Applications/Pulse.app
cp -R "$APP" ~/Applications/
echo "kuruldu: ~/Applications/Pulse.app ($IDENTITY)"
