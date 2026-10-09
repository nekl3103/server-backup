#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cp backend/helper.py Sources/ServerBackup/Resources/helper.py
export CLANG_MODULE_CACHE_PATH="${TMPDIR:-/tmp}/server-backup-clang"
export SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR:-/tmp}/server-backup-swift"
swift build --disable-sandbox -c release
PRODUCTS="$(swift build --disable-sandbox -c release --show-bin-path)"
APP="$PWD/dist/release/Server Backup.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/ServerBackup" "$APP/Contents/MacOS/ServerBackup"
for bundle in "$PRODUCTS"/*.bundle; do cp -R "$bundle" "$APP/Contents/Resources/"; done
mkdir -p dist/AppIcon.iconset
swiftc -module-cache-path "$CLANG_MODULE_CACHE_PATH" scripts/icon.swift -o dist/make-icon
dist/make-icon dist/icon-1024.png
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" dist/icon-1024.png --out "dist/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" dist/icon-1024.png --out "dist/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns dist/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp vendor/rclone/rclone "$APP/Contents/Resources/rclone"
cp vendor/rclone/LICENSE.txt "$APP/Contents/Resources/rclone-license.txt"
codesign --force --sign - "$APP/Contents/Resources/rclone"
# SwiftPM locates executable resources via Bundle.main.resourceURL.
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ServerBackup</string>
<key>CFBundleIdentifier</key><string>ru.serverbackup.macos</string>
<key>CFBundleName</key><string>Server Backup</string>
<key>CFBundleDisplayName</key><string>Server Backup</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.9.1</string>
<key>CFBundleVersion</key><string>26</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
chmod 755 "$APP/Contents/Resources/ServerBackup_ServerBackup.bundle/Contents/Resources/Resources/askpass.sh"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/ServerBackup" --self-test
"$APP/Contents/MacOS/ServerBackup" --terminal-test
mkdir -p dist/dmg-content
rm -rf "dist/dmg-content/Server Backup.app"
cp -R "$APP" dist/dmg-content/
ln -sfn /Applications dist/dmg-content/Applications
cp README.md dist/dmg-content/Инструкция.md
hdiutil create -ov -volname 'Server Backup' -srcfolder dist/dmg-content -fs HFS+ -format UDZO dist/Server-Backup-1.9.1-arm64.dmg
hdiutil verify dist/Server-Backup-1.9.1-arm64.dmg
