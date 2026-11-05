#!/bin/sh
# Desinstala nova-server del servidor: para el servicio y borra binario, configuración (token
# incluido), historia y reglas de UFW. En el servidor: sudo sh ~/nova-server/uninstall.sh
set -eu
[ "$(id -u)" = 0 ] || { echo "Ejecuta con sudo: sudo sh $0"; exit 1; }
OWNER=${SUDO_USER:-root}
systemctl disable --now nova-server.service 2>/dev/null || true
rm -f /etc/systemd/system/nova-server.service /usr/local/bin/nova-server
rm -rf /etc/nova-server /var/lib/nova-server
systemctl daemon-reload
if command -v ufw >/dev/null; then
    # `ufw show added` lista las reglas aunque UFW esté inactivo; cada una se borra repitiéndola con `delete`.
    ufw show added | grep "comment 'nova-server'" | sed 's/^ufw //' | while read -r rule; do
        eval "ufw delete $rule" || true
    done
fi
HOME_DIR=$(getent passwd "$OWNER" | cut -d: -f6)
rm -f "$HOME_DIR/.nova-server-token" "$HOME_DIR/.nova-server-port"
echo "nova-server desinstalado. Quita el servidor de ~/Library/Application Support/Nova/servers.json en el Mac."
