#!/bin/zsh
#
# Builds SwiftShare.app from app/main.swift using swiftc — no Xcode project.
# Output: ./SwiftShare.app (a menu-bar / LSUIElement app).
#
emulate -L zsh
setopt err_exit pipe_fail

ROOT="${0:A:h}"
APP="$ROOT/SwiftShare.app"
SRC="$ROOT/app/main.swift"
BIN="$APP/Contents/MacOS/SwiftShare"

echo "▸ Cleaning previous build"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "▸ Writing Info.plist"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>SwiftShare</string>
    <key>CFBundleDisplayName</key>     <string>SwiftShare</string>
    <key>CFBundleIdentifier</key>      <string>co.in.quantumleap.swiftshare</string>
    <key>CFBundleExecutable</key>      <string>SwiftShare</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>13.0</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>LSUIElement</key>             <true/>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundleIconName</key>        <string>AppIcon</string>
</dict>
</plist>
PLIST

echo "▸ Generating app icon"
if [[ ! -f "$ROOT/icon/AppIcon.icns" ]]; then
    swift "$ROOT/icon/GenerateIcon.swift" "$ROOT/icon" >/dev/null
    iconutil -c icns "$ROOT/icon/AppIcon.iconset" -o "$ROOT/icon/AppIcon.icns"
fi
cp "$ROOT/icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Compiling (swiftc)"
swiftc -O \
    -framework AppKit \
    -framework SwiftUI \
    -framework UniformTypeIdentifiers \
    "$SRC" \
    -o "$BIN"

echo "▸ Ad-hoc code signing"
codesign --force --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ Built $APP"
echo "  Launch with:  open \"$APP\""
