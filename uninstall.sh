#!/bin/bash
# Reverte a instalação do Prox-Kiox (Wayland/cage) neste nó.
# Não remove os pacotes (firefox-esr pode ser útil e cage é inofensivo).
set -uo pipefail
[ "$EUID" -eq 0 ] || { echo "ERRO: correr como root" >&2; exit 1; }

systemctl disable --now prox-kiox-guard.timer 2>/dev/null
systemctl disable --now prox-kiox.service 2>/dev/null
rm -f /etc/systemd/system/prox-kiox.service \
      /etc/systemd/system/prox-kiox-guard.service \
      /etc/systemd/system/prox-kiox-guard.timer \
      /usr/local/bin/prox-kiox-wl \
      /usr/local/bin/prox-kiox-has-display \
      /usr/local/bin/prox-kiox-guard
systemctl daemon-reload
pkill -x firefox-esr 2>/dev/null
echo "Prox-Kiox (Wayland) removido. Log mantido em /var/log/prox-kiox.log"
