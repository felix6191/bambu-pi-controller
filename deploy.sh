#!/bin/bash
# deploy.sh - Einfaches Deploy-Skript für den Raspberry Pi

set -e

echo "🚀 Bambu Pi Controller Deploy"
echo "=============================="

# Prüfen ob .env existiert
if [ ! -f pi_backend/.env ]; then
    echo "❌ pi_backend/.env nicht gefunden!"
    echo "   Kopiere .env.example und trage deine Daten ein:"
    echo "   cp pi_backend/.env.example pi_backend/.env"
    exit 1
fi

# API Token prüfen
if grep -q "your-secure-api-token-here" pi_backend/.env; then
    echo "⚠️  API_TOKEN noch nicht gesetzt!"
    echo "   Generiere einen neuen Token:"
    echo "   openssl rand -hex 32"
    echo "   Und trage ihn in pi_backend/.env ein"
    exit 1
fi

# Tailscale Auth Key prüfen (optional)
if ! grep -q "TAILSCALE_AUTHKEY=" pi_backend/.env || grep -q "TAILSCALE_AUTHKEY=$" pi_backend/.env; then
    echo "ℹ️  TAILSCALE_AUTHKEY nicht gesetzt - nur LAN-Zugriff möglich"
    echo "   Für Remote-Zugriff: Auth-Key bei https://login.tailscale.com/admin/settings/keys erstellen"
fi

echo "📦 Baue und starte Container..."
docker compose up -d --build

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
docker compose ps

echo ""
echo "🔗 Zugriff:"
echo "   Lokal:      http://$(hostname -I | awk '{print $1}'):8000"
if command -v tailscale &> /dev/null; then
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "nicht verbunden")
    echo "   Tailscale:  http://${TAILSCALE_IP}:8000"
fi
echo ""
echo "📱 iOS App Einstellungen:"
echo "   Server URL: http://<TAILSCALE_IP>:8000"
echo "   API Token:  $(grep API_TOKEN pi_backend/.env | cut -d= -f2)"
echo ""
echo "📝 Logs anzeigen: docker compose logs -f bambu-controller"