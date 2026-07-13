#!/bin/bash
# Empaqueta Nova.app (release, firmada ad-hoc) en un .zip listo para publicar
# como asset de un GitHub Release y consumir desde un cask de Homebrew.
#
# Uso:   ./tools/package-release.sh [version]     (por defecto 1.0)
# Salida: Nova-<version>.zip en la raíz del proyecto + su sha256.
set -euo pipefail

APP_NAME="Nova"
BUNDLE_ID="io.github.byluismoya.Nova"
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-1.0}"
BUILD_DIR="$PROJECT_DIR/.release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXEC_PATH="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ZIP_PATH="$PROJECT_DIR/$APP_NAME-$VERSION.zip"

echo "==> Compilando release..."
cd "$PROJECT_DIR"
swift build -c release
BUILT_BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> Creando bundle en $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILT_BIN" "$EXEC_PATH"
chmod +x "$EXEC_PATH"

if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>Nova</string>
    <key>CFBundleDisplayName</key>           <string>Nova</string>
    <key>CFBundleExecutable</key>            <string>Nova</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Firmando ad-hoc..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Comprimiendo a $ZIP_PATH..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo ""
echo "✅ Paquete listo:"
echo "   $ZIP_PATH"
echo ""
echo "   sha256 (cópialo para el cask):"
shasum -a 256 "$ZIP_PATH" | awk '{print "   " $1}'
