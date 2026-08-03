#!/bin/bash
set -e

cd "$(dirname "$0")"

if ! ls /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null; then
  echo "Installing qemu-user-static-binfmt for aarch64 cross-compilation..."
  paru -S --noconfirm qemu-user-static-binfmt
fi

echo "=== Building Flatpak x86-64 bundle ==="
flatpak-builder --force-clean --user --install-deps-from=flathub --arch=x86_64 flatpak-build-x64 pkgs/flatpak/com.github.lalaggi.semitone.json
flatpak build-export flatpak-repo-x64 flatpak-build-x64
flatpak build-bundle flatpak-repo-x64 flatpak-downloads/Semitone-x86-64.flatpak com.github.lalaggi.semitone --arch=x86_64
rm -rf flatpak-build-x64 flatpak-repo-x64

echo "=== Building Flatpak arm64 bundle ==="
if flatpak-builder --force-clean --user --install-deps-from=flathub --arch=aarch64 flatpak-build-arm64 pkgs/flatpak/com.github.lalaggi.semitone.json; then
  flatpak build-export flatpak-repo-arm64 flatpak-build-arm64
  flatpak build-bundle flatpak-repo-arm64 flatpak-downloads/Semitone-arm64.flatpak com.github.lalaggi.semitone --arch=aarch64
  rm -rf flatpak-build-arm64 flatpak-repo-arm64
else
  echo "Skipping arm64 build (requires aarch64 host or cross-compilation setup)"
  rm -rf flatpak-build-arm64 flatpak-repo-arm64
fi

echo "=== Building and installing with ninja ==="
meson setup build --buildtype=release --prefix=/usr
ninja -C build
sudo ninja -C build install || {
  echo "Install failed - try running manually: sudo ninja -C build install"
  exit 1
}

echo "=== Done ==="
echo "Flatpak bundles saved to flatpak-downloads/"
echo "Download from: https://github.com/Lalaggi/Semitone/tree/main/flatpak-downloads/"
