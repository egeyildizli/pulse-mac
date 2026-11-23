#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
VERSION=${VERSION:-0.1.0}
BUN=${BUN:-bun}
OUT=dist
mkdir -p "$OUT"

: "${NOTARY_KEY:?NOTARY_KEY gerekli}" "${NOTARY_KEY_ID:?NOTARY_KEY_ID gerekli}" "${NOTARY_ISSUER:?NOTARY_ISSUER gerekli}"
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -E "Developer ID Application: Appxiom" | sed -E 's/.*"(.*)"/\1/' || true)}
IDENTITY=${IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 -E "Developer ID Application" | sed -E 's/.*"(.*)"/\1/' || true)}
[[ "$IDENTITY" == *"Developer ID Application"* ]] || { echo "Developer ID Application sertifikası yok"; exit 1; }

echo "1/6 motor (arm64 + x86_64)"
(cd engine && $BUN build local/main.ts --compile --minify --no-compile-autoload-dotenv --no-compile-autoload-bunfig --no-compile-autoload-tsconfig --no-compile-autoload-package-json --target=bun-darwin-arm64 --outfile build/pulse-engine-arm64 >/dev/null \
  && $BUN build local/main.ts --compile --minify --no-compile-autoload-dotenv --no-compile-autoload-bunfig --no-compile-autoload-tsconfig --no-compile-autoload-package-json --target=bun-darwin-x64 --outfile build/pulse-engine-x64 >/dev/null \
  && lipo -create build/pulse-engine-arm64 build/pulse-engine-x64 -output build/pulse-engine-universal)

echo "2/6 panel (arm64 + x86_64)"
(cd mac && swift build -c release --arch arm64 --arch x86_64 -Xswiftc -DPULSE_OFFICIAL >/dev/null)

echo "3/6 paket"
APP="$OUT/Pulse.app"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp mac/.build/apple/Products/Release/Pulse "$APP/Contents/MacOS/Pulse"
cp engine/build/pulse-engine-universal "$APP/Contents/MacOS/pulse-engine"
[ -f mac/Resources/AppIcon.icns ] && cp mac/Resources/AppIcon.icns "$APP/Contents/Resources/"
cp i18n/en.json "$APP/Contents/Resources/en.json"
mkdir -p "$APP/Contents/Resources/Licenses"
cp legal/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/"
(cd engine && $BUN build local/main.ts --target=bun --minify --outfile build/pulse-engine.js >/dev/null)
cp engine/build/pulse-engine.js "$APP/Contents/Resources/Licenses/pulse-engine.js"
for l in mac/Resources/*.lproj(N); do cp -R "$l" "$APP/Contents/Resources/"; done
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
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Appxiom Spark LLC</string>
</dict></plist>
PLIST

echo "4/6 imza"
codesign --force --options runtime --timestamp --entitlements mac/engine.entitlements --sign "$IDENTITY" "$APP/Contents/MacOS/pulse-engine"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"

echo "5/6 Apple onayı (uygulama)"
NOTARY=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
ditto -c -k --keepParent "$APP" "$OUT/Pulse.zip"
xcrun notarytool submit "$OUT/Pulse.zip" "${NOTARY[@]}" --wait --timeout 30m | tail -3
xcrun stapler staple "$APP" >/dev/null
rm -f "$OUT/Pulse.zip"

echo "6/6 DMG + Apple onayı"
DMG="$OUT/Pulse-${VERSION}.dmg"
STAGE=$(mktemp -d)
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Pulse" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait --timeout 30m | tail -3
xcrun stapler staple "$DMG" >/dev/null
spctl -a -t open --context context:primary-signature -v "$DMG" 2>&1 | tail -1
spctl -a -t exec -v "$APP" 2>&1 | tail -1
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
ls -la "$DMG" | awk '{print "boyut:", $5}'
