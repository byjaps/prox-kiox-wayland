#!/bin/bash
# Refaz a sessão do kiosk: semeia o localStorage (token + capacidades) e renova
# o cookie. Corre NO NÓ, como root. Pára o serviço e o guard durante o processo.
set -uo pipefail
[ "$EUID" -eq 0 ] || { echo "ERRO: correr como root" >&2; exit 1; }
DIR=$(cd "$(dirname "$0")" && pwd)

systemctl stop prox-kiox-guard.timer 2>/dev/null || true
systemctl stop prox-kiox.service 2>/dev/null || true
pkill -x firefox-esr 2>/dev/null || true
pkill -x cage 2>/dev/null || true
sleep 2

rm -rf /run/prox-kiox; mkdir -p /run/prox-kiox; chmod 700 /run/prox-kiox
export HOME=/root XDG_RUNTIME_DIR=/run/prox-kiox MOZ_ENABLE_WAYLAND=1 WLR_LIBINPUT_NO_DEVICES=1
nohup cage -s -- /usr/bin/firefox-esr --marionette --new-window https://127.0.0.1:8006 \
    >/tmp/prox-kiox-seed.log 2>&1 &
sleep 14

python3 "$DIR/seed_pve_auth.py" --user kiosk@pve --token-id panel \
    --pass-file /etc/prox-kiox/kiosk-pass --token-file /etc/prox-kiox/kiosk-token

pkill -x firefox-esr 2>/dev/null || true
pkill -x cage 2>/dev/null || true
sleep 2

/usr/local/bin/prox-kiox-login || true
systemctl start prox-kiox.service
systemctl start prox-kiox-guard.timer 2>/dev/null || true
sleep 8
echo "serviço: $(systemctl is-active prox-kiox.service)"
