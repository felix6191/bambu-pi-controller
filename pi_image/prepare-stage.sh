#!/bin/bash -e
# Bereitet den pi-gen-Stage host-seitig vor: Repo-Tarball erzeugen und
# Stage nach pi-gen/ kopieren. Muss VOR build.sh/build-docker.sh laufen.
set -e
SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)"
PI_IMAGE="$SCRIPT_DIR"
REPO_ROOT="$(dirname "$PI_IMAGE")"
[[ -d "$PI_IMAGE/pi-gen" ]] || git -C "$PI_IMAGE" clone --depth 1 https://github.com/RPi-Distro/pi-gen.git
tar --exclude='.git' --exclude='__pycache__' --exclude='.DS_Store' \
  --exclude='pi_image/stage-bambu/bambu-repo.tar.gz' \
  --exclude='pi_image/pi-gen' --exclude='ios_app/build' \
  --exclude='*.xcuserdata' \
  -czf "$PI_IMAGE/stage-bambu/bambu-repo.tar.gz" -C "$REPO_ROOT" .
echo "Repo-Tarball: $(du -h "$PI_IMAGE/stage-bambu/bambu-repo.tar.gz" | cut -f1)"
rm -rf "$PI_IMAGE/pi-gen/stage-bambu"
cp -r "$PI_IMAGE/stage-bambu" "$PI_IMAGE/pi-gen/stage-bambu"
printf '%s\n' \
  'IMG_NAME=bambu-controller' \
  'RELEASE=bookworm' \
  'DEPLOY_COMPRESSION=xz' \
  'STAGE_LIST="stage0 stage1 stage2 ./stage-bambu"' \
  > "$PI_IMAGE/pi-gen/config"
echo "Stage bereit in pi-gen/stage-bambu"
