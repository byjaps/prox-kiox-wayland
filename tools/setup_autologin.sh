#!/bin/bash
# Prepara o autologin do kiosk num nó PVE:
#   1. garante o utilizador kiosk@pve (PVEAdmin) e o token API `panel` sem expiração
#   2. define uma password própria para esse utilizador (só serve para obter `cap`)
#   3. semeia o localStorage do perfil do Firefox (token + cap) e deixa o kiosk pronto
#
# Correr como root NO NÓ, com o serviço parado (o script trata disso).
set -uo pipefail
USERID=kiosk@pve
TOKENID=panel
DIR=/etc/prox-kiox
CONF=$DIR/config
PASSF=$DIR/kiosk-pass
TOKF=$DIR/kiosk-token

[ "$EUID" -eq 0 ] || { echo "ERRO: correr como root" >&2; exit 1; }
mkdir -p "$DIR" && chmod 700 "$DIR"

# --- utilizador e permissões
pveum user add "$USERID" --comment "Ecra local Prox-Kiox (autologin)" 2>/dev/null || true
pveum acl modify / --users "$USERID" --roles PVEAdmin >/dev/null
echo "utilizador $USERID com role PVEAdmin"

# --- password (só para o login que devolve as capabilities)
if [ -s "$PASSF" ]; then
    echo "password já existente"
else
    PW=$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 28)
    printf '%s\n' "$PW" > "$PASSF"
    chmod 600 "$PASSF"
    pveum user modify "$USERID" --password "$PW" >/dev/null
    echo "password gerada e guardada em $PASSF"
fi

# --- token API sem expiração
if [ -s "$TOKF" ]; then
    echo "token já existente"
else
    pveum user token add "$USERID" "$TOKENID" --privsep 0 --output-format json > /tmp/pk-token.json
    python3 -c "import json;d=json.load(open('/tmp/pk-token.json'));open('$TOKF','w').write(d['value']+'\n')"
    shred -u /tmp/pk-token.json 2>/dev/null || rm -f /tmp/pk-token.json
    chmod 600 "$TOKF"
    echo "token $USERID!$TOKENID criado"
fi

# --- semear o perfil (precisa do Firefox parado e de uma sessão Marionette)
# O guard (timer de 1 min) volta a arrancar o kiosk a meio da semeação e briga
# pelo DRM; pára-se durante o processo e volta-se a ligar no fim.
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

python3 "$(dirname "$0")/seed_pve_auth.py" --user "$USERID" --token-id "$TOKENID" \
    --pass-file "$PASSF" --token-file "$TOKF" || {
        echo "ERRO: falhou a semeação; log em /tmp/prox-kiox-seed.log" >&2
        systemctl start prox-kiox.service
        systemctl start prox-kiox-guard.timer 2>/dev/null || true
        exit 1
    }

pkill -x firefox-esr 2>/dev/null || true
pkill -x cage 2>/dev/null || true
sleep 2
systemctl start prox-kiox.service
systemctl start prox-kiox-guard.timer 2>/dev/null || true
sleep 8
echo "serviço: $(systemctl is-active prox-kiox.service)"
echo "token: revogar com  pveum user token remove $USERID $TOKENID"
