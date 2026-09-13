#!/bin/bash
# deploy.sh - Einfaches Deploy-Skript für den Raspberry Pi

set -e

echo "🚀 Bambu Pi Controller Deploy"
echo "=============================="

[[ -f pi_backend/.env ]] || { echo "❌ pi_backend/.env nicht gefunden! cp pi_backend/.env.example pi_backend/.env"; exit 1; }
grep -q "your-secure-api-token-here" pi_backend/.env && { echo "⚠️  API_TOKEN nicht gesetzt! openssl rand -hex 32"; exit 1; }

echo "📦 Baue und starte Container..."
docker compose up -d --build

echo ""; echo "⏳ Warte auf Health Check..."
for i in {1..30}; do curl -sf http://localhost:8000/health >/dev/null 2>&1 && { echo "✅ Backend läuft!"; break; }; sleep 1; done

echo ""; echo "📋 Status:"; docker compose ps

echo ""; echo "🔗 Zugriff:"
echo "   Lokal:      http://$(hostname -I | awk '{print $1}'):8000"
echo "   Remote:     App → Einstellungen → Fernzugriff starten (Cloudflare, ohne Login)"
echo ""
echo "📱 iOS App Einstellungen:"
echo "   Server URL: http://$(hostname -I | awk '{print $1}'):8000  (Heimnetz)"
echo "   API Token:  $(grep API_TOKEN pi_backend/.env | cut -d= -f2)"
echo ""
echo "📝 Logs: docker compose logs -f bambu-controller"