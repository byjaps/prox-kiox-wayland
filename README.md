# Prox-Kiox (Wayland)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Proxmox VE](https://img.shields.io/badge/Platform-Proxmox%20VE%207--9-E57000.svg)](https://www.proxmox.com)
[![Renderer: cage/Wayland](https://img.shields.io/badge/Renderer-cage%20%2F%20Wayland-4A90D9.svg)](https://github.com/cage-kiosk/cage)
[![Status: tested on 3-node cluster](https://img.shields.io/badge/Status-tested%20on%203--node%20cluster-brightgreen.svg)](#verified-behaviour)

Turn a Proxmox VE node's local display into a **kiosk showing the PVE web UI**
(`https://127.0.0.1:8006`) — and keep it working after kernel upgrades.

## Why this exists

If you lose remote access because of a configuration mistake or a network
outage, this is the fallback that still works: the node's own display gives you
the PVE UI without SSH, VPN or a second machine.

And if your mini-rack has a screen, it turns that screen into a graphical
environment for the cluster — no extra hardware, no VM, no container and no GPU
passthrough.

Two modes, your choice at install time and switchable in one command:

| Mode | Command | What you get |
|---|---|---|
| `window` (default) | `./install.sh --window` | Firefox drawn as a normal window: tab bar, address bar and menus visible inside `cage`, so `Ctrl+T` opens the router, Home Assistant or anything else on the LAN. `cage` still gives that one window the whole output. |
| `kiosk` | `./install.sh --kiosk` | Classic full-screen kiosk (`--kiosk`): no bars, no menus, only the PVE UI. Nothing to click away by accident. |

Switch on a running node without reinstalling:

```bash
prox-kiox-mode kiosk     # full screen
prox-kiox-mode window    # tabs back
prox-kiox-mode           # which mode am I in?
```

This is a re-implementation of the idea behind
[LegitKnots/Prox-Kiox](https://github.com/LegitKnots/Prox-Kiox) (MIT), with two
differences that matter in practice:

1. **Wayland instead of X11.** The original uses `startx` + `openbox` +
   `firefox --kiosk`. Current PVE kernels boot with `lockdown=integrity`, and in
   that mode Xorg cannot open the legacy VGA I/O ports:

   ```
   xf86EnableIO: failed to enable I/O ports 0000-03ff (Operation not permitted)
   xinit: connection to X server lost
   ```

   That is why X11 kiosks "silently die after an update". The usual workaround is
   `lockdown=none` on the kernel command line — i.e. weakening the kernel on every
   node. This project avoids X entirely: [`cage`](https://github.com/cage-kiosk/cage)
   is a single-app Wayland compositor that draws through KMS/DRM, needs no I/O
   ports, and therefore runs **with lockdown integrity on**.

2. **Autostart that is safe on headless nodes.** A cluster usually has one monitor
   and several nodes. A naive autostart blocks or spams restarts on the nodes with
   no display. Here the unit is skipped unless a DRM connector reports
   `connected`, and a one-minute guard follows the HDMI cable: the node that gains
   the cable starts the kiosk, the one that loses it stops.

## What it does

| Component | Role |
|---|---|
| `prox-kiox.service` | Runs `cage` + `firefox-esr` over `https://127.0.0.1:8006`, in the mode set by `/etc/default/prox-kiox` (`--new-window` or `--kiosk`). `Type=simple`, `Restart=always`, `RestartSec=10`. |
| `prox-kiox-mode` | `window` / `kiosk` / `status`: writes `/etc/default/prox-kiox` and restarts the service. |
| `install-kiosk.sh` / `install-window.sh` | Standalone installers, one per version, with an embedded `--uninstall`. |
| `install.sh` | Same thing in one script, driven by `--kiosk` / `--window` (for a git clone). |
| `prox-kiox-has-display` | Exit 0 if any `/sys/class/drm/cardN-*/status` is `connected`. Used as `ExecCondition`. |
| `prox-kiox-guard` + timer | Every minute: start the kiosk if a monitor is attached and it is down, stop it if the monitor went away. |
| `prox-kiox-idle` | Optional. With `PROX_KIOX_IDLE` set to a number of seconds it blanks the monitor over DDC/CI and wakes it on the first key or mouse move. Default `0`: never blank, the screen stays on. |
| `prox-kiox-refresh` + timer | Every 15 min: if the PVE ticket has less than 20 min left, restart the service — that renews the cookie and reloads the page, so the kiosk stays logged in past the 2 h ticket lifetime. |
| `user.js` | Firefox prefs for the kiosk profile: no session restore, no telemetry, no self-update (ESR comes from apt). |

Behaviour:

- **Monitor attached at boot** → kiosk starts with `multi-user.target`.
- **No monitor** → unit result is `exec-condition`, `inactive`; boot is never
  delayed and the text console on `tty1` is untouched.
- **Cable moved to another node** → within ~60 s the old node stops and the new one
  starts, no SSH needed.
- **Firefox or cage crashes** → systemd restarts it in ~10 s.
- **Screen idle (opt-in)** → by default the screen stays on. To let it blank
  after 5 minutes, add `PROX_KIOX_IDLE=300` to `/etc/default/prox-kiox` and
  restart the service (`0` or `off` disables it again). It wakes on the first
  key or mouse movement. DDC/CI is used because `cage` does not implement
  `wlr-output-power-management` (`wlopm` does not work here); without a
  DDC-capable display the helper exits silently.
- **Long uptime** → the PVE ticket lasts 2 h. The refresh timer renews it before
  it expires, so the kiosk does not fall back to the login form.
- **Kernel upgrade** → nothing to re-patch: there is no X server and no kernel
  command-line change. `cage` and `firefox-esr` come from Debian and are updated
  by normal `apt` upgrades.

## Install — pick one of two versions

Each version is a **single self-contained script**: download it and run it as
root. No `git clone`, no companion folder, nothing to keep in sync.

### Version A — full-screen kiosk

```bash
wget -O install-kiosk.sh https://raw.githubusercontent.com/byjaps/prox-kiox-wayland/main/install-kiosk.sh
chmod +x install-kiosk.sh && ./install-kiosk.sh
```

Firefox runs with `--kiosk`: no tab bar, no address bar, no menus. Only the PVE
UI. Nothing to click away by accident — best for an unattended screen.

### Version B — Firefox window (tabs available)

```bash
wget -O install-window.sh https://raw.githubusercontent.com/byjaps/prox-kiox-wayland/main/install-window.sh
chmod +x install-window.sh && ./install-window.sh
```

Firefox runs with `--new-window`: the tab bar, address bar and menus are visible,
so `Ctrl+T` opens the router, Home Assistant or anything else on the LAN. `cage`
still gives that single window the whole output.

### Either version, switched later without reinstalling

```bash
prox-kiox-mode kiosk     # full screen
prox-kiox-mode window    # tabs back
prox-kiox-mode           # which mode am I in?
```

Both scripts are idempotent and re-runnable. Each one writes its own mode
explicitly, so `./install-kiosk.sh` always ends in kiosk and `./install-window.sh`
always ends in window. To remove everything: `./install-kiosk.sh --uninstall`
(or the window script — the cleanup is the same).

The repo also keeps the original two-in-one `install.sh` (`./install.sh --window`
/ `--kiosk`, with no flag keeping the mode already configured) for anyone who
prefers cloning the repo and running it from the working tree.

`install.sh` is idempotent: it installs `cage` + `firefox-esr`, copies the
binaries to `/usr/local/bin`, the units to `/etc/systemd/system`, writes
`/etc/default/prox-kiox` with the chosen mode, writes `user.js` into
`/root/.mozilla/firefox/*.default-esr`, then enables `prox-kiox.service` and
`prox-kiox-guard.timer`. Re-running it without a flag never changes the mode of
an already configured node.

Then, once, on the node that has the monitor: let Firefox open, accept the PVE
self-signed certificate and log in with **Remember me** ticked. The profile keeps
both, so later boots go straight to the dashboard. (PVE's generated certificate
already includes `IP:127.0.0.1` in its SAN; `security.enterprise_roots.enabled` is
set in `user.js`, so a local CA can be trusted system-wide if you prefer that to a
manual exception.)

Log: `/var/log/prox-kiox.log`.

## Uninstall

```bash
./install-kiosk.sh --uninstall    # standalone scripts: same cleanup in both
# or, from a clone:
./uninstall.sh                    # stops/disables the units, removes binaries and units
```

It leaves `cage`/`firefox-esr` installed (they are harmless) and keeps the log.

## Verified behaviour

Measured on a 3-node Proxmox VE 9.2 cluster (kernel 7.0.14, `lockdown=integrity`
on all nodes), one shared 1366×768 monitor:

- Node with the monitor: `systemctl is-active prox-kiox` → `active`, `pgrep -x
  cage` and `pgrep -x firefox-esr` present, the PVE dashboard rendered with tab bar,
  address bar and menus visible (verified with `grim` screenshots, no X involved),
  and `cage` holding the `/dev/input/event*` devices of the USB keyboard/touchpad —
  so `Ctrl+T` and clicking tabs work.
- Two headless nodes: `Result=exec-condition`, `inactive`, `getty@tty1` still
  active.
- `kill -9` on Firefox → back within ~10 s.
- Both modes on the same node, switched with `prox-kiox-mode`: `kiosk` renders the
  PVE UI with no bars at all; `window` brings back the tab bar, and a synthetic
  `Ctrl+T` (`wtype`) opens a second tab inside the single `cage` window.
- **Cold boot**: node rebooted, returned in 113 s, all guests up, kiosk running
  with `NRestarts=0` and the PVE dashboard on screen (session restored).
- Kernel stayed at `root=ZFS=... boot=zfs`: **no `lockdown=none`**.

## Notes and gotchas

- `cage` on Debian **hard-depends on `xwayland`**. Don't try to remove X packages
  with `apt-get remove xwayland ...` unless you mean to remove `cage` too (that is
  exactly how the kiosk disappears). Xwayland is inert when nothing speaks X11.
- Do not run `apt-get autoremove` on a PVE node to clean up X leftovers — on a
  typical node it proposes removing **old kernels**. Remove packages explicitly.
- `getty@tty1` is stopped **inside the wrapper**, not via `Conflicts=` in the unit:
  a `Conflicts` is applied when the job is queued, even if `ExecCondition` then
  fails, and it would kill the text console on headless nodes.
- `-s` in `cage -s` allows VT switching, so `Alt+F2` still gives you a console.
- If the HDMI link is not up yet at 30 s after boot, the guard timer starts the
  kiosk on its next tick — the autostart does not depend on EDID timing.
- **Optional auto-login (token + ticket).** PVE 9 does not accept an API token in
  the login form, and its web client does not keep a session across browser
  restarts. `tools/setup_autologin.sh` (run once, as root, on the node) creates a
  dedicated `kiosk@pve` user with a non-expiring API token and seeds the Firefox
  profile with `ProxmoxUser` (token) and `GuiCap` (capabilities) in `localStorage`.
  `files/prox-kiox-login` runs before each kiosk start, renews the 2 h
  `PVEAuthCookie` in `cookies.sqlite` and leaves the dashboard logged in without
  a single click. The cookie is written as a **non-HttpOnly** cookie: the PVE web
  client reads it from JavaScript to decide whether the session is alive, so an
  HttpOnly row is accepted by the API but still shows the login form. A refresh
  timer renews the ticket every 15 min when less than 20 min are left, so the
  session survives past the 2 h lifetime. Remove it all with `pveum user token
  remove kiosk@pve panel && pveum user delete kiosk@pve && rm -rf /etc/prox-kiox
  /usr/local/bin/prox-kiox-login`.
  **Security:** the token is as powerful as the role you give it, and anyone with
  physical access to the monitor gets that power; the secret sits in
  `/etc/prox-kiox` (mode 700/600) and the password only exists to fetch the
  capabilities once. Prefer a narrower role than `PVEAdmin` if the screen is in a
  shared room.
- The kiosk talks only to `127.0.0.1:8006`; no network egress, no telemetry.
- Tabs are **not** restored after a restart (the profile has session restore off,
  so a crash never pops a "restore session" dialog). If you want the tab set to come
  back, set `user_pref("browser.startup.page", 3);` in `user.js`.

## Credits

- Idea and original X11 script: [LegitKnots/Prox-Kiox](https://github.com/LegitKnots/Prox-Kiox) (MIT).
- [cage](https://github.com/cage-kiosk/cage) — the single-app Wayland kiosk compositor.

## License

MIT — see [LICENSE](LICENSE).
