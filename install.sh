#!/bin/bash
# bambu-pi-installer.sh - One-Click Installer für Bambu Pi Controller
# Führe aus: curl -fsSL https://raw.githubusercontent.com/DEIN_USERNAME/bambu-pi-controller/main/install.sh | sudo bash
# Oder lokal: chmod +x install.sh && sudo ./install.sh

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
REPO_URL="https://github.com/DEIN_USERNAME/bambu-pi-controller.git"
INSTALL_DIR="/opt/bambu-pi-controller"
SERVICE_USER="bambu"

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

check_root() { [[ $EUID -eq 0 ]] || err "Bitte als root ausführen: sudo ./install.sh"; }

detect_os() {
    . /etc/os-release
    log "Erkannt: $PRETTY_NAME"
}

install_docker() {
    command -v docker &>/dev/null && { ok "Docker: $(docker --version)"; return; }
    log "Installiere Docker..."; curl -fsSL https://get.docker.com | sh; systemctl enable --now docker; ok "Docker installiert"
}

install_docker_compose() {
    docker compose version &>/dev/null && { ok "Docker Compose verfügbar"; return; }
    log "Installiere Docker Compose Plugin..."; apt-get update -qq && apt-get install -y -qq docker-compose-plugin; ok "Docker Compose installiert"
}

install_tailscale() {
    command -v tailscale &>/dev/null && { ok "Tailscale installiert"; return; }
    log "Installiere Tailscale..."; curl -fsSL https://tailscale.com/install.sh | sh; ok "Tailscale installiert"
}

create_service_user() {
    id "$SERVICE_USER" &>/dev/null && { ok "User $SERVICE_USER existiert"; return; }
    log "Erstelle Service-User $SERVICE_USER..."; useradd -r -m -s /bin/bash "$SERVICE_USER"; usermod -aG docker "$SERVICE_USER"; ok "User erstellt"
}

clone_repo() {
    if [[ -d "$INSTALL_DIR/.git" ]]; then log "Repo existiert, aktualisiere..."; cd "$INSTALL_DIR"; git pull origin main
    else log "Klone Repository..."; git clone "$REPO_URL" "$INSTALL_DIR"; fi
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"; ok "Repository bereit"
}

setup_config() {
    local env="$INSTALL_DIR/pi_backend/.env"
    [[ -f "$env" ]] && grep -q "PRINTER_HOST=" "$env" && ! grep -q "PRINTER_HOST=$" "$env" && { ok "Config existiert"; return; }

    log "Konfiguration..."; cp "$INSTALL_DIR/pi_backend/.env.example" "$env"
    echo -e "\n${YELLOW}=== BAMBU A1 KONFIGURATION ===${NC}"
    echo "Daten aus Bambu Handy App: Gerät → Einstellungen → MQTT"
    echo ""
    read -p "Drucker IP (z.B. 192.168.1.100): " PRINTER_HOST
    read -p "Seriennummer (Aufkleber/Verpackung): " PRINTER_SERIAL
    read -p "MQTT Zugangscode (8-stellig): " PRINTER_ACCESS_CODE
    API_TOKEN=$(openssl rand -hex 32)

    sed -i "s|PRINTER_HOST=.*|PRINTER_HOST=$PRINTER_HOST|" "$env"
    sed -i "s|PRINTER_SERIAL=.*|PRINTER_SERIAL=$PRINTER_SERIAL|" "$env"
    sed -i "s|PRINTER_ACCESS_CODE=.*|PRINTER_ACCESS_CODE=$PRINTER_ACCESS_CODE|" "$env"
    sed -i "s|API_TOKEN=.*|API_TOKEN=$API_TOKEN|" "$env"

    read -p "Tailscale Auth-Key (leer=überspringen): " TS_KEY
    [[ -n "$TS_KEY" ]] && sed -i "s|TAILSCALE_AUTHKEY=.*|TAILSCALE_AUTHKEY=$TS_KEY|" "$env"

    read -p "Kamera Stream URL (optional): " CAM_URL
    [[ -n "$CAM_URL" ]] && sed -i "s|# CAMERA_URL=.*|CAMERA_URL=$CAM_URL|" "$env"

    chown "$SERVICE_USER:$SERVICE_USER" "$env"; chmod 600 "$env"; ok "Config gespeichert"
}

setup_tailscale() {
    local ts_key=$(grep "TAILSCALE_AUTHKEY=" "$INSTALL_DIR/pi_backend/.env" | cut -d= -f2)
    [[ -z "$ts_key" || "$ts_key" == "TS_KEY" ]] && { warn "Kein Tailscale Key - nur LAN-Zugriff"; return; }
    log "Verbinde Tailscale..."; sudo -u "$SERVICE_USER" tailscale up --authkey="$ts_key" --hostname=bambu-pi --accept-routes 2>/dev/null || true
    sleep 3; local ts_ip=$(tailscale ip -4 2>/dev/null || echo "verbunden"); ok "Tailscale: $ts_ip"
}

deploy() {
    log "Starte Container..."; cd "$INSTALL_DIR"; sudo -u "$SERVICE_USER" docker compose up -d --build
    log "Warte auf Health Check..."
    for i in {1..30}; do curl -sf http://localhost:8000/health >/dev/null 2>&1 && { ok "Backend läuft!"; break; }; sleep 1; done
}

print_summary() {
    local ts_ip=$(tailscale ip -4 2>/dev/null || echo "nicht verbunden")
    local lan_ip=$(hostname -I | awk '{print $1}')
    local api_token=$(grep "API_TOKEN=" "$INSTALL_DIR/pi_backend/.env" | cut -d= -f2)
    echo -e "\n${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  INSTALLATION ERFOLGREICH! 🎉            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}\n"
    echo -e "${BLUE}ZUGRIFF:${NC}"
    echo -e "  Lokal (LAN):      http://$lan_ip:8000"
    echo -e "  Remote (Tailscale): http://$ts_ip:8000\n"
    echo -e "${BLUE}IOS APP EINSTELLUNGEN:${NC}"
    echo -e "  Server URL:   http://$ts_ip:8000"
    echo -e "  API Token:    $api_token\n"
    echo -e "${BLUE}BEFEHLE:${NC}"
    echo -e "  Logs:      sudo -u $SERVICE_USER docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
    echo -e "  Restart:   sudo -u $SERVICE_USER docker compose -f $INSTALL_DIR/docker-compose.yml restart"
    echo -e "  Update:    cd $INSTALL_DIR && git pull && sudo -u $SERVICE_USER docker compose up -d --build"
    echo -e "  Status:    sudo -u $SERVICE_USER docker compose -f $INSTALL_DIR/docker-compose.yml ps\n"
    echo -e "${YELLOW}NÄCHSTE SCHRITTE:${NC}"
    echo "  1. iOS App in Xcode öffnen & auf iPhone installieren"
    echo "  2. In App: Einstellungen → Server URL & Token eintragen"
    echo "  3. 'Verbindung testen' → ✅"
    echo "  4. Dashboard zeigt Live-Status deines A1"
}

main() {
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  Bambu Pi Controller - One-Click Install ║${NC}"
    echo -e "${BLUE}║  für Raspberry Pi 4 + Bambu Lab A1       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}\n"
    check_root; detect_os
    apt-get update -qq && apt-get install -y -qq git curl openssl ca-certificates >/dev/null
    install_docker; install_docker_compose; install_tailscale; create_service_user; clone_repo; setup_config; setup_tailscale; deploy; print_summary
}

main "$@"