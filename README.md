<img align="left" alt="Project logo" src="data/icons/hicolor/scalable/apps/app.svg" />

# Semitone
Play your music elegantly.

Semitone is a lightweight music player written in GTK4/libadwaita, forked from [Gapless (G4Music)](https://gitlab.gnome.org/neithern/g4music) and grown into its own independent project.

**Source:** [codeberg.org/el1lovescomputers/semitone](https://codeberg.org/el1lovescomputers/semitone)

## Features
- Supports most music file types, Samba and any other remote protocols (via GIO and GStreamer)
- Fast loading and parsing of large music collections in seconds, with optional file monitoring
- Low memory usage even with large collections and embedded/external album art — no thumbnail cache required
- Groups and sorts by album/artist/title, with full-text search
- Fluent adaptive UI for desktop, tablet, and mobile
- Gaussian blurred cover art as background, follows GNOME light/dark mode
- Synced lyrics with word-by-word highlighting, auto-scroll, and click-to-seek (BetterLyrics, SimpMusic, LRCLib)
- Queue viewer with cover art
- Shuffle and repeat modes
- Sleep timer
- Playlist creation and editing, drag to reorder
- Drag and drop support
- Audio peak visualizer
- Gapless playback
- ReplayGain volume normalization
- Configurable audio sink
- MPRIS control

## Building

Written in Vala with few dependencies:

1. Clone the repository:
   ```bash
   git clone https://codeberg.org/el1lovescomputers/semitone
   cd semitone
   ```
2. Install dependencies: `vala`, `meson`, `gtk4-devel`, `libadwaita-devel`, `gstreamer-devel`, `gstreamer-plugins-base-devel`, `libsoup3-devel`, `json-glib-devel`, `libxml2-devel`
3. Build and install:
   ```bash
   meson setup builddir --buildtype=release
   sudo ninja -C builddir install
   ```

## FreeBSD Dependencies
```bash
pkg install vala meson libadwaita gstreamer1-plugins-all gettext gtk4 libsoup3 json-glib libxml2
```

## Reporting Issues
Please open issues at [codeberg.org/el1lovescomputers/semitone/issues](https://codeberg.org/el1lovescomputers/semitone/issues).
