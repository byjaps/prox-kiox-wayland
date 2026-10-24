#!/usr/bin/env python3
"""Diagnóstico: erros de JS e estado de auth na UI da PVE (com Marionette ligado)."""
import json
import sys
import time

sys.path.insert(0, "/root")
from seed_pve_auth import Marionette  # noqa: E402


def main():
    m = Marionette()
    m.new_session()

    m.script("""
        window.__errs = [];
        window.addEventListener('error', function (e) {
            window.__errs.push('error: ' + (e.message || '') + ' @ ' + (e.filename || ''));
        });
        window.addEventListener('unhandledrejection', function (e) {
            window.__errs.push('rejection: ' + String(e.reason));
        });
        var oldErr = console.error;
        console.error = function () {
            window.__errs.push('console.error: ' + Array.prototype.join.call(arguments, ' '));
            return oldErr.apply(console, arguments);
        };
    """)

    m.cmd("WebDriver:Navigate", {"url": "https://127.0.0.1:8006"})
    time.sleep(10)

    out = m.script("""
        let st = {};
        st.user = (window.Proxmox && Proxmox.UserName) || '';
        st.csrf = (window.Proxmox && Proxmox.CSRFPreventionToken) ? 'presente' : 'vazio';
        st.authOK = !!(window.Proxmox && Proxmox.Utils && Proxmox.Utils.authOK && Proxmox.Utils.authOK());
        st.ls = (window.localStorage.getItem('ProxmoxUser') || '').slice(0, 40);
        st.errs = (window.__errs || []).slice(0, 15);
        st.panels = document.querySelectorAll('.x-panel').length;
        st.text = (document.body.innerText || '').replace(/\\s+/g, ' ').slice(0, 400);
        return JSON.stringify(st);
    """)
    print(json.dumps(json.loads(out.get("value") or "{}"), indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
