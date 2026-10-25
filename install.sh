#!/bin/bash
# Prox-Kiox (Wayland/cage) - instalação idempotente num nó Proxmox VE.
# Uso:  ./install.sh [--window|--kiosk]   (como root, no nó; leva files/ ao lado)
#   --window (omissão) -> Firefox em janela, com barra de abas
#   --kiosk            -> Firefox em ecrã inteiro, sem barras
# Repõe: binários em /usr/local/bin, units em /etc/systemd/system, user.js no
# perfil do Firefox, e ativa o serviço + o vigia (timer de 1 min).
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "ERRO: correr como root" >&2; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)

MODO=""
case "${1:-}" in
    --kiosk)  MODO="kiosk" ;;
    --window) MODO="window" ;;
    "")       ;;
    *)        echo "ERRO: opção desconhecida '$1' (use --window ou --kiosk)" >&2; exit 1 ;;
esac

echo "== pacotes =="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cage firefox-esr

echo "== ficheiros =="
install -m 0755 "$SRC/files/prox-kiox-wl"          /usr/local/bin/prox-kiox-wl
install -m 0755 "$SRC/files/prox-kiox-has-display" /usr/local/bin/prox-kiox-has-display
install -m 0755 "$SRC/files/prox-kiox-guard"       /usr/local/bin/prox-kiox-guard
install -m 0755 "$SRC/files/prox-kiox-mode"        /usr/local/bin/prox-kiox-mode
install -m 0755 "$SRC/files/prox-kiox-url"         /usr/local/bin/prox-kiox-url
install -m 0644 "$SRC/files/prox-kiox.service"       /etc/systemd/system/prox-kiox.service
install -m 0644 "$SRC/files/prox-kiox-guard.service" /etc/systemd/system/prox-kiox-guard.service
install -m 0644 "$SRC/files/prox-kiox-guard.timer"   /etc/systemd/system/prox-kiox-guard.timer
touch /var/log/prox-kiox.log

# Modo: só muda se o pedido for explícito (um `install.sh` sem argumentos numa
# máquina já configurada não toca no modo). As outras chaves — PROX_KIOX_IDLE e
# PROX_KIOX_URL — são preservadas; antes eram apagadas nesta reescrita.
if [ -n "$MODO" ]; then
    tmp=$(mktemp)
    [ -r /etc/default/prox-kiox ] && grep -v '^[[:space:]]*PROX_KIOX_MODE=' /etc/default/prox-kiox > "$tmp" || true
    printf 'PROX_KIOX_MODE=%s\n' "$MODO" >> "$tmp"
    cat "$tmp" > /etc/default/prox-kiox
    rm -f "$tmp"
elif [ ! -r /etc/default/prox-kiox ]; then
    printf '# Prox-Kiox - definicoes do kiosk (window|kiosk, IDLE em segundos, URL)\nPROX_KIOX_MODE=window\nPROX_KIOX_IDLE=0\nPROX_KIOX_URL=\n' > /etc/default/prox-kiox
fi
echo "  modo: $(. /etc/default/prox-kiox && echo "${PROX_KIOX_MODE:-window}")  (trocar: prox-kiox-mode kiosk|window)"

echo "== perfil do Firefox =="
shopt -s nullglob
profiles=(/root/.mozilla/firefox/*.default-esr)
if [ ${#profiles[@]} -eq 0 ]; then
    echo "  (sem perfil ainda; o user.js será aplicado no próximo install)"
else
    for d in "${profiles[@]}"; do install -m 0644 "$SRC/files/user.js" "$d/user.js"; echo "  user.js -> $d"; done
fi

echo "== systemd =="
systemctl daemon-reload
systemctl enable prox-kiox.service prox-kiox-guard.timer >/dev/null
systemctl restart prox-kiox-guard.timer
# Se já estiver ativo, `start` não faz nada e o modo novo não era aplicado:
# reiniciar. Num nó sem monitor o ExecCondition salta o arranque (sem falha).
if systemctl is-active --quiet prox-kiox.service; then
    systemctl restart prox-kiox.service || true
else
    systemctl start prox-kiox.service || true
fi
sleep 6

echo "== estado =="
echo -n "monitor ligado: "; /usr/local/bin/prox-kiox-has-display && echo sim || echo nao
systemctl is-active prox-kiox.service | sed 's/^/prox-kiox.service: /'
pgrep -x cage >/dev/null && echo "cage: a correr (pid $(pgrep -x cage | tr '\n' ' '))" || echo "cage: parado"
pgrep -x firefox-esr >/dev/null && echo "firefox-esr: a correr" || echo "firefox-esr: parado"
systemctl list-timers prox-kiox-guard.timer --no-pager | tail -2
