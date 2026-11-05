#!/bin/sh
# Instala nova-server en un servidor Linux y lo añade a Nova en este Mac.
#   ./deploy.sh usuario@servidor [puerto-ssh]
#   ./deploy.sh --pair usuario@servidor [puerto-ssh]   (solo el paso 3: otro Mac, servidor ya instalado)
#
# 1. Compila nova-server para la arquitectura del servidor (binario estático musl).
# 2. Lo copia a ~/nova-server/ del servidor y ejecuta el instalador con sudo (pide la contraseña).
# 3. Lee por SSH el token y la huella del certificado TLS que ha generado el servidor y los añade a
#    ~/Library/Application Support/Nova/servers.json (permisos 600). El token no se imprime.
set -eu
PAIR_ONLY=false
if [ "${1:-}" = "--pair" ]; then PAIR_ONLY=true; shift; fi
TARGET=${1:?uso: ./deploy.sh [--pair] usuario@servidor [puerto-ssh]}
SSH_PORT=${2:-22}
cd "$(dirname "$0")"

# Usuario y host reales (resuelve los alias de ~/.ssh/config).
SSH_USER=$(ssh -G -p "$SSH_PORT" "$TARGET" | awk '/^user /{print $2; exit}')
SSH_HOST=$(ssh -G -p "$SSH_PORT" "$TARGET" | awk '/^hostname /{print $2; exit}')

# En /tmp y no en $TMPDIR: la ruta del socket no puede pasar de 104 caracteres.
CONTROL="/tmp/nova-ssh-%C"
SSH_OPTS="-p $SSH_PORT -o ControlMaster=auto -o ControlPath=$CONTROL -o ControlPersist=120"
remote() { ssh $SSH_OPTS "$TARGET" "$@"; }

if ! $PAIR_ONLY; then
case "$(remote uname -m)" in
    x86_64) TRIPLE=x86_64-unknown-linux-musl ;;
    aarch64 | arm64) TRIPLE=aarch64-unknown-linux-musl ;;
    *) echo "Arquitectura no soportada: $(remote uname -m)"; exit 1 ;;
esac

command -v zig >/dev/null || { echo "Falta zig para compilar la parte criptográfica: brew install zig"; exit 1; }
echo "==> Compilando nova-server ($TRIPLE)..."
command -v rustup >/dev/null && rustup target add "$TRIPLE" >/dev/null
cargo build --release --target "$TRIPLE"

echo "==> Copiando a $TARGET:~/nova-server/ ..."
remote 'mkdir -p ~/nova-server'
scp -q -P "$SSH_PORT" -o ControlPath="$CONTROL" \
    "target/$TRIPLE/release/nova-server" install.sh uninstall.sh nova-server.service "$TARGET:nova-server/"

echo "==> Instalando el servicio (sudo)..."
if [ -n "${NOVA_SERVER_PORT:-}" ]; then
    case "$NOVA_SERVER_PORT" in *[!0-9]*) echo "NOVA_SERVER_PORT no es un número"; exit 1 ;; esac
    ssh -t $SSH_OPTS "$TARGET" "sudo NOVA_SERVER_PORT=$NOVA_SERVER_PORT sh ~/nova-server/install.sh"
else
    ssh -t $SSH_OPTS "$TARGET" 'sudo sh ~/nova-server/install.sh'
fi
fi

echo "==> Emparejando con Nova..."
NAME=$(remote hostname)
AGENT_PORT=$(remote 'cat ~/.nova-server-port 2>/dev/null' || true)
TAILSCALE_IP=$(remote "ip -4 -o addr show tailscale0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1" || true)
# La IP de la LAN que usa el propio servidor, para no depender de alias de ~/.ssh/config.
LAN_IP=$(remote "ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if (\$i == \"src\") { print \$(i + 1); exit }}'" || true)
is_ipv4() { echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; }
is_ipv4 "$LAN_IP" || LAN_IP=
[ -z "$TAILSCALE_IP" ] || is_ipv4 "$TAILSCALE_IP" || TAILSCALE_IP=
case "$AGENT_PORT" in '' | *[!0-9]*) AGENT_PORT=8765 ;; esac
HOST=${LAN_IP:-$SSH_HOST}
FINGERPRINT=$(remote 'cat /var/lib/nova-server/fingerprint 2>/dev/null' | tr -d '[:space:]')
case "$FINGERPRINT" in
    *[!0-9a-f]* | '') echo "No encuentro la huella del certificado en el servidor: reinstala con ./deploy.sh $TARGET"; exit 1 ;;
esac
[ ${#FINGERPRINT} -eq 64 ] || { echo "Huella del certificado no válida: $FINGERPRINT"; exit 1; }
NOVA_SERVER_TOKEN=$(remote 'cat ~/.nova-server-token') || {
    echo "No encuentro ~/.nova-server-token en el servidor: instala primero con ./deploy.sh $TARGET"; exit 1; }
export NOVA_SERVER_TOKEN
python3 -I - "$NAME" "$HOST" "${AGENT_PORT:-8765}" "$TAILSCALE_IP" "ssh://$SSH_USER@$SSH_HOST:$SSH_PORT" "$FINGERPRINT" <<'PY'
import json, os, sys
name, host, port, tailscale, ssh, fingerprint = sys.argv[1:7]
path = os.path.expanduser("~/Library/Application Support/Nova/servers.json")
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {"servers": []}
hosts = [f"https://{host}:{port}"] + ([f"https://{tailscale}:{port}"] if tailscale and tailscale != host else [])
entry = {"name": name, "hosts": hosts, "token": os.environ["NOVA_SERVER_TOKEN"], "fingerprint": fingerprint, "ssh": ssh}
data["servers"] = [s for s in data.get("servers", []) if s.get("name") != name] + [entry]
fd = os.open(path + ".tmp", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
os.replace(path + ".tmp", path)
print(f"Añadido «{name}» ({', '.join(hosts)}, huella {fingerprint[:16]}…) a {path}")
PY
unset NOVA_SERVER_TOKEN

if launchctl print "gui/$(id -u)/io.github.byluismoya.Nova" >/dev/null 2>&1; then
    launchctl kickstart -k "gui/$(id -u)/io.github.byluismoya.Nova"
    echo "Nova reiniciada: el servidor aparecerá en la barra de menú en cuanto responda."
else
    echo "Reinicia Nova para que cargue el servidor."
fi
