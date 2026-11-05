#!/bin/sh
# Instala nova-server como servicio systemd que arranca con la máquina.
#   sudo sh install.sh
# Espera el binario `nova-server` junto a este script (lo deja ahí ./deploy.sh desde el Mac).
#
# Cada máquina genera su propio token la primera vez y lo guarda en
#   /etc/nova-server/config.json   (solo root)
#   ~/.nova-server-token           (solo el usuario que ejecutó sudo, para emparejar el Mac)
#   ~/.nova-server-port            (el puerto, sin secreto)
# Reinstalar conserva el token. Para cambiarlo: borra config.json y vuelve a instalar.
#
# Al arrancar, el agente genera su certificado TLS en /var/lib/nova-server (clave solo root) y deja
# su huella en /var/lib/nova-server/fingerprint, que el Mac fija al emparejar.
# El agente solo atiende a IPs privadas (LAN, Tailscale, loopback) aunque no haya firewall.
#
# Variables opcionales (con sudo hay que pasarlas detrás: sudo NOVA_SERVER_PORT=9000 sh install.sh):
#   NOVA_SERVER_PORT   puerto (8765 por defecto); si se da, también cambia el de una instalación existente
#   NOVA_SERVER_ALLOW  red que UFW deja pasar, si está activo (por defecto, la LAN de la ruta por defecto)
set -eu
[ "$(id -u)" = 0 ] || { echo "Ejecuta con sudo: sudo sh $0"; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)
OWNER=${SUDO_USER:-root}
PORT=${NOVA_SERVER_PORT:-8765}
case "$PORT" in '' | *[!0-9]*) echo "NOVA_SERVER_PORT no es un número: $PORT"; exit 1 ;; esac
CONFIG=/etc/nova-server/config.json
umask 077

[ -x "$HERE/nova-server" ] || { echo "Falta $HERE/nova-server (cópialo con ./deploy.sh)"; exit 1; }
command -v smartctl >/dev/null || { command -v apt-get >/dev/null && apt-get install -y smartmontools || echo "Aviso: sin smartctl no habrá datos SMART"; }

install -m 755 "$HERE/nova-server" /usr/local/bin/nova-server
install -d -m 700 /etc/nova-server
if [ ! -f "$CONFIG" ]; then
    TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '=+/\n')
    printf '{\n  "port": %s,\n  "bind": "0.0.0.0",\n  "token": "%s"\n}\n' "$PORT" "$TOKEN" > "$CONFIG"
fi
chmod 600 "$CONFIG"
if [ -n "${NOVA_SERVER_PORT:-}" ]; then
    sed -i "s/\"port\": *[0-9]*/\"port\": $PORT/" "$CONFIG"
fi
TOKEN=$(sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' "$CONFIG")
PORT=$(sed -n 's/.*"port": *\([0-9]*\).*/\1/p' "$CONFIG")
PORT=${PORT:-8765}
[ -n "$TOKEN" ] || { echo "$CONFIG no tiene token"; exit 1; }

# Copia para emparejar el Mac, escrita como el propio usuario (no como root) para no seguir
# un enlace simbólico que haya en su home. Con `sudo` desde root, va a /root.
HOME_DIR=$(getent passwd "$OWNER" | cut -d: -f6)
write_as_owner() {
    if [ "$OWNER" = root ]; then
        rm -f "$1" && printf '%s\n' "$2" > "$1" && chmod "$3" "$1"
    else
        printf '%s\n' "$2" | runuser -u "$OWNER" -- sh -c 'umask 077; rm -f "$1"; cat > "$1"; chmod "$2" "$1"' sh "$1" "$3"
    fi
}
write_as_owner "$HOME_DIR/.nova-server-token" "$TOKEN" 600
write_as_owner "$HOME_DIR/.nova-server-port" "$PORT" 644

install -m 644 "$HERE/nova-server.service" /etc/systemd/system/nova-server.service
systemctl daemon-reload
systemctl enable nova-server.service
systemctl restart nova-server.service

if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    ALLOW=${NOVA_SERVER_ALLOW:-}
    if [ -z "$ALLOW" ]; then
        DEV=$(ip -4 route show default | awk '{print $5; exit}')
        ALLOW=$(ip -4 -o route show dev "$DEV" scope link | awk '{print $1; exit}')
    fi
    if [ -n "$ALLOW" ]; then
        ufw allow from "$ALLOW" to any port "$PORT" proto tcp comment nova-server
    fi
    if [ -e /sys/class/net/tailscale0 ]; then
        ufw allow in on tailscale0 to any port "$PORT" proto tcp comment nova-server
    fi
fi

FINGERPRINT_FILE=/var/lib/nova-server/fingerprint
i=0
while [ ! -s "$FINGERPRINT_FILE" ] && [ $i -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
systemctl --no-pager --lines=3 status nova-server.service || true
[ -s "$FINGERPRINT_FILE" ] || { echo "nova-server no ha generado su certificado: journalctl -u nova-server"; exit 1; }
echo "nova-server instalado en https, puerto $PORT. Huella del certificado: $(cat "$FINGERPRINT_FILE")"
