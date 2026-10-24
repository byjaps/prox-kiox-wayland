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
          "$CONF"
    systemctl daemon-reload
    pkill -x firefox-esr 2>/dev/null || true
    echo "Prox-Kiox removido. Log mantido em $LOG"
    exit 0
fi

echo "== pacotes =="
apt-get update -qq
# `cage` no Debian depende de xwayland; não remover xwayland depois disto.
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq cage firefox-esr

echo "== binários =="
install -m 0755 /dev/stdin /usr/local/bin/prox-kiox-wl <<'WRAPPER'
#!/bin/bash
# Arranca cage + Firefox ESR sobre a PVE web UI (modo definido em
# /etc/default/prox-kiox). Corre como serviço systemd (prox-kiox.service):
# sem X11, logo sem portas de I/O — compatível com lockdown=integrity.
set -u

PROX_KIOX_MODE="window"
[ -r /etc/default/prox-kiox ] && . /etc/default/prox-kiox

case "${PROX_KIOX_MODE:-window}" in
    kiosk)  ARGS="--kiosk" ;;
    *)      ARGS="--new-window" ;;
esac

URL="${PROX_KIOX_URL:-https://127.0.0.1:8006}"

# Um firefox órfão deixa o perfil bloqueado e abre o diálogo "already running".
pkill -x firefox-esr 2>/dev/null && sleep 1

# Liberta o tty1 (consola de texto da PVE) só no instante em que o kiosk arranca;
# num nó sem monitor o getty nunca é tocado.
systemctl stop getty@tty1.service 2>/dev/null

# Espera pelo pveproxy: depois de um upgrade/restart da PVE o serviço pode
# arrancar antes da API responder, e o Firefox ficaria com um erro no ecrã.
if command -v curl >/dev/null 2>&1; then
    for _ in $(seq 1 60); do
        if curl -sk -o /dev/null --max-time 3 "$URL"; then break; fi
        sleep 2
    done
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
set -u
CONF=/etc/default/prox-kiox
atual() { local m="window"; [ -r "$CONF" ] && . "$CONF" && m="${PROX_KIOX_MODE:-window}"; echo "$m"; }
case "${1:-status}" in
    status|"") echo "modo atual: $(atual)"; echo "serviço: $(systemctl is-active prox-kiox.service 2>/dev/null)" ;;
    window|kiosk)
        [ "$EUID" -eq 0 ] || { echo "ERRO: precisa de root" >&2; exit 1; }
        printf '# Modo do Prox-Kiox: window (janela com abas) ou kiosk (ecrã inteiro)\nPROX_KIOX_MODE=%s\n' "$1" > "$CONF"
        echo "modo -> $1"
        systemctl restart prox-kiox.service && echo "serviço reiniciado"
        ;;
    *) echo "uso: prox-kiox-mode [window|kiosk|status]" >&2; exit 1 ;;
esac
MODE

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

touch "$LOG"
# Escreve sempre: este instalador é explícito quanto ao modo (janela).
printf '# Modo do Prox-Kiox: window (janela com abas) ou kiosk (ecrã inteiro)\nPROX_KIOX_MODE=%s\n' "$MODE" > "$CONF"

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
pgrep -x cage >/dev/null && echo "cage: a correr" || echo "cage: parado"
pgrep -x firefox-esr >/dev/null && echo "firefox-esr: a correr" || echo "firefox-esr: parado"
echo "modo: $MODE  (trocar: prox-kiox-mode kiosk)"
echo "log: $LOG"
