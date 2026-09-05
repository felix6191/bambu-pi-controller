#!/bin/bash -e
# pi-gen Stage-Vorbereitung: Repo als Tarball einbetten (Code ist im Image,
# kein Git zur Laufzeit nötig). Erzeugt stage-bambu/bambu-repo.tar.gz.
cd "$(dirname "$0")/../.."
tar --exclude='.git' --exclude='__pycache__' --exclude='.DS_Store' \
  --exclude='pi_image/stage-bambu/bambu-repo.tar.gz' \
  -czf pi_image/stage-bambu/bambu-repo.tar.gz .
echo "Repo-Tarball: $(du -h pi_image/stage-bambu/bambu-repo.tar.gz | cut -f1)"
