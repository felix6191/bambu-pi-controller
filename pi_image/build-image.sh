#!/bin/bash
# Baut das flash-fertige Image mit pi-gen (offizieller Raspberry-Pi-Weg).
# Lokal: nur auf Linux mit Docker/root. Empfohlen: GitHub-Action
# (.github/workflows/build-image.yml) — das fertige .img liegt danach
# unter Releases als Download.
set -e
cd "$(dirname "$0")"
bash prepare-stage.sh
echo "Starte Build (dauert 20–60 Min)…"
if command -v docker &>/dev/null; then
  (cd pi-gen && sudo ./build-docker.sh -c ./config)
else
  (cd pi-gen && sudo ./build.sh -c ./config)
fi
echo "Fertig: pi-gen/deploy/bambu-controller*.img.xz"
echo "Flashen mit Raspberry Pi Imager → Eigenes Image wählen."
