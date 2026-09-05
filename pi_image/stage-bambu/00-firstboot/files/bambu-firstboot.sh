#!/bin/bash
# Bambu Pi Controller — Ersteinrichtung beim ersten Start des Flash-Images.
# Wird einmalig per systemd (bambu-firstboot.service) ausgeführt, danach
# deaktiviert. Idempotent: kann gefahrlos erneut laufen.
set -e
LOG=/var/log/bambu-firstboot.log
exec >>"$LOG" 2>&1
echo "=== bambu-firstboot $(date -Is) ==="

INSTALL_DIR="/opt/bambu-pi-controller"
SERVICE_USER="bambu"
ENV_FILE="$INSTALL_DIR/pi_backend/.env"

# 1) Netzwerk abwarten (Kabel ODER per Pi-Imager eingetragenes WLAN), max ~5 Min
for _ in $(seq 1 60); do
  if ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 || ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
    echo "Netzwerk ok"; break
  fi
  sleep 5
done
if ! ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
  echo "Kein Netzwerk — Setup-AP wird gestartet (Bambu-Setup-XXXX)"
  systemctl start bambu-setup-ap.service || true
  exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl openssl ca-certificates avahi-daemon docker.io docker-compose-plugin >/dev/null
systemctl enable --now docker 2>/dev/null || true
systemctl enable --now avahi-daemon 2>/dev/null || true

# 2) Dienst-User + Code (Code ist im Image eingebettet; Git nur als Fallback)
if ! id "$SERVICE_USER" &>/dev/null; then
  useradd -r -m -s /bin/bash "$SERVICE_USER"
  usermod -aG docker "$SERVICE_USER"
fi
if [[ ! -f "$INSTALL_DIR/docker-compose.yml" && -n "${BAMBU_REPO_URL:-}" ]]; then
  git clone --depth 1 "${BAMBU_REPO_URL}" "$INSTALL_DIR"
fi
if [[ ! -f "$INSTALL_DIR/docker-compose.yml" ]]; then
  echo "FEHLER: kein Code im Image und kein Repo erreichbar — Abbruch"
  exit 1
fi
chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" 2>/dev/null || true

# 3) API-Token erzeugen (einmalig) — Handy holt ihn sich per Tap (Pairing)
if [[ -f "$ENV_FILE" ]]; then
  TOKEN=$(grep "^API_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d= -f2 || true)
fi
if [[ -z "${TOKEN:-}" || "$TOKEN" == "your-secure-api-token-here" ]]; then
  TOKEN=$(openssl rand -hex 32)
  mkdir -p "$(dirname "$ENV_FILE")"
  touch "$ENV_FILE"
  if grep -q "^API_TOKEN=" "$ENV_FILE"; then
    sed -i "s|^API_TOKEN=.*|API_TOKEN=$TOKEN|" "$ENV_FILE"
  else
    echo "API_TOKEN=$TOKEN" >> "$ENV_FILE"
  fi
  chown "$SERVICE_USER:$SERVICE_USER" "$ENV_FILE"; chmod 600 "$ENV_FILE"
  echo "API-Token erzeugt"
fi

# 4) mDNS-Anzeige für die App („Bambu-Pi sendet Signal")
cp "$INSTALL_DIR/pi_image/stage-bambu/00-firstboot/files/bambu-pi-avahi.service" /etc/avahi/services/bambu-pi.service 2>/dev/null || true
systemctl reload avahi-daemon 2>/dev/null || true

# 5) Server starten
cd "$INSTALL_DIR"
sudo -u "$SERVICE_USER" docker compose up -d --build
for _ in $(seq 1 40); do
  curl -sf http://localhost:8000/health >/dev/null 2>&1 && break
  sleep 3
done
curl -sf http://localhost:8000/health && echo "Server läuft" || echo "WARN: Server antwortet nicht"

# 6) Einmal-Service deaktivieren
systemctl disable bambu-firstboot.service
echo "=== fertig $(date -Is) ==="
