#!/bin/bash
# Bambu Pi Controller — One-Click Installer für Raspberry Pi + Bambu Lab A1
#
# Einziger Installationsweg (kein Custom-Image, kein Flashen nötig):
# Standard Raspberry Pi OS (64-bit) per offiziellem Pi Imager auf SD-Karte,
# Pi starten, dann genau 1 Befehl auf dem Pi:
#   curl -fsSL https://raw.githubusercontent.com/felix6191/bambu-pi-controller/main/install.sh | sudo bash
#
# Am Pi muss nichts getippt werden: bei allen Fragen einfach ENTER drücken
# (Defaults = alles später per App). Der Rest passiert in der iPhone-App:
# Pi antippen → Verbinden → Drucker wählen → fertig.
# Fallback (z. B. unterwegs via Tailscale): 2 Werte vom Bildschirm abtippen.
#
# Flags:
#   --configure   Nur Einrichtungs-Wizard erneut durchlaufen (Druckerdaten korrigieren)
#   --update      Repo aktualisieren + Container neu bauen
# Umgebungsvariablen (optional, für Profis — überspringen die Fragen):
#   PRINTER_HOST PRINTER_SERIAL PRINTER_ACCESS_CODE TAILSCALE_AUTHKEY API_TOKEN

set -e
trap 'echo ""; echo "[FEHLER] Abgebrochen. Einfach erneut starten — der Installer macht da weiter, wo er war."' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
REPO_URL="https://github.com/felix6191/bambu-pi-controller.git"
INSTALL_DIR="/opt/bambu-pi-controller"
SERVICE_USER="bambu"
ENV_FILE="$INSTALL_DIR/pi_backend/.env"

log()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }
title(){ echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}\n"; }

MODE="install"
[[ "${1:-}" == "--configure" ]] && MODE="configure"
[[ "${1:-}" == "--update" ]] && MODE="update"

# ---------------------------------------------------------------- checks ---

check_root() { [[ $EUID -eq 0 ]] || err "Bitte mit sudo starten. Richtiger Befehl steht in der Anleitung."; }

ensure_tty() {
    # Bei `curl … | sudo bash` hängt stdin an der Pipe, nicht an der Tastatur —
    # ohne diesen Trick würden die `read`-Abfragen unten Skriptzeilen statt
    # Tastatureingaben lesen. Terminal zurückholen, damit ENTER wirklich ENTER ist.
    if [[ ! -t 0 ]]; then
        if [[ -e /dev/tty ]]; then
            exec </dev/tty 2>/dev/null || warn "Kein Terminal für Eingaben — laufe mit Defaults (Drucker später per iPhone einrichten)."
        else
            warn "Kein Terminal erkannt — laufe vollautomatisch mit Defaults (Drucker später per iPhone einrichten)."
        fi
    fi
}

preflight() {
    title "Schritt 0/6 · System prüfen"
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        log "System: ${PRETTY_NAME:-unbekannt}"
        if [[ "${ID_LIKE:-$ID}" != *debian* && "$ID" != "debian" && "$ID" != "ubuntu" && "$ID" != "raspbian" ]]; then
            warn "Kein Debian/Ubuntu/Raspberry Pi OS erkannt — ich versuche es trotzdem."
        fi
    else
        warn "Betriebssystem unbekannt — ich versuche es trotzdem."
    fi
    if ! ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 && ! ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
        err "Kein Internet erreichbar. Bitte WLAN/LAN am Pi prüfen und erneut starten."
    fi
    ok "Internet ok"
    local mem_kb
    mem_kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 4000000)
    [[ "$mem_kb" -lt 1500000 ]] && warn "Wenig RAM erkannt — sollte trotzdem laufen, kann aber dauern."
    ok "System bereit"
}

install_base() {
    title "Schritt 1/6 · Grundprogramme installieren"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq git curl openssl ca-certificates iputils-ping avahi-daemon qrencode >/dev/null 2>&1 || \
        apt-get install -y -qq git curl openssl ca-certificates iputils-ping avahi-daemon >/dev/null
    systemctl enable --now avahi-daemon 2>/dev/null || true
    ok "Grundprogramme bereit"
}

install_docker() {
    if command -v docker &>/dev/null; then ok "Docker ist schon da ($(docker --version | cut -d' ' -f3))"; return; fi
    log "Docker wird installiert (dauert 2–5 Minuten, einfach warten) …"
    curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
    systemctl enable --now docker
    ok "Docker installiert"
}

install_compose() {
    if docker compose version &>/dev/null; then ok "Docker Compose ist schon da"; return; fi
    log "Docker Compose wird installiert …"
    apt-get install -y -qq docker-compose-plugin >/dev/null
    ok "Docker Compose installiert"
}

install_tailscale() {
    if command -v tailscale &>/dev/null; then ok "Tailscale ist schon da"; return; fi
    log "Tailscale wird installiert (für weltweiten Zugriff vom iPhone) …"
    curl -fsSL https://tailscale.com/install.sh | sh >/dev/null 2>&1
    ok "Tailscale installiert"
}

check_slicer() {
    # Optional: STL→G-Code direkt auf dem Pi (ARM64-Build nötig, kein Pflichtprogramm)
    if command -v prusa-slicer &>/dev/null || command -v prusa_slicer &>/dev/null || command -v orcaslicer &>/dev/null || command -v bambustudio &>/dev/null; then
        ok "Slicer gefunden — STL-Druck aus der App funktioniert"
    else
        warn "Kein Slicer auf dem Pi (nötig für STL→G-Code in der App)."
        echo "  Später nachholen: ARM64-Build von PrusaSlicer/OrcaSlicer installieren,"
        echo "  ggf. SLICER_CMD/SLICER_TEMPLATE in docker-compose.yml anpassen (siehe README)."
        echo "  Ohne Slicer gehen trotzdem: Status, Steuerung, Kamera + SD-Dateien starten."
    fi
}

setup_user_repo() {
    title "Schritt 2/6 · Programmdateien holen"
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd -r -m -s /bin/bash "$SERVICE_USER"
        usermod -aG docker "$SERVICE_USER"
    fi
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        log "Aktualisiere Dateien …"
        git -C "$INSTALL_DIR" pull --ff-only origin main 2>/dev/null || warn "Konnte nicht aktualisieren — nutze vorhandene Dateien."
    else
        log "Lade Dateien herunter …"
        git clone --depth 1 "$REPO_URL" "$INSTALL_DIR" || err "Download fehlgeschlagen. Internet prüfen und erneut starten."
    fi
    chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR"
    # Helfer-Befehl installieren (bambu status / bambu iphone / …)
    if [[ -f "$INSTALL_DIR/pi_helpers/bambu" ]]; then
        cp "$INSTALL_DIR/pi_helpers/bambu" /usr/local/bin/bambu
        chmod +x /usr/local/bin/bambu
    fi
    ok "Dateien bereit"
}

# ------------------------------------------------------------- wizard ---

valid_ip() {
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS=.
    # shellcheck disable=SC2162
    read -r a b c d <<< "$1"
    for o in "$a" "$b" "$c" "$d"; do [[ "$o" -le 255 ]] || return 1; done
    return 0
}

ask() { # ask VAR "Prompt" "Default" "Hint"
    local var="$1" prompt="$2" def="$3" hint="$4" val
    # Profi-Modus: Umgebungsvariable gewinnt
    if [[ -n "${!var:-}" ]]; then return 0; fi
    while true; do
        echo -e "${BOLD}$prompt${NC}"
        [[ -n "$hint" ]] && echo -e "  ${YELLOW}Tipp: $hint${NC}"
        if [[ -n "$def" ]]; then read -rp "  Eingabe [$def]: " val; val="${val:-$def}"
        else read -rp "  Eingabe: " val; fi
        printf -v "$var" '%s' "$val"
        [[ -n "${!var}" ]] && break
        echo "  Bitte etwas eingeben (oder später mit 'sudo bambu reconfigure' ändern)."
    done
}

wizard() {
    local env="$ENV_FILE"
    title "Schritt 3/6 · Drucker einrichten (einmalig)"
    echo "Ich brauche 3 Angaben von deinem Bambu Lab A1."
    echo "Alle findest du wie folgt:"
    echo "  1. Am Drucker-Display: Einstellungen → Netzwerk → IP-Adresse + Access Code"
    echo "  2. Seriennummer: Aufkleber am Drucker oder auf der Verpackung"
    echo "  3. Wichtig: Am Drucker muss der Entwickler-/LAN-Modus AN sein."
    echo ""
    echo "  Bequemere Alternative: Hier ENTER drücken zum Überspringen und die"
    echo "  3 Werte später direkt am Drucker stehend per iPhone-App nachtragen"
    echo "  (App → Einrichtung → Drucker). Der Server startet auch ohne."
    echo ""
    # Bestehende Werte laden (für Reconfigure: ENTER behält sie)
    local old_host="" old_serial="" old_code=""
    if [[ -f "$ENV_FILE" ]]; then
        old_host=$(grep "^PRINTER_HOST=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
        old_serial=$(grep "^PRINTER_SERIAL=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
        old_code=$(grep "^PRINTER_ACCESS_CODE=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
    fi

    if [[ -z "${PRINTER_HOST:-}" ]]; then
        # Default ist ÜBERSPRINGEN: einfach ENTER hämmern → alles später per App.
        # Nur wer jetzt tippen will, drückt j.
        if [[ -n "$old_host" ]]; then
            echo "  Gespeichert ist bereits: $old_host (Seriennummer ${old_serial:-?})"
        fi
        read -rp "  Jetzt eingeben (j) oder später per iPhone (Enter)? [Enter]: " _when
        if [[ "$_when" != "j" && "$_when" != "J" ]]; then
            if [[ -n "$old_host" ]]; then
                log "Behalte bisherige Druckerdaten ($old_host) — weiter geht's."
                return 0
            fi
            log "Übersprungen — Drucker wird später per iPhone eingerichtet."
            # Leere Platzhalter schreiben, API-Token trotzdem erzeugen
            if [[ -z "${API_TOKEN:-}" ]]; then
                API_TOKEN=$(grep "^API_TOKEN=" "$env" 2>/dev/null | cut -d= -f2)
                [[ -z "$API_TOKEN" || "$API_TOKEN" == "your-secure-api-token-here" ]] && API_TOKEN=$(openssl rand -hex 32)
            fi
            cp "$INSTALL_DIR/pi_backend/.env.example" "$env" 2>/dev/null || true
            sed -i "s|^API_TOKEN=.*|API_TOKEN=$API_TOKEN|" "$env"
            sed -i "s|^PRINTER_HOST=.*|PRINTER_HOST=|" "$env"
            chown "$SERVICE_USER:$SERVICE_USER" "$env"; chmod 600 "$env"
            ok "Platzhalter gespeichert — weiter geht's"
            return 0
        fi
    fi

    while true; do
        ask PRINTER_HOST "Wie lautet die IP-Adresse des Druckers? (z. B. 192.168.1.50)" "$old_host" "Muss mit 192.168. oder 10. oder 172. anfangen (Heimnetz)."
        valid_ip "$PRINTER_HOST" && break
        echo "  Das sieht nicht wie eine IP-Adresse aus — bitte prüfen."
        unset PRINTER_HOST
    done

    ask PRINTER_SERIAL "Wie lautet die Seriennummer?" "$old_serial" "Steht auf dem Aufkleber, z. B. 01S00A…"
    while true; do
        ask PRINTER_ACCESS_CODE "Wie lautet der 8-stellige Access Code?" "$old_code" "Am Drucker-Display unter Netzwerk."
        [[ "${#PRINTER_ACCESS_CODE}" -eq 8 ]] && break
        echo "  Der Code hat genau 8 Zeichen — bitte prüfen."
        unset PRINTER_ACCESS_CODE
    done

    # Erreichbarkeit prüfen (freundlich, kein Abbruch)
    title "Drucker wird gesucht …"
    if ping -c1 -W3 "$PRINTER_HOST" >/dev/null 2>&1; then
        ok "Drucker antwortet auf Ping ($PRINTER_HOST)"
        if timeout 6 bash -c "</dev/tcp/$PRINTER_HOST/8883" 2>/dev/null; then
            ok "Drucker-MQTT (Port 8883) erreichbar — sehr gutes Zeichen."
        else
            warn "Port 8883 antwortet nicht. Mögliche Gründe: Drucker aus/gedruckt gerade? LAN-/Entwicklermodus am Drucker prüfen. Ich installiere trotzdem weiter — später mit 'sudo bambu reconfigure' korrigierbar."
        fi
    else
        warn "Drucker antwortet nicht auf Ping. Bist du im gleichen WLAN? IP prüfen! Ich installiere trotzdem weiter."
    fi

    # Tailscale-Key optional
    if [[ -z "${TAILSCALE_AUTHKEY:-}" ]]; then
        echo ""
        echo -e "${BOLD}Tailscale für weltweiten iPhone-Zugriff (optional, empfohlen)${NC}"
        echo "  Mit Key geht alles automatisch. Ohne Key zeige ich dir gleich einen Login-Link."
        echo "  Key erstellen (30 Sek.): https://login.tailscale.com/admin/settings/keys"
        read -rp "  Auth-Key (Enter = überspringen): " TAILSCALE_AUTHKEY
    fi

    # API-Token: behalten oder neu
    if [[ -z "${API_TOKEN:-}" ]]; then
        API_TOKEN=$(grep "^API_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
        [[ -z "$API_TOKEN" || "$API_TOKEN" == "your-secure-api-token-here" ]] && API_TOKEN=$(openssl rand -hex 32)
    fi

    # .env atomar schreiben
    local tmp
    tmp=$(mktemp)
    {
        echo "# Automatisch erstellt von install.sh — nicht von Hand ändern, nutze: sudo bambu reconfigure"
        echo "PRINTER_HOST=$PRINTER_HOST"
        echo "PRINTER_SERIAL=$PRINTER_SERIAL"
        echo "PRINTER_ACCESS_CODE=$PRINTER_ACCESS_CODE"
        echo "PRINTER_PORT=8883"
        echo "PRINTER_USE_TLS=true"
        echo "HOST=0.0.0.0"
        echo "PORT=8000"
        echo "LOG_LEVEL=INFO"
        echo "API_TOKEN=$API_TOKEN"
        echo "TAILSCALE_AUTHKEY=${TAILSCALE_AUTHKEY:-}"
        echo "# CAMERA_URL="
    } > "$tmp"
    mkdir -p "$(dirname "$ENV_FILE")"
    mv "$tmp" "$ENV_FILE"
    chown "$SERVICE_USER:$SERVICE_USER" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "Drucker-Konfiguration gespeichert"
}

# ------------------------------------------------------------- mdns ---

setup_mdns() {
    title "Schritt 4/6 · iPhone-Findung einrichten (Auto-Discovery)"
    # Die App findet den Pi ohne IP-Eingabe per mDNS `_bambu-pi._tcp`.
    # Früher kam das aus dem Flash-Image — jetzt richtet es der Installer ein.
    local src="$INSTALL_DIR/pi_helpers/bambu-pi-avahi.service"
    if [[ -f "$src" ]]; then
        mkdir -p /etc/avahi/services
        cp "$src" /etc/avahi/services/bambu-pi.service
        systemctl enable --now avahi-daemon 2>/dev/null || service avahi-daemon restart 2>/dev/null || true
        systemctl reload avahi-daemon 2>/dev/null || true
        ok "Pi meldet sich im WLAN als _bambu-pi._tcp (App findet ihn von allein)"
    else
        warn "Avahi-Service-Datei fehlt ($src) — App findet Pi nur per IP. Update holen mit 'sudo bambu update'."
    fi
}

# ------------------------------------------------------------- tailscale ---

setup_tailscale() {
    title "Schritt 5/6 · Weltweiten Zugriff einrichten (Tailscale)"
    local ts_key
    ts_key=$(grep "^TAILSCALE_AUTHKEY=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)

    if [[ -n "$ts_key" ]]; then
        log "Verbinde mit Auth-Key …"
        tailscale up --authkey="$ts_key" --hostname=bambu-pi --accept-routes >/dev/null 2>&1 || true
        sleep 3
    else
        if [[ ! -t 0 ]]; then
            warn "Nicht interaktiv — Tailscale-Login übersprungen (nur Heimnetz). Später: 'sudo tailscale up'."
            TAILSCALE_IP=""; return 0
        fi
        echo ""
        echo "  Gleich startet der Tailscale-Login per Link (Handy/PC, 1 Minute)."
        read -rp "  Jetzt verbinden (Enter) oder später (n)? [Enter]: " _ts_now
        if [[ "$_ts_now" == "n" || "$_ts_now" == "N" ]]; then
            warn "Tailscale übersprungen — nur Heimnetz. Später: 'sudo tailscale up'."
            TAILSCALE_IP=""; return 0
        fi
        log "Starte Tailscale-Login …"
        rm -f /tmp/ts_up.log
        tailscale up --hostname=bambu-pi >/tmp/ts_up.log 2>&1 &
        local ts_pid=$!
        local url=""
        for _ in $(seq 1 12); do
            sleep 5
            url=$(grep -o 'https://login\.tailscale\.com[^ ]*' /tmp/ts_up.log 2>/dev/null | head -1)
            tailscale ip -4 >/dev/null 2>&1 && break
            kill -0 "$ts_pid" 2>/dev/null || break
        done
        if tailscale ip -4 >/dev/null 2>&1; then
            ok "Tailscale ist schon verbunden"
            kill "$ts_pid" 2>/dev/null || true
        elif [[ -n "$url" ]]; then
            echo ""
            echo -e "${YELLOW}${BOLD}  ➜ BITTE JETZT: Öffne auf Handy oder PC diesen Link und logge dich ein:${NC}"
            echo -e "${BOLD}  $url${NC}"
            echo ""
            echo "  Ich warte bis zu 3 Minuten … (einfach einloggen, hier passiert es automatisch)"
            for _ in $(seq 1 36); do
                sleep 5
                if tailscale ip -4 >/dev/null 2>&1; then break; fi
                kill -0 "$ts_pid" 2>/dev/null || break
            done
            wait "$ts_pid" 2>/dev/null || true
        else
            warn "Konnte keinen Login-Link erzeugen — prüfe 'sudo tailscale status' manuell."
        fi
    fi

    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    if [[ -n "$ts_ip" ]]; then ok "Tailscale verbunden: $ts_ip (weltweit erreichbar)"; TAILSCALE_IP="$ts_ip"
    else warn "Tailscale nicht verbunden — Zugriff nur im Heimnetz. Später: 'sudo tailscale up' oder 'sudo bambu reconfigure'."; TAILSCALE_IP=""; fi
}

# ---------------------------------------------------------------- deploy ---

deploy() {
    title "Schritt 6/6 · Server starten"
    log "Baue und starte (erster Start lädt Docker-Bilder, dauert ein paar Minuten) …"
    cd "$INSTALL_DIR"
    sudo -u "$SERVICE_USER" docker compose up -d --build || err "Start fehlgeschlagen. Details: sudo bambu logs"
    log "Warte, bis der Server antwortet …"
    local ok_health=0
    for _ in $(seq 1 40); do
        if curl -sf http://localhost:8000/health >/dev/null 2>&1; then ok_health=1; break; fi
        sleep 3
    done
    if [[ "$ok_health" -eq 1 ]]; then
        ok "Server läuft!"
        local health
        health=$(curl -sf http://localhost:8000/health 2>/dev/null || echo "")
        echo "  $health" | grep -q '"printer_connected":true' \
            && ok "Drucker verbunden!" \
            || warn "Server läuft, Drucker meldet sich noch nicht. Drucker an? IP/Code prüfen mit 'sudo bambu reconfigure'. Logs: 'sudo bambu logs'."
    else
        err "Server antwortet nicht. Details ansehen mit: sudo bambu logs"
    fi
}

write_iphone_sheet() {
    local lan_ip ts_ip api_token server_url
    lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
    api_token=$(grep "^API_TOKEN=" "$ENV_FILE" | cut -d= -f2)
    if [[ -n "$ts_ip" ]]; then server_url="http://$ts_ip:8000"; else server_url="http://$lan_ip:8000"; fi
    {
        echo "Bambu Pi Controller — iPhone Einrichtung"
        echo "========================================"
        echo ""
        echo "In der iPhone-App (Einrichtung oder Einstellungen) eintragen:"
        echo ""
        echo "  Server URL:  $server_url"
        echo "  API Token:   $api_token"
        echo ""
        echo "Dann 'Verbindung testen' → ✅ → Fertig."
        echo "Diese Datei liegt auf dem Pi: $INSTALL_DIR/IPHONE_SETUP.txt"
        echo "Jederzeit erneut anzeigen mit:  sudo bambu iphone"
    } > "$INSTALL_DIR/IPHONE_SETUP.txt"
    chown "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR/IPHONE_SETUP.txt"
    IPHONE_URL="$server_url"; IPHONE_TOKEN="$api_token"; LAN_IP="$lan_ip"
}

print_summary() {
    write_iphone_sheet
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  FERTIG! 🎉  Dein Drucker-Server läuft.           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${BOLD}So geht es auf dem iPhone weiter (1 Minute):${NC}"
    echo "  1. BambuController-App öffnen → Einrichtung starten"
    echo "  2. Dein Pi erscheint von allein -> antippen -> 'Verbinden' (nichts abtippen!)"
    echo "  3. Nur als Fallback (z. B. unterwegs via Tailscale) diese 2 Werte tippen:"
    echo -e "     ${BOLD}Server URL:${NC}  $IPHONE_URL"
    echo -e "     ${BOLD}API Token:${NC}   $IPHONE_TOKEN"
    echo "  4. 'Verbindung testen' → ✅ → 'Fertig'"
    echo ""
    if command -v qrencode &>/dev/null; then
        echo "  QR-Code für die Server-URL (Token danach abtippen):"
        qrencode -t ANSIUTF8 -m 1 "$IPHONE_URL" 2>/dev/null || true
        echo ""
    fi
    echo -e "${BOLD}Nützliche Befehle für später (auf dem Pi):${NC}"
    echo "  sudo bambu status       Zustand + Adressen anzeigen"
    echo "  sudo bambu iphone       Diese iPhone-Anleitung erneut anzeigen"
    echo "  sudo bambu logs         Live-Protokoll ansehen"
    echo "  sudo bambu update       Auf neueste Version aktualisieren"
    echo "  sudo bambu reconfigure  Druckerdaten korrigieren"
}

# ------------------------------------------------------------------ main ---

main() {
    echo -e "${BLUE}${BOLD}"
    echo "╔════════════════════════════════════════════════════╗"
    echo "║  Bambu Pi Controller · 1-Klick-Installation        ║"
    echo "║  Raspberry Pi + Bambu Lab A1 + iPhone              ║"
    echo "╚════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    check_root
    ensure_tty

    if [[ "$MODE" == "update" ]]; then
        [[ -d "$INSTALL_DIR/.git" ]] || err "Nichts installiert. Erst normal installieren."
        cd "$INSTALL_DIR"
        git pull --ff-only origin main
        if [[ -f "$INSTALL_DIR/pi_helpers/bambu" ]]; then
            cp "$INSTALL_DIR/pi_helpers/bambu" /usr/local/bin/bambu
            chmod +x /usr/local/bin/bambu
        fi
        setup_mdns
        sudo -u "$SERVICE_USER" docker compose up -d --build
        ok "Aktualisiert."
        exit 0
    fi

    if [[ "$MODE" == "configure" ]]; then
        [[ -f "$INSTALL_DIR/pi_backend/.env.example" ]] || err "Nichts installiert. Erst normal installieren."
        # Alte Werte als Vorschlag laden
        wizard
        setup_mdns
        cd "$INSTALL_DIR"
        sudo -u "$SERVICE_USER" docker compose up -d --build
        ok "Neu konfiguriert und neu gestartet."
        print_summary
        exit 0
    fi

    preflight
    install_base
    install_docker
    install_compose
    install_tailscale
    setup_user_repo
    wizard
    setup_mdns
    setup_tailscale
    check_slicer
    deploy
    print_summary
}

main "$@"
