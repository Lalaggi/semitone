#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "=== Building Flatpak bundle ==="
flatpak-builder --force-clean --user --install-deps-from=flathub flatpak-build pkgs/flatpak/org.codeberg.el1lovescomputers.semitone.json
flatpak build-export flatpak-repo flatpak-build
flatpak build-bundle flatpak-repo flatpak-downloads/semitone.flatpak org.codeberg.el1lovescomputers.semitone

echo "=== Building and installing with ninja ==="
meson setup build --buildtype=release --prefix=/usr
ninja -C build
sudo ninja -C build install || { echo "Install failed - try running manually: sudo ninja -C build install"; exit 1; }

echo "=== Done ==="
echo "Flatpak bundle saved to flatpak-downloads/semitone.flatpak"
