<img align="left" alt="Semitone" src="assets/app.svg" width="128" />

# Semitone

A lightweight GTK4 music player written in Vala.

**Source:** [gitlab.com/Lalaggi/semitone](https://gitlab.com/Lalaggi/semitone)

## Features

- **Playback** — Shuffle and repeat modes, sleep timer, MPRIS media controls, Discord Rich Presence
- **Library** — Fast scanning of large collections, groups and sorts by album/artist/title, full-text search, file change monitoring
- **Queue** — Queue viewer with cover art, drag to reorder
- **Playlists** — Create, edit, and manage playlists, import/export M3U files
- **Lyrics** — 13 providers (BetterLyrics, Unison, BiniLyrics, LRCLib, PaxSenix, NetEase, KuGou, MusicBrainz, SimpMusic, Megalobiz, LyricsPlus (QQ, Deezer, and Musixmatch scraping. Community run so endpoints are often overloaded), Genius, Musixmatch), synced lyrics with word-by-word highlighting, auto-scroll + resume chip, click-to-seek, auto-select best match, LRC+ v2 multi-voice with pretty names (`display`/`voice` fallback `Elphaba`/`Glinda`/`Background`), configurable voice labels *None / Coded / Pretty (recommended)* and independent per-voice colors, duplicate filtering, TTML agent-name import
- **Visuals** — Gaussian blurred cover art background, follows system light/dark mode, adaptive layout for desktop/tablet/mobile, audio peak visualizer
- **Audio** — ReplayGain volume normalization (track/album), configurable audio sink
- **Formats** — Supports most audio formats via GStreamer (MP3, FLAC, OGG, OPUS, M4A, WAV, etc.)
- **Remote** — Samba and other remote protocols via GIO

## Dependencies

**Arch Linux:**

```bash
sudo pacman -S vala meson gtk4 libadwaita gstreamer gst-plugins-base libsoup3 json-glib libxml2
```

**Debian/Ubuntu:**

```bash
sudo apt install vala meson libgtk-4-dev libadwaita-1-dev libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libsoup-3.0-dev libjson-glib-dev libxml2-dev
```

**Fedora:**

```bash
sudo dnf install vala meson gtk4-devel libadwaita-devel gstreamer1-devel gstreamer1-plugins-base-devel libsoup3-devel json-glib-devel libxml2-devel
```

**OpenSUSE Tumbleweed**

```bash
sudo zypper install vala meson gtk4-devel libadwaita-devel gstreamer-devel gstreamer-plugins-base-devel libsoup3-devel json-glib-devel libxml2-devel
```

**Void Linux**

```bash
sudo xbps-install vala meson gtk4-devel libadwaita-devel gstreamer1-devel gst-plugins-base1-devel libsoup3-devel json-glib-devel libxml2-devel
```

**Alpine**

```bash
sudo apk add vala meson gtk4.0-dev libadwaita-dev gstreamer-dev gst-plugins-base-dev libsoup3-dev json-glib-dev libxml2-dev
```

## Installation

### Flatpak

```bash
flatpak remote-add --if-not-exists lalaggi-flatpak https://flatpak.lalaggi.xyz/lalaggi-flatpak.flatpakrepo
flatpak install lalaggi-flatpak xyz.lalaggi.semitone
```

### Recommended: [gitpkg](https://gitlab.com/Lalaggi/gitpkg)

```bash
gitpkg install Lalaggi/semitone --supplier gitlab.com
```

### From Source

```bash
git clone https://gitlab.com/Lalaggi/semitone.git
cd semitone
meson setup build --buildtype=release --prefix=/usr
sudo ninja -C build install
```

## Reporting Issues

<https://gitlab.com/Lalaggi/semitone/-/issues>

## License

GPL-3.0 — see [LICENSE](LICENSE).
