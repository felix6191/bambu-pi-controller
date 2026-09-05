#!/bin/bash
# Baut das flash-fertige Image mit pi-gen (offizieller Raspberry-Pi-Weg).
# CI (empfohlen): GitHub-Action (.github/workflows/build-image.yml) — das
# fertige .img liegt danach unter Releases als Download.
# Lokal: nur auf Linux (arm64) mit Docker + root.
set -e
cd "$(dirname "$0")"
bash prepare-stage.sh
echo "Starte Build (dauert 20–60 Min)…"
sudo docker run --privileged --rm \
  -v "$PWD/pi-gen:/pi-gen" -w /pi-gen \
  debian:bookworm bash -e -o pipefail -c "
    git config --global --add safe.directory /pi-gen &&
    apt-get update -qq &&
    apt-get install -y -qq git quilt parted coreutils qemu-user-static \
      qemu-user-binfmt debootstrap zerofree zip dosfstools e2fsprogs libcap2-bin \
      libarchive-tools grep rsync xz-utils curl xxd file kmod bc \
      gpg pigz arch-test binfmt-support ca-certificates fdisk &&
    ./build.sh
  "
echo "Fertig: pi-gen/deploy/*.img.xz"
echo "Flashen mit Raspberry Pi Imager → Eigenes Image wählen."
