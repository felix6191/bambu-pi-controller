#!/bin/bash
# update.sh - Aktualisiert das Repository und deployed neu
# Auf dem Pi ausführen: sudo ./update.sh

set -e

INSTALL_DIR="/opt/bambu-pi-controller"
SERVICE_USER="bambu"

echo "🔄 Bambu Pi Controller Update"
echo "============================="

cd "$INSTALL_DIR"

echo "📥 Lade neueste Änderungen..."
git pull origin main

echo "📦 Baue und starte Container neu..."
sudo -u "$SERVICE_USER" docker compose up -d --build

echo ""
echo "⏳ Warte auf Health Check..."
for i in {1..30}; do
    if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
        echo "✅ Backend läuft!"
        break
    fi
    sleep 1
done

echo ""
echo "📋 Status:"
sudo -u "$SERVICE_USER" docker compose ps

echo ""
echo "✅ Update abgeschlossen!"