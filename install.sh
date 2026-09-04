#!/bin/bash
# bambu-pi-installer.sh - One-Click Installer für Bambu Pi Controller
# Führe aus: curl -fsSL https://raw.githubusercontent.com/DEIN_REPO/main/install.sh | bash
# Oder lokal: chmod +x install.sh && ./install.sh

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

REPO_URL="https://github.com/DEIN_USERNAME/bambu-pi-controller.git"
INSTALL_DIR="/opt/bambu-pi-controller"
SERVICE_USER="bambu"

log() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*"; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Bitte als root ausführen: sudo ./install.sh"
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        err "Kann OS nicht erkennen"
    fi
    log "Erkannt: $PRETTY_NAME"
}

install_docker() {
    if command -v docker &> /dev/null; then
        ok "Docker bereits installiert: $(docker --version)"
        return
    fi
    log "Installiere Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "Docker installiert"
}

install_docker_compose() {
    if docker compose version &> /dev/null; then
        ok "Docker Compose bereits verfügbar"
        return
    fi
    log "Installiere Docker Compose Plugin..."
    apt-get update && apt-get install -y docker-compose-plugin
    ok "Docker Compose installiert"
}

install_tailscale() {
    if command -v tailscale &> /dev/null; then
        ok "Tailscale bereits installiert"
        return
    fi
    log "Installiere Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    ok "Tailscale installiert"
}

create_service_user() {
    if id "$SERVICE_USER" &>/dev/null; then
        ok "User $SERVICE_USER existiert bereits"
    else
        log "Erstelle Service-User $SERVICE_USER..."
        useradd -r -m -s /bin/bash "$SERVICE_USER"
        usermod -aG docker "$SERVICE_USER"
        ok "User $SERVICE_USER erstellt"
    fi
}

clone_repo() {
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log "Repo existiert, aktualisiere..."
        cd "$INSTALL_DIR"
        git pull origin main
    else
        log "Klone Repository..."
        git clone "$REPO_URL" "$INSTALL_DIR"
    fi
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    ok "Repository bereit"
}

setup_config() {
    local env_file="$INSTALL_DIR/pi_backend/.env"
    if [[ -f "$env_file" ]] && grep -q "PRINTER_HOST=" "$env_file" && ! grep -q "PRINTER_HOST=$" "$env_file"; then
        ok "Config existiert bereits"
        return
    fi

    log "Konfiguration wird erstellt..."
    cp "$INSTALL_DIR/pi_backend/.env.example" "$env_file"

    echo ""
    echo -e "${YELLOW}=== BAMBU A1 KONFIGURATION ===${NC}"
    echo "Diese Daten findest du in der Bambu Handy App:"
    echo "  Gerät → Einstellungen → MQTT"
    echo ""

    read -p "Drucker IP (z.B. 192.168.1.100): " PRINTER_HOST
    read -p "Seriennummer (auf Aufkleber/Verpackung): " PRINTER_SERIAL
    read -p "MQTT Zugangscode (8-stellig): " PRINTER_ACCESS_CODE

    API_TOKEN=$(openssl rand -hex 32)

    sed -i "s|PRINTER_HOST=.*|PRINTER_HOST=$PRINTER_HOST|" "$env_file"
    sed -i "s|PRINTER_SERIAL=.*|PRINTER_SERIAL=$PRINTER_SERIAL|" "$env_file"
    sed -i "s|PRINTER_ACCESS_CODE=.*|PRINTER_ACCESS_CODE=$PRINTER_ACCESS_CODE|" "$env_file"
    sed -i "s|API_TOKEN=.*|API_TOKEN=$API_TOKEN|" "$env_file"

    echo ""
    read -p "Tailscale Auth-Key (für Remote-Zugriff, leer=überspringen): " TS_KEY
    if [[ -n "$TS_KEY" ]]; then
        sed -i "s|TAILSCALE_AUTHKEY=.*|TAILSCALE_AUTHKEY=$TS_KEY|" "$env_file"
    fi

    # Kamera (optional)
    read -p "Kamera Stream URL (optional, z.B. http://192.168.1.100:8080/stream): " CAM_URL
    if [[ -n "$CAM_URL" ]]; then
        sed -i "s|# CAMERA_URL=.*|CAMERA_URL=$CAM_URL|" "$env_file"
    fi

    chown "$SERVICE_USER:$SERVICE_USER" "$env_file"
    chmod 600 "$env_file"
    ok "Konfiguration gespeichert"
}

setup_tailscale() {
    local env_file="$INSTALL_DIR/pi_backend/.env"
    local ts_key=$(grep "TAILSCALE_AUTHKEY=" "$env_file" | cut -d= -f2)

    if [[ -z "$ts_key" || "$ts_key" == "TS_KEY" ]]; then
        warn "Kein Tailscale Auth-Key konfiguriert - nur LAN-Zugriff möglich"
        return
    fi

    log "Verbinde Tailscale..."
    sudo -u "$SERVICE_USER" tailscale up --authkey="$ts_key" --hostname=bambu-pi --accept-routes 2>/dev/null || true
    sleep 3
    local ts_ip=$(tailscale ip -4 2>/dev/null || echo "verbunden")
    ok "Tailscale verbunden: $ts_ip"
}

deploy() {
    log "Starte Container..."
    cd "$INSTALL_DIR"
    sudo -u "$SERVICE_USER" docker compose up -d --build

    log "Warte auf Health Check..."
    for i in {1..30}; do
        if curl -sf http://localhost:8000/health > /dev/null 2>&1; then
            ok "Backend läuft!"
            break
        fi
        sleep 1
    done
}

print_summary() {
    local ts_ip=$(tailscale ip -4 2>/dev/null || echo "nicht verbunden")
    local lan_ip=$(hostname -I | awk '{print $1}')
    local api_token=$(grep "API_TOKEN=" "$INSTALL_DIR/pi_backend/.env" | cut -d= -f2)

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  INSTALLATION ERFOLGREICH! 🎉            ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BLUE}ZUGRIFF:${NC}"
    echo -e "  Lokal (LAN):     http://$lan_ip:8000"
    echo -e "  Remote (Tailscale): http://$ts_ip:8000"
    echo ""
    echo -e "${BLUE}IOS APP EINSTELLUNGEN:${NC}"
    echo -e "  Server URL:   http://$ts_ip:8000"
    echo -e "  API Token:    $api_token"
    echo ""
    echo -e "${BLUE}BEFEHLE:${NC}"
    echo -e "  Logs:      sudo -u $SERVICE_USER docker compose -f $INSTALL_DIR/docker-compose.yml logs -f"
    echo -e "  Restart:   sudo -u $SERVICE_USER docker compose -f $INSTALL_DIR/docker-compose.yml restart"
    echo -e "  Update:    cd $INSTALL_DIR && git pull && sudo -u $SERVICE_USER docker compose up -d --build"
    echo -e "  Status:    sudo -u $SERVICE_USER docker compose -f $INSTALL_DIR/docker-compose.yml ps"
    echo ""
    echo -e "${YELLOW}NÄCHSTE SCHRITTE:${NC}"
    echo "  1. iOS App in Xcode öffnen & auf iPhone installieren"
    echo "  2. In App: Einstellungen → Server URL & Token eintragen"
    echo "  3. 'Verbindung testen' → ✅"
    echo "  4. Dashboard zeigt Live-Status deines A1"
}

main() {
    echo -e "${BLUE}"
    echo "╔══════════════════════════════════════════╗"
    echo "║  Bambu Pi Controller - One-Click Install ║"
    echo "║  für Raspberry Pi 4 + Bambu Lab A1       ║"
    echo "╚══════════════════════════════════════════╝"
    echo -e "${NC}"

    check_root
    detect_os

    apt-get update -qq
    apt-get install -y -qq git curl openssl ca-certificates > /dev/null

    install_docker
    install_docker_compose
    install_tailscale
    create_service_user
    clone_repo
    setup_config
    setup_tailscale
    deploy
    print_summary
}

main "$@"