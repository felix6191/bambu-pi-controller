#!/bin/bash
# update.sh - Aktualisiert das Repository und deployed neu
# Auf dem Pi ausführen: sudo ./update.sh  (oder: sudo bambu update)
set -e

INSTALL_DIR="/opt/bambu-pi-controller"

echo "🔄 Bambu Pi Controller Update"
echo "============================="

# Zentrale, robuste Update-Logik: lädt die neuesten Dateien, rüstet Helfer +
# mDNS nach, korrigiert die /data-Rechte und baut inkl. Slicer neu.
exec bash "$INSTALL_DIR/install.sh" --update
