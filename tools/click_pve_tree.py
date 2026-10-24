#!/usr/bin/env python3
"""Diagnóstico: clica num nó da árvore da PVE (via Marionette) e mostra o texto do painel."""
import json
import sys
import time

sys.path.insert(0, "/root")
from seed_pve_auth import Marionette  # noqa: E402

alvo = sys.argv[1] if len(sys.argv) > 1 else "Datacenter"

m = Marionette()
m.new_session()

js = """
var alvo = arguments[0];
var els = Array.from(document.querySelectorAll('.x-tree-node-text, .x-grid-cell-inner'));
var hit = els.find(function (e) { return (e.textContent || '').trim() === alvo; });
if (!hit) return 'nao encontrado; candidatos: ' + els.slice(0, 12).map(function(e){return e.textContent.trim();}).join(' | ');
hit.click();
return 'clicado: ' + alvo;
"""
print(m.script(js, [alvo]).get("value"))
time.sleep(6)

out = m.script("""
return JSON.stringify({
  text: (document.body.innerText || '').replace(/\\s+/g,' ').slice(0, 700),
  panes: document.querySelectorAll('.x-panel').length
});
""")
print(json.dumps(json.loads(out.get("value") or "{}"), indent=1, ensure_ascii=False))
