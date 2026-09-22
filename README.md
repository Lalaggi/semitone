<img align="left" alt="Semitone" src="assets/app.svg" width="128" />

# Semitone

A lightweight GTK4/libadwaita music player for Linux, written in Vala. Semitone plays your local music collection with gapless GStreamer playback, synced (LRC) lyrics, a 6-band graphic equalizer, ReplayGain normalization, playlists, and MPRIS media controls — in a fast, adaptive GNOME-friendly interface for desktop, tablet, and mobile.

**Canonical source:** [gitlab.com/Lalaggi/semitone](https://gitlab.com/Lalaggi/semitone) · Mirrors on GitHub and Codeberg · **License:** GPL-3.0 — see [LICENSE](LICENSE)

> **Fork note:** Semitone is a fork of [Gapless](https://github.com/neithern/g4music) (formerly G4Music) by neithern, extended with synced lyrics, an in-app equalizer, and many other improvements. Upstream history is preserved where practical; see release notes in the AppStream metadata for inherited changes.

![Semitone main library view](screenshots/Semitone%20Main.png)

More in [SCREENSHOTS.md](SCREENSHOTS.md) · Install via [INSTALL.md](INSTALL.md)

## Features

- **Gapless playback** — gapless GStreamer playback (MP3, FLAC, OGG, Opus, M4A, WAV, …), Samba and other remote protocols via GIO
- **Library** — fast scanning of thousands of files with tag cache and low memory use, grouped/sorted by album/artist/title, full-text search, file-change monitoring
- **Queue** — editable, persistent play queue with cover art and drag-to-reorder, shuffle and repeat (none/all/one) modes
- **Playlists** — create, rename, edit, and delete playlists; M3U import/export; drag covers between playlists and other apps
- **Lyrics** — 13 providers (BetterLyrics, Unison, BiniLyrics, LRCLib, PaxSenix, NetEase, KuGou, MusicBrainz, SimpMusic, Megalobiz, LyricsPlus, Genius, Musixmatch), synced lyrics with word-by-word highlighting, click-to-seek, auto-scroll with resume delay, auto-select best match, LRC+ v3 multi-voice labels and per-voice colors, TTML import
- **Equalizer** — in-app 6-band graphic equalizer (62 Hz – 10 kHz, −24 dB to +12 dB), persisted per band in GSettings
- **Audio** — ReplayGain volume normalization (track/album), configurable GStreamer audio sink, audio peak visualizer with custom characters
- **Controls** — sleep timer (with finish-track option), MPRIS media controls, Discord Rich Presence, background playback, cover rotation, custom CSS, UI scale, and list density options
- **Visuals** — Gaussian-blurred cover-art background, follows system light/dark mode, adaptive layout for desktop/tablet/mobile with stable bottom-tab navigation (category buttons no longer jump between header and tabs at different window sizes), grid or list views

## Install

See [INSTALL.md](INSTALL.md) for Flatpak, [gitpkg](https://gitlab.com/Lalaggi/gitpkg), and from-source instructions with per-distro dependencies.

## Semitone vs Gapless / G4Music

Semitone is a fork of Gapless (formerly G4Music by neithern) for listeners who want more than minimal playback.
It keeps the upstream strengths — fast library scanning for large collections, gapless GStreamer playback,
ReplayGain, MPRIS, an audio peak visualizer, M3U playlist import/export, and an adaptive GTK4/libadwaita
interface — and adds what upstream lacks: word-by-word synced lyrics from 13 providers with click-to-seek
and LRC+ v3 multi-voice support, an in-app 6-band graphic equalizer, a sleep timer, Discord Rich Presence,
and a persistent editable queue. It also reworks navigation for accessibility and intuitiveness: upstream
moves the music-category buttons between bottom tabs, header shortcuts, and other placements depending on
window size, despite claiming GNOME HIG closeness — Semitone keeps them as stable bottom tabs. If you like
Gapless but miss lyrics, an EQ, or a UI that stays put, Semitone is the drop-in next step.

## Screenshots

See [SCREENSHOTS.md](SCREENSHOTS.md).

## Documentation

- Lyrics format specs: [docs/](docs/) (`LRCPLUS_SPEC.md`, `LRCPLUS_SPEC_V2.md`, `LRCPLUS_SPEC_V3.md`)
- AppStream release history: [data/app.metainfo.xml.in](data/app.metainfo.xml.in)

## Reporting issues

Please report bugs and feature requests on GitLab (the canonical forge; GitHub/Codeberg are read-only mirrors):

<https://gitlab.com/Lalaggi/semitone/-/issues>

## Keywords

gtk4 music player, libadwaita music player, vala music player, linux music player, gnome music app, gstreamer player, gapless playback, synced lyrics, lrc lyrics, word-by-word lyrics, replaygain, graphic equalizer, mpris, offline music player, lightweight music player, flathub alternative, g4music fork, gapless fork
