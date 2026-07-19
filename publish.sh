#!/bin/bash
# Build semitone + Velox into a single flatpak repo for self-hosting on Codeberg Pages.
# Target repo URL: https://el1lovescomputers.codeberg.page/flatpak-repo/repo/
#
# Usage:
#   ./publish.sh            # build x86_64, export into flatpak-repo/repo/
#
# Optional GPG signing:
#   The repo is signed by default with the key below; the public key lives at
#   flatpak-repo/flatpak-repo.pub.asc and is served alongside the repo.
#   To use a different key:  GPG_KEYID=KEYID ./publish.sh
# Users install with the public key:
#   flatpak remote-add --if-not-exists el1-flatpak \
#     --gpg-import=https://el1lovescomputers.codeberg.page/flatpak-repo/flatpak-repo.pub.asc \
#     https://el1lovescomputers.codeberg.page/flatpak-repo/repo/
set -e

cd "$(dirname "$0")"

ARCH="${ARCH:-x86_64}"
REPO_DIR="flatpak-repo/repo"
GPG_KEYID="${GPG_KEYID:-B1EAB7259FA1C8748F127216710BA1A16C99D05C}"
PUB_KEY="${PUB_KEY:-flatpak-repo/flatpak-repo.pub.asc}"

mkdir -p "$REPO_DIR"

build_and_export() {
    local manifest="$1"
    local name="$2"
    echo "=== Building $name ($manifest) ==="
    flatpak-builder --force-clean --user --install-deps-from=flathub \
        --arch="$ARCH" "flatpak-build-$name" "$manifest"
    flatpak build-export "$REPO_DIR" "flatpak-build-$name" "$ARCH"
    rm -rf "flatpak-build-$name"
}

# semitone: use the .json manifest (runtime 49)
build_and_export "pkgs/flatpak/org.codeberg.el1lovescomputers.semitone.json" "semitone"

# Velox
build_and_export "../Velox/pkgs/flatpak/org.codeberg.el1lovescomputers.velox.json" "velox"

# AriaGUI
build_and_export "pkgs/flatpak/org.codeberg.el1lovescomputers.ariagui.json" "ariagui"

# Streamline
build_and_export "../Streamline/pkgs/flatpak/org.codeberg.el1lovescomputers.streamline.json" "streamline"

# WayClicker (formerly linux-autoclicker)
build_and_export "../LinuxAutoclicker/pkgs/flatpak/org.codeberg.el1lovescomputers.wayclicker.json" "wayclicker"

echo "=== Finalizing repo ==="
if [ -n "$GPG_KEYID" ]; then
    echo "Signing repo with GPG key ${GPG_KEYID}"
    flatpak build-update-repo --gpg-sign="$GPG_KEYID" "$REPO_DIR"
else
    flatpak build-update-repo "$REPO_DIR"
fi

echo "=== Done ==="
echo "Push the contents of flatpak-repo/ to the codeberg flatpak-repo repo."
echo "Install command for users:"
echo "  flatpak remote-add --if-not-exists el1-flatpak \\"
echo "    --gpg-import=https://el1lovescomputers.codeberg.page/flatpak-repo/flatpak-repo.pub.asc \\"
echo "    https://el1lovescomputers.codeberg.page/flatpak-repo/repo/"
echo "  flatpak install el1-flatpak org.codeberg.el1lovescomputers.semitone"
echo "  flatpak install el1-flatpak org.codeberg.el1lovescomputers.velox"
echo "  flatpak install el1-flatpak org.codeberg.el1lovescomputers.ariagui"
echo "  flatpak install el1-flatpak org.codeberg.el1lovescomputers.streamline"
echo "  flatpak install el1-flatpak org.codeberg.el1lovescomputers.wayclicker"
