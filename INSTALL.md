# Installing Semitone

## Flatpak (recommended for most users)

```bash
flatpak remote-add --if-not-exists lalaggi-flatpak https://flatpak.lalaggi.xyz/lalaggi-flatpak.flatpakrepo
flatpak install lalaggi-flatpak xyz.lalaggi.semitone
```

Run with:

```bash
flatpak run xyz.lalaggi.semitone
```

## gitpkg (recommended for source-based distros)

[gitpkg](https://gitlab.com/Lalaggi/gitpkg) builds and installs directly from the GitLab source:

```bash
gitpkg install Lalaggi/semitone --supplier gitlab.com
```

## From source

### Dependencies

You need Vala, Meson, GTK4, libadwaita, GStreamer (+ base plugins), libsoup3, json-glib, and libxml2.

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

**OpenSUSE Tumbleweed:**

```bash
sudo zypper install vala meson gtk4-devel libadwaita-devel gstreamer-devel gstreamer-plugins-base-devel libsoup3-devel json-glib-devel libxml2-devel
```

**Void Linux:**

```bash
sudo xbps-install vala meson gtk4-devel libadwaita-devel gstreamer1-devel gst-plugins-base1-devel libsoup3-devel json-glib-devel libxml2-devel
```

**Alpine:**

```bash
sudo apk add vala meson gtk4.0-dev libadwaita-dev gstreamer-dev gst-plugins-base-dev libsoup3-dev json-glib-dev libxml2-dev
```

GStreamer codec plugins (`gst-plugins-good/bad/ugly`) are recommended for full format coverage (MP3, M4A, etc.).

### Build and install

```bash
git clone https://gitlab.com/Lalaggi/semitone.git
cd semitone
meson setup build --buildtype=release --prefix=/usr
sudo ninja -C build install
```
