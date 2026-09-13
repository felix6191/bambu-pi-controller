#!/bin/bash
# update.sh — Einfaches Update für den Bambu Pi Controller.
#
# Aufruf auf dem Pi (ein Befehl, ohne die alten Dateien zu treffen):
#   curl -fsSL https://raw.githubusercontent.com/felix6191/bambu-pi-controller/main/update.sh | sudo bash
#
# Der Befehl lädt immer die neueste install.sh und führt den Update-Modus aus.
# So funktioniert das Update auch dann, wenn die lokale Kopie veraltet ist.
# Danach genügt auch:  sudo bambu update
set -e

INSTALL_DIR="/opt/bambu-pi-controller"
RAW="https://raw.githubusercontent.com/felix6191/bambu-pi-controller/main"

if [[ $EUID -ne 0 ]]; then
    echo "Bitte mit sudo starten:"
    echo "  curl -fsSL $RAW/update.sh | sudo bash"
    exit 1
fi

if [[ ! -d "$INSTALL_DIR/.git" ]]; then
    echo "Der Bambu Pi Controller ist hier nicht installiert."
    echo "Erst neu installieren:"
    echo "  curl -fsSL $RAW/install.sh | sudo bash"
    exit 1
fi

echo "🔄 Bambu Pi Controller Update"
echo "============================="

tmp="$(mktemp)"
if ! curl -fsSL "$RAW/install.sh" -o "$tmp"; then
    echo "Download fehlgeschlagen — Internet/GitHub prüfen."
    exit 1
fi
exec bash "$tmp" --update
