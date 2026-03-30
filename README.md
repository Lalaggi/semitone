# Semitone

A lightweight GTK4 music player written in Vala.

**Source:** [codeberg.org/el1lovescomputers/semitone](https://codeberg.org/el1lovescomputers/semitone)

## Features

- **Playback** — Shuffle and repeat modes, sleep timer, MPRIS media controls
- **Library** — Fast scanning of large collections, groups and sorts by album/artist/title, full-text search
- **Queue** — Queue viewer with cover art, drag to reorder
- **Playlists** — Create, edit, and manage playlists, import/export M3U files
- **Lyrics** — Synced lyrics with word-by-word highlighting, auto-scroll, click-to-seek (LRCLib support)
- **Visuals** — Gaussian blurred cover art background, follows system light/dark mode, adaptive layout for desktop/tablet/mobile, audio peak visualizer
- **Audio** — ReplayGain volume normalization, configurable audio sink
- **Formats** — Supports most audio formats via GStreamer (MP3, FLAC, OGG, OPUS, MP4, WAV, etc.)
- **Remote** — Samba and other remote protocols via GIO

## Installation

### Recommended: [gitpkg](https://codeberg.org/el1lovescomputers/gitpkg)

```bash
curl -fsSL "https://codeberg.org/el1lovescomputers/gitpkg/raw/branch/main/install.sh" | sh
gitpkg install el1lovescomputers/semitone --supplier "codeberg.org"
```

### From Source

Dependencies:

**Arch Linux:**
```bash
sudo pacman -S vala meson gtk4 libadwaita gstreamer gstreamer-plugins-base libsoup json-glib libxml2
```

**Debian/Ubuntu:**
```bash
sudo apt install vala meson libgtk-4-dev libadwaita-1-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libsoup-3.0-dev libjson-glib-dev libxml2-dev
```

**Fedora:**
```bash
sudo dnf install vala meson gtk4-devel libadwaita-devel gstreamer-devel gstreamer-plugins-base-devel libsoup-devel json-glib-devel libxml2-devel
```

Build and install:
```bash
git clone https://codeberg.org/el1lovescomputers/semitone
cd semitone
meson setup builddir --buildtype=release
ninja -C builddir install
```

## Reporting Issues

https://codeberg.org/el1lovescomputers/semitone/issues
