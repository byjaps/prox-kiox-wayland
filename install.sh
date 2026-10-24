#!/bin/bash
# Prox-Kiox (Wayland/cage) - instalação idempotente num nó Proxmox VE.
# Uso:  ./install.sh        (como root, no nó; leva a pasta files/ ao lado)
# Repõe: binários em /usr/local/bin, units em /etc/systemd/system, user.js no
# perfil do Firefox, e ativa o serviço + o vigia (timer de 1 min).
set -euo pipefail
[ "$EUID" -eq 0 ] || { echo "ERRO: correr como root" >&2; exit 1; }
SRC=$(cd "$(dirname "$0")" && pwd)

echo "== pacotes =="
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cage firefox-esr

echo "== ficheiros =="
install -m 0755 "$SRC/files/prox-kiox-wl"          /usr/local/bin/prox-kiox-wl
install -m 0755 "$SRC/files/prox-kiox-has-display" /usr/local/bin/prox-kiox-has-display
install -m 0755 "$SRC/files/prox-kiox-guard"       /usr/local/bin/prox-kiox-guard
install -m 0644 "$SRC/files/prox-kiox.service"       /etc/systemd/system/prox-kiox.service
install -m 0644 "$SRC/files/prox-kiox-guard.service" /etc/systemd/system/prox-kiox-guard.service
install -m 0644 "$SRC/files/prox-kiox-guard.timer"   /etc/systemd/system/prox-kiox-guard.timer
touch /var/log/prox-kiox.log

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
systemctl start prox-kiox.service || true   # ExecCondition pode saltar (sem monitor)
sleep 6

echo "== estado =="
echo -n "monitor ligado: "; /usr/local/bin/prox-kiox-has-display && echo sim || echo nao
systemctl is-active prox-kiox.service | sed 's/^/prox-kiox.service: /'
pgrep -x cage >/dev/null && echo "cage: a correr (pid $(pgrep -x cage | tr '\n' ' '))" || echo "cage: parado"
pgrep -x firefox-esr >/dev/null && echo "firefox-esr: a correr" || echo "firefox-esr: parado"
systemctl list-timers prox-kiox-guard.timer --no-pager | tail -2
