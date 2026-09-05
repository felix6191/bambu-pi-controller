#!/bin/bash -e
# pi-gen Stage: Bambu Pi Controller ins Image einbetten.
# Läuft auf dem Build-Host, ROOTFS_DIR zeigt aufs Ziel-Image.
REPO_TARBALL="$(dirname "$0")/../bambu-repo.tar.gz"
install -d "${ROOTFS_DIR}/opt/bambu-pi-controller"
tar -xzf "$REPO_TARBALL" -C "${ROOTFS_DIR}/opt/bambu-pi-controller"
install -m 644 "${ROOTFS_DIR}/opt/bambu-pi-controller/pi_image/stage-bambu/00-firstboot/files/bambu-firstboot.service" \
  "${ROOTFS_DIR}/etc/systemd/system/bambu-firstboot.service"
install -m 644 "${ROOTFS_DIR}/opt/bambu-pi-controller/pi_image/stage-bambu/00-firstboot/files/bambu-setup-ap.service" \
  "${ROOTFS_DIR}/etc/systemd/system/bambu-setup-ap.service"
on_chroot <<'EOF'
systemctl enable bambu-firstboot.service
mkdir -p /var/lib
echo "Bambu Pi Controller Image — Ersteinrichtung läuft beim ersten Start."
EOF
