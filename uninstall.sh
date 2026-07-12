#!/bin/bash
# Desinstala Nova: para el proceso, quita el LaunchAgent y borra el bundle.
set -uo pipefail

APP_NAME="Nova"
BUNDLE_ID="io.github.byluismoya.Nova"
APP_BUNDLE="$HOME/Applications/$APP_NAME.app"
AGENT_PLIST="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
UID_NUM="$(id -u)"

echo "==> Parando y descargando el LaunchAgent..."
launchctl bootout "gui/$UID_NUM/$BUNDLE_ID" 2>/dev/null || true
launchctl unload -w "$AGENT_PLIST" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true

echo "==> Borrando archivos..."
rm -f "$AGENT_PLIST"
rm -rf "$APP_BUNDLE"

echo "✅ Desinstalado."
