# Prox-Kiox (Wayland)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Proxmox VE](https://img.shields.io/badge/Platform-Proxmox%20VE%207--9-E57000.svg)](https://www.proxmox.com)
[![Renderer: cage/Wayland](https://img.shields.io/badge/Renderer-cage%20%2F%20Wayland-4A90D9.svg)](https://github.com/cage-kiosk/cage)
[![Status: tested on 3-node cluster](https://img.shields.io/badge/Status-tested%20on%203--node%20cluster-brightgreen.svg)](#verified-behaviour)

Turn a Proxmox VE node's local display into a **kiosk showing the PVE web UI**
(`https://127.0.0.1:8006`) — and keep it working after kernel upgrades.

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
| `prox-kiox.service` | Runs `cage` + `firefox-esr --kiosk https://127.0.0.1:8006`. `Type=simple`, `Restart=always`, `RestartSec=10`. |
| `prox-kiox-has-display` | Exit 0 if any `/sys/class/drm/cardN-*/status` is `connected`. Used as `ExecCondition`. |
| `prox-kiox-guard` + timer | Every minute: start the kiosk if a monitor is attached and it is down, stop it if the monitor went away. |
| `user.js` | Firefox prefs for a kiosk profile: no session restore, no telemetry, no self-update (ESR comes from apt). |

Behaviour:

- **Monitor attached at boot** → kiosk starts with `multi-user.target`.
- **No monitor** → unit result is `exec-condition`, `inactive`; boot is never
  delayed and the text console on `tty1` is untouched.
- **Cable moved to another node** → within ~60 s the old node stops and the new one
  starts, no SSH needed.
- **Firefox or cage crashes** → systemd restarts it in ~10 s.
- **Kernel upgrade** → nothing to re-patch: there is no X server and no kernel
  command-line change. `cage` and `firefox-esr` come from Debian and are updated
  by normal `apt` upgrades.

## Install

On each node, as root:

```bash
apt-get install -y git
git clone https://github.com/byjaps/prox-kiox-wayland.git
cd prox-kiox-wayland
./install.sh
```

`install.sh` is idempotent: it installs `cage` + `firefox-esr`, copies the
binaries to `/usr/local/bin`, the units to `/etc/systemd/system`, writes
`user.js` into `/root/.mozilla/firefox/*.default-esr`, then enables
`prox-kiox.service` and `prox-kiox-guard.timer`.

Then, once, on the node that has the monitor: let Firefox open, accept the PVE
self-signed certificate and log in with **Remember me** ticked. The profile keeps
both, so later boots go straight to the dashboard. (PVE's generated certificate
already includes `IP:127.0.0.1` in its SAN; `security.enterprise_roots.enabled` is
set in `user.js`, so a local CA can be trusted system-wide if you prefer that to a
manual exception.)

Log: `/var/log/prox-kiox.log`.

## Uninstall

```bash
./uninstall.sh     # stops/disables the units, removes binaries and units
```

It leaves `cage`/`firefox-esr` installed (they are harmless) and keeps the log.

## Verified behaviour

Measured on a 3-node Proxmox VE 9.2 cluster (kernel 7.0.14, `lockdown=integrity`
on all nodes), one shared 1366×768 monitor:

- Node with the monitor: `systemctl is-active prox-kiox` → `active`, `pgrep -x
  cage` and `pgrep -x firefox-esr` present, PVE login rendered (verified with
  `grim` screenshots, no X involved).
- Two headless nodes: `Result=exec-condition`, `inactive`, `getty@tty1` still
  active.
- `kill -9` on Firefox → back within ~10 s.
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
- Login uses the Firefox profile's saved session ("Remember me"). Scripted
  auto-login with a plaintext password is deliberately not implemented: it hands
  an unlocked PVE UI to anyone touching the screen and stores the password on the
  node.
- The kiosk talks only to `127.0.0.1:8006`; no network egress, no telemetry.

## Credits

- Idea and original X11 script: [LegitKnots/Prox-Kiox](https://github.com/LegitKnots/Prox-Kiox) (MIT).
- [cage](https://github.com/cage-kiosk/cage) — the single-app Wayland kiosk compositor.

## License

MIT — see [LICENSE](LICENSE).
