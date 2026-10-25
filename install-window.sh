#!/bin/bash
# =============================================================================
# Prox-Kiox — VERSÃO B: JANELA DO FIREFOX (--new-window)
# =============================================================================
# Põe a interface web do Proxmox VE (https://127.0.0.1:8006) no monitor do nó
# numa janela normal do Firefox — com barra de abas, barra de endereços e menus —
# e mantém-na viva depois de updates. O `cage` continua a dar o ecrã todo a essa
# única janela, mas agora dá para abrir mais abas (Ctrl+T): router, Home
# Assistant, o que for preciso, tudo a partir do mesmo teclado.
#
# Diferença em relação à Versão A: lá o Firefox arranca com --kiosk (sem barras);
# aqui arranca com --new-window. Tudo o resto — serviço, autostart, guarda do
# monitor, resistência a updates — é idêntico.
#
# PORQUÊ WAYLAND E NÃO X11 (a razão de o kiosk antigo morrer nos updates):
#   Os kernels da PVE arrancam com lockdown=integrity. Nesse modo o Xorg não
#   consegue abrir as portas de I/O VGA e aborta:
#       xf86EnableIO: failed to enable I/O ports 0000-03ff (Operation not permitted)
#       xinit: connection to X server lost
#   O truque habitual é pôr lockdown=none na linha de comandos do kernel — ou
#   seja, enfraquecer o kernel de todos os nós. Aqui não há X nenhum: o `cage`
#   é um compositor Wayland de aplicação única, desenha por KMS/DRM, não usa
#   portas de I/O, e corre com o lockdown intacto. Um upgrade de kernel não lhe
#   toca.
#
# O QUE FICA RESISTENTE A UPDATES DA PVE:
#   * Nada em /etc/pve, nada na linha de comandos do kernel, nada no GRUB.
#   * Units em /etc/systemd/system (a PVE não as gere nem as substitui).
#   * ExecCondition: num nó sem monitor o serviço é saltado, não falha nem
#     atrasa o boot — e o getty@tty1 fica intacto.
#   * Timer de 1 min: se o cabo HDMI chegar depois do boot (ou mudar de nó), o
#     kiosk arranca sozinho; se o cabo sair, pára.
#   * Restart=always: Firefox ou cage a cair → volta em ~10 s.
#   * O wrapper espera que o pveproxy responda antes de lançar o Firefox, para
#     um upgrade/restart da PVE não deixar no ecrã um "não foi possível ligar".
#
# Uso (como root, no nó):
#   ./install-window.sh              instala / atualiza
#   ./install-window.sh --uninstall  remove tudo (mantém o log)
#
# Página aberta: por omissão a UI da PVE local (https://127.0.0.1:8006). Para
# abrir outra coisa (Home Assistant, Grafana, Glances, ...) usa-se
# `prox-kiox-url https://...` depois de instalar — ou, no install,
# `PROX_KIOX_URL=https://... ./install-window.sh`.
#
# Este ficheiro é autónomo: não precisa da pasta files/ nem de git clone.
# =============================================================================
set -euo pipefail

[ "$EUID" -eq 0 ] || { echo "ERRO: correr como root" >&2; exit 1; }

LOG=/var/log/prox-kiox.log
CONF=/etc/default/prox-kiox
MODE=window
ARGS="--new-window"

# ---------------------------------------------------------------- desinstalar
if [ "${1:-}" = "--uninstall" ]; then
    systemctl disable --now prox-kiox-guard.timer 2>/dev/null || true
    systemctl disable --now prox-kiox.service     2>/dev/null || true
    rm -f /etc/systemd/system/prox-kiox.service \
          /etc/systemd/system/prox-kiox-guard.service \
          /etc/systemd/system/prox-kiox-guard.timer \
          /usr/local/bin/prox-kiox-wl \
          /usr/local/bin/prox-kiox-has-display \
          /usr/local/bin/prox-kiox-guard \
          /usr/local/bin/prox-kiox-mode \
          /usr/local/bin/prox-kiox-url \
          /usr/local/bin/prox-kiox-idle \
          /usr/local/bin/prox-kiox-refresh \
          /etc/systemd/system/prox-kiox-refresh.service \
          /etc/systemd/system/prox-kiox-refresh.timer \
          "$CONF"
    systemctl daemon-reload
    pkill -x firefox-esr 2>/dev/null || true
    echo "Prox-Kiox removido. Log mantido em $LOG"
    exit 0
fi

echo "== pacotes =="
apt-get update -qq
# `cage` no Debian depende de xwayland; não remover xwayland depois disto.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cage firefox-esr ddcutil swayidle

echo "== binários =="
install -m 0755 /dev/stdin /usr/local/bin/prox-kiox-wl <<'WRAPPER'
#!/bin/bash
# Arranca cage + Firefox ESR sobre a PVE web UI (modo definido em
# /etc/default/prox-kiox). Corre como serviço systemd (prox-kiox.service):
# sem X11, logo sem portas de I/O — compatível com lockdown=integrity.
set -u

PROX_KIOX_MODE="window"
PROX_KIOX_IDLE="0"
[ -r /etc/default/prox-kiox ] && . /etc/default/prox-kiox
export PROX_KIOX_IDLE

case "${PROX_KIOX_MODE:-window}" in
    kiosk)  ARGS="--kiosk" ;;
    *)      ARGS="--new-window" ;;
esac

URL="${PROX_KIOX_URL:-https://127.0.0.1:8006}"

# Autologin e renovação do ticket só existem para a UI da PVE local: com outra
# página (Home Assistant, Grafana, Glances, ...) não há ticket nenhum para
# renovar, e o prox-kiox-login não tem o que fazer.
case "$URL" in
    https://127.0.0.1:8006|https://localhost:8006) PVE_LOCAL=1 ;;
    *)                                             PVE_LOCAL=0 ;;
esac

# Um firefox órfão deixa o perfil bloqueado e abre o diálogo "already running".
pkill -x firefox-esr 2>/dev/null && sleep 1

# Autologin (opcional): se /usr/local/bin/prox-kiox-login estiver instalado,
# renova o ticket da PVE no perfil antes de o Firefox abrir. Sem ele, o kiosk
# mostra o formulário de login normal. Só se aplica à UI da PVE local.
[ "$PVE_LOCAL" = 1 ] && { /usr/local/bin/prox-kiox-login 2>/dev/null || true; }

# Liberta o tty1 (consola de texto da PVE) só no instante em que o kiosk arranca;
# num nó sem monitor o getty nunca é tocado.
systemctl stop getty@tty1.service 2>/dev/null
# Consola de socorro: o tty1 fica entregue ao cage, por isso Ctrl+Alt+F2 tem de
# encontrar um getty — senão o nó fica sem consola local (parar o kiosk não
# resolve: o prox-kiox-guard.timer volta a arrancá-lo em menos de um minuto).
systemctl start getty@tty2.service 2>/dev/null || true

# Espera pelo pveproxy: depois de um upgrade/restart da PVE o serviço pode
# arrancar antes da API responder, e o Firefox ficaria com um erro no ecrã.
# Só para a PVE local: com uma página remota (Home Assistant, Grafana, ...) uma
# espera de minutos com a máquina em baixo dava um ecrã negro — o Firefox mostra
# antes a página de erro, que se recarrega quando o serviço voltar.
if [ "$PVE_LOCAL" = 1 ] && command -v curl >/dev/null 2>&1; then
    for _ in $(seq 1 60); do
        if curl -sk -o /dev/null --max-time 3 "$URL"; then break; fi
        sleep 2
    done
fi


# Ecrã: apaga o monitor por DDC/CI depois de PROX_KIOX_IDLE segundos sem input
# (300 por omissão) e acorda com a primeira tecla/rato. Arranca em paralelo,
# assim que o socket Wayland existir; o systemd leva-o consigo ao parar.
#
# Com o standby ligado, o `prox-kiox-idle` que arranca abaixo acende o monitor e
# só o apaga ao fim de PROX_KIOX_IDLE segundos sem input — um restart acende o
# ecrã por desenho (é o que evita ficar preto sem ninguém a acordá-lo). Quem
# impede o ecrã de acender de madrugada é o `prox-kiox-refresh`, que adia a
# renovação do cookie com o monitor em standby.
if [ "${PROX_KIOX_IDLE:-0}" = "0" ] || [ "${PROX_KIOX_IDLE:-0}" = "off" ]; then
    /usr/local/bin/prox-kiox-idle --on 2>/dev/null || true
fi

if [ "${PROX_KIOX_IDLE:-0}" != "0" ] && [ "${PROX_KIOX_IDLE:-0}" != "off" ]; then
(
    WD=""
    for _ in $(seq 1 40); do
        WD=$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -type s -name 'wayland-*' -printf '%f\n' 2>/dev/null | head -1)
        [ -n "$WD" ] && break
        sleep 0.5
    done
    [ -n "$WD" ] || exit 0
    # O cage só anuncia idle-notify depois de criar o socket; sem esta pausa o
    # swayidle liga-se cedo demais e nunca dispara.
    sleep 3
    WAYLAND_DISPLAY="$WD" exec /usr/local/bin/prox-kiox-idle
) &
fi

exec cage -s -- /usr/bin/firefox-esr $ARGS "$URL"
WRAPPER

install -m 0755 /dev/stdin /usr/local/bin/prox-kiox-has-display <<'HASDISP'
#!/bin/bash
# 0 = há pelo menos um monitor ligado (conector DRM "connected"); 1 = headless.
# Usado como ExecCondition do prox-kiox.service: numa máquina sem monitor o
# serviço é saltado (não fica em falha, não bloqueia o boot).
n=$(cat /sys/class/drm/card[0-9]-*/status 2>/dev/null | grep -c '^connected$')
[ "${n:-0}" -gt 0 ]
HASDISP

install -m 0755 /dev/stdin /usr/local/bin/prox-kiox-guard <<'GUARD'
#!/bin/bash
# Vigia do kiosk (timer de 1 min):
#   monitor ligado  e kiosk parado  -> arranca (cobre o cabo mudado de nó)
#   monitor desligado e kiosk ativo -> pára (não desenha para o nada)
#   kiosk vivo                      -> não faz nada
set -u
LOG=/var/log/prox-kiox.log
if /usr/local/bin/prox-kiox-has-display; then
    if ! systemctl is-active --quiet prox-kiox.service; then
        echo "$(date -Is) guard: monitor detetado, a arrancar kiosk" >> "$LOG"
        systemctl start prox-kiox.service
    fi
else
    if systemctl is-active --quiet prox-kiox.service; then
        echo "$(date -Is) guard: sem monitor, a parar kiosk" >> "$LOG"
        systemctl stop prox-kiox.service
    fi
fi
exit 0
GUARD

install -m 0755 /dev/stdin /usr/local/bin/prox-kiox-mode <<'MODE'
#!/bin/bash
# prox-kiox-mode [status|window|kiosk]  — troca o modo e reinicia o serviço.
# Preserva as outras chaves de /etc/default/prox-kiox (PROX_KIOX_IDLE, PROX_KIOX_URL).
set -u
CONF=/etc/default/prox-kiox

conf_get() { # chave -> valor (vazio se não existir)
    [ -r "$CONF" ] || return 0
    awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$CONF"
}

set_key() { # chave valor — muda só essa linha; o resto do ficheiro fica igual
    local tmp
    tmp=$(mktemp) || return 1
    [ -r "$CONF" ] && grep -v "^[[:space:]]*$1=" "$CONF" > "$tmp"
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    cat "$tmp" > "$CONF"
    rm -f "$tmp"
}

case "${1:-status}" in
    status|"")
        u=$(conf_get PROX_KIOX_URL)
        echo "modo atual: $(conf_get PROX_KIOX_MODE)"
        if [ -n "$u" ]; then echo "URL:         $u"
        else echo "URL:         https://127.0.0.1:8006 (omissão)"; fi
        echo "serviço: $(systemctl is-active prox-kiox.service 2>/dev/null)"
        ;;
    window|kiosk)
        [ "$EUID" -eq 0 ] || { echo "ERRO: precisa de root" >&2; exit 1; }
        [ -r "$CONF" ] || printf '# Prox-Kiox - definicoes do kiosk\nPROX_KIOX_IDLE=0\nPROX_KIOX_URL=\n' > "$CONF"
        set_key PROX_KIOX_MODE "$1"
        echo "modo -> $1"
        systemctl restart prox-kiox.service && echo "serviço reiniciado"
        ;;
    *) echo "uso: prox-kiox-mode [window|kiosk|status]" >&2; exit 1 ;;
esac
MODE

install -m 0755 /dev/stdin /usr/local/bin/prox-kiox-url <<'URLCMD'
#!/bin/bash
# prox-kiox-url [URL|pve|status]  — que página o kiosk abre.
#   prox-kiox-url                              mostra a URL atual
#   prox-kiox-url https://192.168.1.42:8123  abre o Home Assistant
#   prox-kiox-url https://192.168.1.77:61208 abre o Glances, etc.
#   prox-kiox-url pve                          volta à UI da PVE local
# Sem PROX_KIOX_URL definido o kiosk abre https://127.0.0.1:8006.
set -u
CONF=/etc/default/prox-kiox
DEFAULT_PVE="https://127.0.0.1:8006"

conf_get() {
    [ -r "$CONF" ] || return 0
    awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$CONF"
}

set_key() { # chave valor — muda só essa linha
    local tmp
    tmp=$(mktemp) || return 1
    [ -r "$CONF" ] && grep -v "^[[:space:]]*$1=" "$CONF" > "$tmp"
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    cat "$tmp" > "$CONF"
    rm -f "$tmp"
}

aplicar() { # $1 = valor ("" = omissão PVE)
    [ "$(id -u)" -eq 0 ] || { echo "ERRO: precisa de root" >&2; exit 1; }
    set_key PROX_KIOX_URL "$1"
    if [ -n "$1" ]; then echo "URL -> $1"; else echo "URL -> $DEFAULT_PVE (omissão)"; fi
    if [ -n "$1" ] && command -v curl >/dev/null 2>&1; then
        curl -sk -o /dev/null --max-time 4 "$1" \
            || echo "AVISO: $1 não respondeu agora; o kiosk tenta à mesma." >&2
    fi
    if systemctl restart prox-kiox.service 2>/dev/null; then
        echo "serviço reiniciado"
    else
        echo "serviço não arrancou (sem monitor ligado?) — aplica-se no próximo arranque"
    fi
}

case "${1:-status}" in
    status|"")
        u=$(conf_get PROX_KIOX_URL)
        echo "URL: ${u:-$DEFAULT_PVE}"
        [ -n "$u" ] && echo "omissão: $DEFAULT_PVE  (voltar: prox-kiox-url pve)"
        ;;
    pve|default)       aplicar "" ;;
    http://*|https://*) aplicar "$1" ;;
    *) echo "uso: prox-kiox-url [URL|pve|status]" >&2; exit 1 ;;
esac
URLCMD

install -m 0755 /dev/stdin /usr/local/bin/prox-kiox-idle <<'IDLE'
#!/bin/bash
# Apaga o monitor após PROX_KIOX_IDLE segundos sem input e acorda com input.
# O cage não implementa wlr-output-power-management (wlopm não serve), por isso
# usa DDC/CI. Sem monitor DDC (nó headless, KVM sem DDC) sai em silêncio.
set -u

find_bus() { ddcutil detect --brief 2>/dev/null | awk '/I2C bus:/{print $NF; exit}'; }

BUS="$(find_bus)"
[ -n "${BUS:-}" ] || exit 0
BUS="${BUS#/dev/i2c-}"

power() { ddcutil -b "$BUS" setvcp d6 "$1" >/dev/null 2>&1 || true; }

# 0/off = nunca apagar (omissão): não arrancar sequer o swayidle.
if [ "${1:-}" = "" ] && { [ "${PROX_KIOX_IDLE:-0}" = "0" ] || [ "${PROX_KIOX_IDLE:-0}" = "off" ]; }; then
    exit 0
fi

case "${1:-}" in
    --off) power 4; exit 0 ;;
    --on)
        power 1
        # Se o cookie estiver a expirar (ficou a expirar enquanto o ecrã esteve em
        # standby), agenda a renovação: o utilizador está aqui agora.
        /usr/local/bin/prox-kiox-refresh --ao-acordar >/dev/null 2>&1 &
        exit 0
        ;;
esac

# 4 = DPMS standby, 1 = on. Acorda no arranque para o caso de o serviço
# reiniciar com o ecrã apagado (o novo swayidle não recebia um "resume").
power 1

exec swayidle -w \
    timeout "${PROX_KIOX_IDLE:-300}" "$0 --off" \
    resume "$0 --on"
IDLE

install -m 0755 /dev/stdin /usr/local/bin/prox-kiox-refresh <<'REFRESH'
#!/bin/bash
# Renova o ticket da PVE antes de expirar (2 h). Corre a cada 15 min e só
# reinicia o serviço quando faltam menos de 20 min: o arranque reescreve o
# cookie e recarrega a página, sem reinícios desnecessários.
set -u

# Só a UI da PVE local tem ticket para renovar. Com outra URL (Home Assistant,
# Grafana, ...) este timer não tem nada para fazer e sai já.
[ -r /etc/default/prox-kiox ] && . /etc/default/prox-kiox 2>/dev/null || true
case "${PROX_KIOX_URL:-}" in
    ""|https://127.0.0.1:8006|https://localhost:8006) : ;;
    *) exit 0 ;;
esac

DB=$(ls /root/.mozilla/firefox/*.default*/cookies.sqlite 2>/dev/null | head -1)
[ -n "${DB:-}" ] || exit 0

segundos_de_cookie() {
    python3 - "$DB" <<'PY'
import sqlite3, sys, time
try:
    c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro&immutable=1", uri=True)
    row = c.execute("select expiry from moz_cookies where name='PVEAuthCookie'").fetchone()
    print(int(row[0] / 1000 - time.time()) if row else -1)
except Exception:
    print(-1)
PY
}

LEFT=$(segundos_de_cookie)

# --ao-acordar: chamado pelo prox-kiox-idle quando o monitor acorda. Com o ecrã
# em standby a renovação é adiada, por isso quem voltar ao kiosk ao fim de horas
# apanhava o formulário de login até ao tick seguinte (≤15 min). Aqui, com
# alguém à frente do ecrã, agenda-se um reinício (que renova o cookie e
# recarrega a página) 2 s depois — desanexado do serviço, senão o reinício
# matava quem o pediu. Guarda de 15 min para nunca entrar em ciclo de reinícios.
if [ "${1:-}" = "--ao-acordar" ]; then
    [ "$LEFT" -gt 1200 ] && exit 0
    STAMP=/run/prox-kiox-renovacao.stamp
    if [ -f "$STAMP" ] && [ $(( $(date +%s) - $(stat -c %Y "$STAMP") )) -lt 900 ]; then
        exit 0
    fi
    touch "$STAMP"
    systemd-run --quiet --collect --on-active=2 --unit="prox-kiox-renew-$(date +%s)" \
        systemctl restart prox-kiox.service >/dev/null 2>&1 || true
    exit 0
fi

[ "${LEFT:--1}" -lt 0 ] && exit 0
[ "$LEFT" -gt 1200 ] && exit 0

# NÃO acordar o ecrã: o reinício do kiosk provoca um modeset e o monitor sai do
# standby com o sinal novo (medido: 0x02 -> 0x01 ~4 s depois). Com o monitor em
# standby não se renova: o próximo tick, já com alguém à frente do ecrã,
# reinicia e renova o cookie.
bus=$(ddcutil detect --brief 2>/dev/null | awk '/I2C bus:/{print $NF; exit}')
if [ -n "${bus:-}" ]; then
    modo=$(ddcutil -b "${bus#/dev/i2c-}" getvcp d6 2>/dev/null || true)
    case "$modo" in
        *"sl=0x01"*) : ;;                                   # ligado: pode reiniciar
        *"sl=0x"*)   echo "[$(date -Is)] ecra em standby: renovacao adiada"; exit 0 ;;
    esac
fi

systemctl restart prox-kiox.service
REFRESH

echo "== units =="
install -m 0644 /dev/stdin /etc/systemd/system/prox-kiox.service <<'UNIT'
[Unit]
Description=Prox-Kiox - PVE web UI no ecra local (Wayland/cage, modo janela)
After=systemd-user-sessions.service pveproxy.service
Wants=pveproxy.service

[Service]
Type=simple
Environment=HOME=/root
Environment=MOZ_ENABLE_WAYLAND=1
Environment=XDG_RUNTIME_DIR=/run/prox-kiox
Environment=WLR_LIBINPUT_NO_DEVICES=1
Environment=MOZ_CRASHREPORTER_DISABLE=1
RuntimeDirectory=prox-kiox
RuntimeDirectoryMode=0700
# Sem monitor ligado o serviço é saltado (headless) em vez de falhar em ciclo.
ExecCondition=/usr/local/bin/prox-kiox-has-display
ExecStart=/usr/local/bin/prox-kiox-wl
# Firefox/cage a cair -> volta a subir sozinho.
Restart=always
RestartSec=10
StandardOutput=append:/var/log/prox-kiox.log
StandardError=append:/var/log/prox-kiox.log

[Install]
WantedBy=multi-user.target
UNIT

install -m 0644 /dev/stdin /etc/systemd/system/prox-kiox-guard.service <<'GSVC'
[Unit]
Description=Prox-Kiox guard (arranca/para o kiosk conforme o monitor)

[Service]
Type=oneshot
ExecStart=/usr/local/bin/prox-kiox-guard
GSVC

install -m 0644 /dev/stdin /etc/systemd/system/prox-kiox-guard.timer <<'GTIMER'
[Unit]
Description=Prox-Kiox guard a cada minuto

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
GTIMER

install -m 0644 /dev/stdin /etc/systemd/system/prox-kiox-refresh.service <<'RSVC'
[Unit]
Description=Prox-Kiox - renovar o ticket da PVE antes de expirar
After=prox-kiox.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/prox-kiox-refresh
RSVC

install -m 0644 /dev/stdin /etc/systemd/system/prox-kiox-refresh.timer <<'RTIMER'
[Unit]
Description=Prox-Kiox - verificar o ticket da PVE a cada 15 min

[Timer]
OnBootSec=15min
OnUnitActiveSec=15min
AccuracySec=1min

[Install]
WantedBy=timers.target
RTIMER

touch "$LOG"
# Escreve sempre o modo: este instalador é explícito quanto a ele (janela). O que
# o utilizador já tenha afinado no ficheiro (IDLE, URL) é preservado — antes era
# apagado em cada instalação e em cada `prox-kiox-mode`.
idle_atual=""; [ -r "$CONF" ] && idle_atual=$(awk -F= '$1=="PROX_KIOX_IDLE"{sub(/^[^=]*=/,"");print;exit}' "$CONF")
url_atual="";  [ -r "$CONF" ] && url_atual=$(awk -F= '$1=="PROX_KIOX_URL"{sub(/^[^=]*=/,"");print;exit}' "$CONF")
cat > "$CONF" <<CONF_EOF
# Prox-Kiox — definições do kiosk (aplicadas no arranque do serviço).
# window (janela com abas) ou kiosk (ecrã inteiro).
PROX_KIOX_MODE=$MODE
# Segundos sem input até apagar o ecrã; 0 = nunca apagar (omissão).
PROX_KIOX_IDLE=${PROX_KIOX_IDLE:-${idle_atual:-0}}
# Página que o kiosk abre; vazio = UI da PVE local.
# Trocar: prox-kiox-url https://192.168.1.42:8123   (voltar: prox-kiox-url pve)
PROX_KIOX_URL=${PROX_KIOX_URL:-${url_atual:-}}
CONF_EOF

echo "== perfil do Firefox =="
shopt -s nullglob
profiles=(/root/.mozilla/firefox/*.default-esr)
if [ ${#profiles[@]} -eq 0 ]; then
    echo "  (ainda sem perfil; abre o Firefox uma vez e volta a correr o instalador)"
else
    for d in "${profiles[@]}"; do
        install -m 0644 /dev/stdin "$d/user.js" <<'USERJS'
// Preferências do perfil Prox-Kiox (aplicadas em cada arranque).
user_pref("browser.sessionstore.resume_from_crash", false);
user_pref("browser.sessionstore.max_resumed_crashes", 0);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("browser.tabs.warnOnClose", false);
user_pref("app.update.auto", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
// Usa a loja de CAs do sistema (útil se houver CA local para o :8006).
user_pref("security.enterprise_roots.enabled", true);
// Modo janela: Ctrl+T abre uma aba nova. A sessão NÃO é restaurada depois de um
// restart (para nunca aparecer o diálogo "restaurar sessão" a tapar o ecrã).
// Para as abas voltarem sozinhas, descomenta a linha seguinte:
// user_pref("browser.startup.page", 3);
USERJS
        echo "  user.js -> $d"
    done
fi

echo "== systemd =="
systemctl daemon-reload
systemctl enable prox-kiox.service prox-kiox-guard.timer prox-kiox-refresh.timer >/dev/null
systemctl restart prox-kiox-refresh.timer
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
pgrep -x cage >/dev/null && echo "cage: a correr" || echo "cage: parado"
pgrep -x firefox-esr >/dev/null && echo "firefox-esr: a correr" || echo "firefox-esr: parado"
echo "modo: $MODE  (trocar: prox-kiox-mode kiosk)"
echo "log: $LOG"