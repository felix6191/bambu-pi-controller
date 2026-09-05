#!/bin/bash
# Baut das flash-fertige Image mit pi-gen (offizieller Raspberry-Pi-Weg).
# Lokal: nur auf Linux mit Docker/root. Empfohlen: GitHub-Action
# (.github/workflows/build-image.yml) — das fertige .img liegt danach
# unter Releases als Download.
set -e
cd "$(dirname "$0")"
[[ -d pi-gen ]] || git clone --depth 1 https://github.com/RPi-Distro/pi-gen.git
bash stage-bambu/prerun.sh
cat > pi-gen/config <<EOF
IMG_NAME=bambu-controller
RELEASE=bookworm
DEPLOY_COMPRESSION=xz
STAGE_LIST="stage0 stage1 stage2 ./stage-bambu"
BAMBU_REPO_URL="https://github.com/felix6191/bambu-pi-controller.git"
EOF
cp -r stage-bambu pi-gen/stage-bambu
if command -v docker &>/dev/null; then
  echo "Baue per Docker (empfohlen, alle Deps inklusive)…"
  (cd pi-gen && sudo ./build-docker.sh)
else
  echo "Baue direkt (braucht alle pi-gen-Abhängigkeiten)…"
  (cd pi-gen && sudo ./build.sh)
fi
echo "Fertig: pi-gen/deploy/bambu-controller.img.xz"
echo "Flashen mit Raspberry Pi Imager → Eigenes Image wählen."
