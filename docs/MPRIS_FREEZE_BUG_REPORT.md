# Semitone MPRIS Hang — Cascading Freeze Report

Date: 2026-10-14
Reporter: elilovescomputers (via debug session)
Scope: Semitone acting as MPRIS server hanging, causing Waybar + other D-Bus clients to appear frozen. `pkill -9 semitone` instantly unfreezes everything.

## Environment

- OS: EliArch (Arch-based, CachyOS kernel 7.2.9-2-cachyos)
- Compositor: Hyprland 0.56.2 (configProvider: lua), Wayland only
- GPU: NVIDIA GA106 RTX 3060 LHR, driver 615.78.08 (nvidia-open-dkms), Xwayland running
- Bar: waybar-git 0.15.0.r1085
- MPRIS multiplexer: playerctld (playerctl) running as user service
- Other players present: Zen Browser (`org.mpris.MediaPlayer2.firefox.instance_*`), Semitone
- Portals: xdg-desktop-portal 1.22.1 + -hyprland 1.4.1 + -gtk 1.15.3, `hyprland-portals.conf: default=hyprland;gtk` (healthy)

## Symptoms

1. Waybar frozen / not updating. No crash, no coredump, just stuck.
2. Semitone window present (Hyprland client `xyz.lalaggi.semitone`, pid 2739 at time of capture) but unresponsive — playing "POKÉDANCE" video title, likely still rendering but main loop not answering IPC.
3. GTK apps in general *appeared* broken, but on direct test `nautilus --new-window`, `pavucontrol`, `gnome-calculator` all launched fine. So this was NOT a system-wide GTK/GSK failure.
4. `pkill -9 semitone` fixed everything instantly.

## Key Log Evidence (do not lose)

```
playerctld[1575]: could not update player position for player
  'org.mpris.MediaPlayer2.xyz.lalaggi.semitone': Timeout was reached
```

```
at-spi2-registryd[1468]: Disabling unresponsive app with pid 1268
at-spi2-registryd[1468]: Disabling unresponsive app with pid 163283
... (repeated for waybar PIDs 165912, 170732, 170868)
```

```
steam[1318]: (steam:2038): libappindicator-WARNING **:
  Unable to connect to the Notification Watcher: Timeout was reached
```

After kill, `busctl --user list | grep mpris` showed:

- `org.mpris.MediaPlayer2.firefox.instance_1_155` → owned (zen-bin, healthy)
- `org.mpris.MediaPlayer2.playerctld` → owned (playerctld, healthy)
- `xyz.lalaggi.semitone` / `org.mpris.MediaPlayer2.xyz.lalaggi.semitone` → activatable only, no owner (dead, as expected)

Before kill, Semitone owned its `org.mpris.MediaPlayer2.*` name (pid 2739).

Waybar config relevant snippet (`~/.config/waybar/config.jsonc`):

```json
"mpris": {
    "format": "♪ {title} — {artist}",
    "max-length": 35,
    "on-click": "setsid -f ~/.local/bin/Mediaplayer.py",
    "on-click-right": "playerctl play-pause"
}
```

Note: no `"player"` or `"ignored-players"` filter — so Waybar tracks ALL MPRIS players, including a hung Semitone. `Mediaplayer.py` shells out to `playerctl` with a 2s timeout per call.

## Mechanism (for fixing agent)

This is classic synchronous D-Bus blocking, not a GTK renderer bug:

- D-Bus method calls block the caller until the callee replies or times out (default ~25s, playerctl/playerctld use shorter timeouts but still seconds).
- If Semitone's main loop deadlocks, its MPRIS handlers (`Position`, `Metadata`, `PlaybackStatus`, `PropertiesChanged`) never reply.
- `playerctld` polls `Position` roughly every second for every player → it logs Timeout and backs up.
- Waybar `mpris` module polls the same properties with no player filter → its update thread blocks → whole bar looks frozen.
- Same pattern explains at-spi and libappindicator timeouts: any client doing a sync call to the hung app stalls.
- The session bus itself (dbus-broker) is fine. Killing Semitone removes the bus name, so pending callers get `NameHasNoOwner` immediately instead of waiting out the timeout. Hence "instant fix".

This is why one app can "inhibit other GTK apps" — it doesn't break GTK, it starves every client that talks to it over D-Bus.

## What This Is NOT

- NOT `GSK_RENDERER` / Vulkan vs `ngl`/`gl`. That workaround (DeepSeek suggestion) is for NVIDIA + GTK4 global freezes. Disproven here because other GTK4/libadwaita apps (Nautilus, Calculator) worked fine during the freeze with no renderer override set (`printenv | grep GSK` was empty).
- NOT `xdg-desktop-portal` config. Portal Settings (`busctl get-property org.freedesktop.portal.Desktop ... Settings version` → `u 2`) answered instantly. `default=hyprland;gtk` is correct.
- NOT Waybar config syntax. `waybar -l debug` showed healthy startup, tray host with 3 SNI items, no errors.
- NOT memory pressure. `free -h`: 31Gi total, 9.5Gi used, swap mostly free. No coredumps.

## Reproduction Hints

1. Launch Semitone, play audio, leave running.
2. Run Waybar with default `mpris` module (no filter) + `playerctld` running.
3. Wait for Semitone to wedge (trigger unknown — possibly GStreamer pipeline stall on seek/EOS/network file, not yet bisected).
4. Observe: `playerctl -l` hangs or is slow, `playerctl metadata` times out, Waybar freezes, `journalctl --user -b | grep -i "Timeout was reached"` shows MPRIS timeouts.
5. Confirm: `timeout 2 busctl --user get-property org.mpris.MediaPlayer2.xyz.lalaggi.semitone /org/mpris/MediaPlayer2 org.mpris.MediaPlayer2.Player Position` hangs; after `pkill -9 semitone` all clients recover instantly.

## Task For Fixing Agent

Investigate why Semitone's MPRIS server stops responding while the process stays alive:

1. Is the MPRIS `Position`/`Metadata` getter doing blocking work on the main loop (e.g. live GStreamer `query_position` instead of returning a cached value)?
2. Is `PropertiesChanged` emission flooding or deadlocking (e.g. emitting from non-main thread without marshalling)?
3. Is there a GStreamer bus/pipeline error path (EOS, state change, seek, missing file, network stall) that blocks the GTK main loop and therefore starves D-Bus dispatch?
4. Add defensive fixes: cached position, async/non-blocking MPRIS handlers, main-loop watchdog logging, and ensure `Bus.unown_name` / clean shutdown on hang.
5. Consider adding MPRIS conformance test: spam `Get Position/Metadata` while seeking / cutting network / playing broken files; assert all replies < 100ms.

Do NOT change Waybar/playerctld config as the fix — hardening Semitone's MPRIS server is the correct fix. Waybar filtering (`"ignored-players"`) is only a user-side workaround.
