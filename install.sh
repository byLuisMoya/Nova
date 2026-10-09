#!/bin/bash
# Instala Nova como app de barra de menú y hace que arranque en cada login.
#   - Compila en release
#   - Crea ~/Applications/Nova.app (bundle .app autónomo, firmado ad-hoc)
#   - Instala un LaunchAgent que lo lanza al iniciar sesión (RunAtLoad)
# No requiere sudo ni root.
set -euo pipefail

APP_NAME="Nova"
BUNDLE_ID="io.github.byluismoya.Nova"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/Applications"
APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
EXEC_PATH="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT_PLIST="$AGENT_DIR/$BUNDLE_ID.plist"
UID_NUM="$(id -u)"

echo "==> Compilando release..."
cd "$PROJECT_DIR"
swift build -c release
BUILT_BIN="$(swift build -c release --show-bin-path)/$APP_NAME"

echo "==> Parando cualquier instancia previa..."
launchctl bootout "gui/$UID_NUM/$BUNDLE_ID" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true

echo "==> Creando bundle en $APP_BUNDLE..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BUILT_BIN" "$EXEC_PATH"
chmod +x "$EXEC_PATH"

# Icono del bundle (generado con tools/make-icon.swift).
if [ -f "$PROJECT_DIR/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>Nova</string>
    <key>CFBundleDisplayName</key>           <string>Nova</string>
    <key>CFBundleExecutable</key>            <string>Nova</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundleIdentifier</key>            <string>io.github.byluismoya.Nova</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>1.4</string>
    <key>CFBundleVersion</key>               <string>1.4</string>
    <key>LSMinimumSystemVersion</key>        <string>13.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Firmando ad-hoc..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo "==> Instalando LaunchAgent..."
mkdir -p "$AGENT_DIR"
cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXEC_PATH</string>
    </array>
    <key>RunAtLoad</key>        <true/>
    <key>ProcessType</key>      <string>Interactive</string>
    <key>LimitLoadToSessionType</key> <string>Aqua</string>
</dict>
</plist>
PLIST

echo "==> Cargando y arrancando..."
launchctl bootstrap "gui/$UID_NUM" "$AGENT_PLIST" 2>/dev/null || launchctl load -w "$AGENT_PLIST"
launchctl kickstart -k "gui/$UID_NUM/$BUNDLE_ID" 2>/dev/null || true

echo ""
echo "✅ Instalado."
echo "   App:          $APP_BUNDLE"
echo "   LaunchAgent:  $AGENT_PLIST"
echo "   Se ejecutará automáticamente en cada inicio de sesión."
echo "   El icono 🌡 debería aparecer ya en la barra de menú."
echo ""
echo "   Para desinstalar:  ./uninstall.sh"
