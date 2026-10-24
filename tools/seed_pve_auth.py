#!/usr/bin/env python3
"""Semeia o localStorage do perfil do Firefox para a PVE abrir já autenticada.

Como funciona (e porque é que um token sozinho não bastava): o cliente web da PVE
lê `ProxmoxUser` do localStorage e aceita `storedAuth.token` como autenticação
(cabeçalho `Authorization: PVEAPIToken=...`), mas ao arrancar também precisa do
objeto `cap` (capacidades) que só vem de um login verdadeiro — sem ele o
`pvemanagerlib.js` rebenta com `caps.mapping is undefined` e o painel fica vazio.
Por isso juntamos:
  * `token`  — token API sem expiração (a sessão não morre às 2 h)
  * `cap`    — capacidades de um login real (para a UI saber o que mostrar)
O ticket/cookie de 2 h deixa de ser necessário.

Uso (no nó, com o Firefox a correr com --marionette):
    python3 seed_pve_auth.py --user kiosk@pve --token-id panel \
        --pass-file /etc/prox-kiox/kiosk-pass --token-file /etc/prox-kiox/kiosk-token
    python3 seed_pve_auth.py --check

Protocolo Marionette: TCP 127.0.0.1:2828, mensagens "<len>:<json>".
"""
import argparse
import json
import socket
import ssl
import time
import urllib.parse
import urllib.request

BASE = "https://127.0.0.1:8006"
PORT = 2828


class Marionette:
    def __init__(self, host="127.0.0.1", port=PORT, timeout=25):
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.create_connection((host, port), timeout=5)
                break
            except OSError:
                if time.time() > deadline:
                    raise SystemExit("ERRO: Marionette nao respondeu em %s:%s" % (host, port))
                time.sleep(0.5)
        self.sock.settimeout(30)
        self.buf = b""
        self._read_msg()
        self.msg_id = 0

    def _read_msg(self):
        while b":" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise SystemExit("ERRO: ligacao Marionette fechada")
            self.buf += chunk
        length, rest = self.buf.split(b":", 1)
        length = int(length)
        while len(rest) < length:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise SystemExit("ERRO: ligacao Marionette fechada a meio")
            rest += chunk
        payload, self.buf = rest[:length], rest[length:]
        return json.loads(payload.decode())

    def cmd(self, name, params=None):
        self.msg_id += 1
        msg = json.dumps([0, self.msg_id, name, params or {}]).encode()
        self.sock.sendall(str(len(msg)).encode() + b":" + msg)
        while True:
            reply = self._read_msg()
            if isinstance(reply, list) and len(reply) >= 4 and reply[1] == self.msg_id:
                if reply[2]:
                    raise SystemExit("ERRO Marionette %s: %s" % (name, reply[2]))
                return reply[3]

    def new_session(self):
        return self.cmd("WebDriver:NewSession", {"capabilities": {}}).get("sessionId")

    def script(self, code, args=None):
        return self.cmd("WebDriver:ExecuteScript",
                        {"script": code, "args": args or [], "scriptTimeout": 20000})


def ler(caminho):
    with open(caminho) as fh:
        return fh.read().strip()


def login_ticket(user, password):
    data = urllib.parse.urlencode({"username": user, "password": password}).encode()
    # Verificação TLS a sério: usamos a CA do próprio cluster (/etc/pve) e o
    # certificado do nó inclui IP:127.0.0.1 no SAN. Só se a CA não existir (nó
    # acabado de instalar, antes de o pvecm criar /etc/pve) é que não validamos —
    # e mesmo aí o pedido vai para 127.0.0.1, dentro da própria máquina.
    try:
        ctx = ssl.create_default_context(cafile="/etc/pve/pve-root-ca.pem")
    except (OSError, ssl.SSLError):
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    req = urllib.request.Request(BASE + "/api2/json/access/ticket", data=data)
    with urllib.request.urlopen(req, context=ctx, timeout=20) as r:
        return json.load(r)["data"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default="kiosk@pve")
    ap.add_argument("--token-id", default="panel")
    ap.add_argument("--pass-file", default="/etc/prox-kiox/kiosk-pass")
    ap.add_argument("--token-file", default="/etc/prox-kiox/kiosk-token")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    m = Marionette()
    m.new_session()

    if args.check:
        got = m.script("return window.localStorage.getItem('ProxmoxUser');")
        print("ProxmoxUser:", (got.get("value") or "(vazio)"))
        return

    password = ler(args.pass_file)
    token_secret = ler(args.token_file)
    userid_token = "%s!%s" % (args.user, args.token_id)

    ticket = login_ticket(args.user, password)
    cap = ticket.get("cap") or {}
    if not cap:
        raise SystemExit("ERRO: o login nao devolveu 'cap' (senha errada?)")
    print("login ok; capabilities com %d chaves" % len(cap))

    auth = {
        "username": userid_token,
        "cap": cap,
        "CSRFPreventionToken": ticket.get("CSRFPreventionToken", ""),
        "token": "PVEAPIToken=%s=%s" % (userid_token, token_secret),
    }

    m.cmd("WebDriver:Navigate", {"url": BASE})
    time.sleep(3)
    origin = m.script("return window.location.origin;").get("value") or ""
    if "127.0.0.1:8006" not in origin:
        raise SystemExit("ERRO: a pagina aberta nao e a PVE (%r)" % origin)

    payload = json.dumps(auth)
    res = m.script(
        "window.localStorage.setItem('ProxmoxUser', arguments[0]);"
        "return window.localStorage.getItem('ProxmoxUser');",
        [payload],
    )
    value = res.get("value") or ""
    print("gravado no localStorage (ProxmoxUser): %d bytes" % len(value))

    # As capacidades da UI vivem à parte: o PVE.StateProvider guarda-as no
    # localStorage como 'GuiCap' e, se faltarem, usa um objeto por omissão sem
    # 'mapping' — e o pvemanagerlib.js rebenta com "caps.mapping is undefined",
    # deixando o painel principal vazio. Grava-se pelo próprio provider para
    # ficar no formato que ele espera.
    res = m.script(
        "if (typeof Ext === 'undefined' || !Ext.state || !Ext.state.Manager)"
        " return 'sem Ext nesta pagina';"
        "Ext.state.Manager.set('GuiCap', JSON.parse(arguments[0]));"
        "return 'GuiCap gravado';",
        [json.dumps(cap)],
    )
    print("caps:", res.get("value"))

    m.cmd("WebDriver:Navigate", {"url": BASE})
    time.sleep(6)
    st = m.script(
        "return JSON.stringify({authOK: !!(window.Proxmox && Proxmox.Utils &&"
        " Proxmox.Utils.authOK && Proxmox.Utils.authOK()),"
        " pods: document.querySelectorAll('.x-panel').length,"
        " texto: (document.body.innerText || '').replace(/\\s+/g,' ').slice(0,180)});"
    )
    print("estado apos reload:", st.get("value"))
    print("Fecha o Firefox e arranca o servico normal.")


if __name__ == "__main__":
    main()
