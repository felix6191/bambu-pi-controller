#!/bin/bash
# Bambu Pi Controller — One-Click Installer für Raspberry Pi + Bambu Lab A1
#
# Einziger Installationsweg (kein Custom-Image, kein Flashen nötig):
# Standard Raspberry Pi OS (64-bit) per offiziellem Pi Imager auf SD-Karte,
# Pi starten, dann genau 1 Befehl auf dem Pi:
#   curl -fsSL https://raw.githubusercontent.com/felix6191/bambu-pi-controller/main/install.sh | sudo bash
#
# Am Pi muss gar nichts eingetippt werden: Der Installer fragt KEINE
# Druckerdaten ab. Der Pi startet ohne Drucker; die iPhone-App findet ihn,
# verbindet sich und richtet den Drucker ein. Fernzugriff läuft über einen
# Cloudflare Quick Tunnel (kein Konto, kein Login) und wird später in der
# App aktiviert.
#
# Flags:
#   --configure   Zugangs-Token neu erzeugen (Druckerdaten bleiben)
#   --update      Repo aktualisieren + Container neu bauen
# Umgebungsvariablen (optional, nur für Profis):
#   PRINTER_HOST PRINTER_SERIAL PRINTER_ACCESS_CODE API_TOKEN

set -e
trap 'echo ""; echo "[FEHLER] Abgebrochen. Einfach erneut starten — der Installer macht da weiter, wo er war."' ERR

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
REPO_URL="https://github.com/felix6191/bambu-pi-controller.git"
INSTALL_DIR="/opt/bambu-pi-controller"
SERVICE_USER="bambu"
ENV_FILE="$INSTALL_DIR/pi_backend/.env"
BUILT_MARKER="$INSTALL_DIR/.built_commit"

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
    title "Schritt 0/5 · System prüfen"
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
    title "Schritt 1/5 · Grundprogramme installieren"
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

update_repo() {
    # Dateien auf den neuesten Stand bringen. Bewusst robust:
    #  - git als SERVICE_USER (sonst "dubious ownership" als root -> Pull scheitert still)
    #  - fetch + hard reset, damit lokale Änderungen das Update nicht blockieren
    #  - ungetrackte Dateien (.env, IPHONE_SETUP.txt) bleiben erhalten
    if [[ ! -d "$INSTALL_DIR/.git" ]]; then return 1; fi
    git config --global --add safe.directory "$INSTALL_DIR" >/dev/null 2>&1 || true
    log "Lade neueste Dateien …"
    if ! sudo -u "$SERVICE_USER" git -C "$INSTALL_DIR" fetch --depth 1 origin main >/dev/null 2>&1 \
       && ! git -C "$INSTALL_DIR" fetch --depth 1 origin main >/dev/null 2>&1; then
        warn "Konnte keine neuen Dateien laden (Internet? GitHub?). Nutze vorhandene."
        return 1
    fi
    if sudo -u "$SERVICE_USER" git -C "$INSTALL_DIR" reset --hard FETCH_HEAD >/dev/null 2>&1 \
       || git -C "$INSTALL_DIR" reset --hard FETCH_HEAD >/dev/null 2>&1; then
        chown -R "$SERVICE_USER:$SERVICE_USER" "$INSTALL_DIR" 2>/dev/null || true
        ok "Dateien aktualisiert ($(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo '?'))"
        return 0
    fi
    warn "Konnte Dateien nicht übernehmen — nutze vorhandene."
    return 1
}

setup_user_repo() {
    title "Schritt 2/5 · Programmdateien holen"
    if ! id "$SERVICE_USER" &>/dev/null; then
        useradd -r -m -s /bin/bash "$SERVICE_USER"
        usermod -aG docker "$SERVICE_USER"
    fi
    if [[ -d "$INSTALL_DIR/.git" ]]; then
        update_repo || true
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

wizard() {
    local env="$ENV_FILE"
    title "Schritt 3/5 · Grundkonfiguration (Drucker später in der App)"
    # Wichtig: Druckerdaten werden NICHT mehr auf der Kommandozeile abgefragt.
    # Der Pi startet ohne Druckerdaten; die iPhone-App scannt und richtet alles ein.
    ok "Der Drucker wird per iPhone-App eingerichtet — hier musst du nichts eingeben."
    echo ""

    # Profis können die Werte optional per Umgebungsvariable vorgeben.
    local old_host="" old_serial="" old_code=""
    if [[ -f "$ENV_FILE" ]]; then
        old_host=$(grep "^PRINTER_HOST=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
        old_serial=$(grep "^PRINTER_SERIAL=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
        old_code=$(grep "^PRINTER_ACCESS_CODE=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
    fi
    PRINTER_HOST="${PRINTER_HOST:-$old_host}"
    PRINTER_SERIAL="${PRINTER_SERIAL:-$old_serial}"
    PRINTER_ACCESS_CODE="${PRINTER_ACCESS_CODE:-$old_code}"

    # API-Token: behalten oder neu erzeugen
    if [[ -z "${API_TOKEN:-}" ]]; then
        API_TOKEN=$(grep "^API_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
        [[ -z "$API_TOKEN" || "$API_TOKEN" == "your-secure-api-token-here" ]] && API_TOKEN=$(openssl rand -hex 32)
    fi

    # .env atomar schreiben
    local tmp
    tmp=$(mktemp)
    {
        echo "# Automatisch erstellt von install.sh — Druckerdaten kommen aus der App."
        echo "PRINTER_HOST=$PRINTER_HOST"
        echo "PRINTER_SERIAL=$PRINTER_SERIAL"
        echo "PRINTER_ACCESS_CODE=$PRINTER_ACCESS_CODE"
        echo "PRINTER_PORT=8883"
        echo "PRINTER_USE_TLS=true"
        echo "HOST=0.0.0.0"
        echo "PORT=8000"
        echo "LOG_LEVEL=INFO"
        echo "API_TOKEN=$API_TOKEN"
        echo "# CAMERA_URL="
    } > "$tmp"
    mkdir -p "$(dirname "$ENV_FILE")"
    mv "$tmp" "$ENV_FILE"
    chown "$SERVICE_USER:$SERVICE_USER" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    ok "Zugangs-Token gespeichert"
}

# ------------------------------------------------------------- mdns ---

setup_mdns() {
    title "Schritt 4/5 · iPhone-Findung einrichten (Auto-Discovery)"
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

# ---------------------------------------------------------------- deploy ---

clean_old() {
    # Alles Alte vom Programm entfernen, damit keine Altlasten Fehler machen
    # und der Speicher nicht vollläuft (der Slicer-Container ist groß).
    # Wichtig: KEIN `down -v` / `volume prune` — sonst gehen Druckerdaten,
    # Token und Uploads im /data-Volume verloren.
    log "Räume alte Container, Images und Build-Cache auf …"
    ( cd "$INSTALL_DIR" && sudo -u "$SERVICE_USER" docker compose down \
        --remove-orphans --rmi local ) >/dev/null 2>&1 || true
    # Verwaiste Container/Netzwerke früherer Versionen freigeben
    sudo -u "$SERVICE_USER" docker container prune -f >/dev/null 2>&1 || true
    # Alte, nicht mehr benutzte Images + Build-Cache freigeben
    sudo -u "$SERVICE_USER" docker image prune -f >/dev/null 2>&1 || true
    sudo -u "$SERVICE_USER" docker builder prune -f >/dev/null 2>&1 || true
}

fix_data_perms() {
    # Bestehende Installationen: das Volume /data wurde früher als root
    # angelegt, wodurch die App pairing.json nicht schreiben konnte (HTTP 500).
    # Einmalig als root korrigieren — harmlos, wenn es schon passt.
    log "Prüfe Daten-Rechte …"
    ( cd "$INSTALL_DIR" && sudo -u "$SERVICE_USER" docker compose run --rm -T --no-deps \
        --user root --entrypoint /bin/sh bambu-controller \
        -c 'chown -R appuser:appuser /data 2>/dev/null || true' ) >/dev/null 2>&1 || true
}

reset_pairing_state() {
    # Bei jedem Build/Update das Verbindungsgerät zurücksetzen, damit sich
    # wieder jedes (neue) Handy verbinden kann — sonst: "gehört schon zu einem
    # Handy" (HTTP 403). Der API_Token bleibt gleich, ein bereits verbundenes
    # Handy funktioniert also weiter.
    local token
    token=$(grep "^API_TOKEN=" "$ENV_FILE" 2>/dev/null | cut -d= -f2)
    if [[ -n "$token" ]] && curl -sf -X POST -H "Authorization: Bearer $token" \
        http://localhost:8000/api/v1/pairing/reset >/dev/null 2>&1; then
        ok "Verbindungsgerät zurückgesetzt — jedes Handy kann sich neu verbinden."
        return 0
    fi
    # Fallback ohne laufenden Server: Pairing-Datei im Volume entfernen.
    ( cd "$INSTALL_DIR" && sudo -u "$SERVICE_USER" docker compose run --rm -T --no-deps \
        --user root --entrypoint /bin/sh bambu-controller \
        -c 'rm -f /data/pairing.json' ) >/dev/null 2>&1 || true
    ok "Verbindungsgerät zurückgesetzt (Fallback)."
}

reset_pairing_when_ready() {
    # Kurz auf den Server warten, dann Pairing zurücksetzen (Fallback greift
    # trotzdem, auch wenn der Server noch nicht antwortet).
    for _ in $(seq 1 20); do
        curl -sf http://localhost:8000/health >/dev/null 2>&1 && break
        sleep 2
    done
    reset_pairing_state
}

repo_head() { git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || echo ""; }

image_ready() {
    local img
    img="$( cd "$INSTALL_DIR" && sudo -u "$SERVICE_USER" docker compose config --images 2>/dev/null | head -1 )"
    [[ -n "$img" ]] && sudo -u "$SERVICE_USER" docker image inspect "$img" >/dev/null 2>&1
}

mark_built() {
    repo_head > "$BUILT_MARKER" 2>/dev/null || true
    chown "$SERVICE_USER:$SERVICE_USER" "$BUILT_MARKER" 2>/dev/null || true
}

built_is_current() {
    [[ -f "$BUILT_MARKER" ]] || return 1
    local head; head="$(repo_head)"
    [[ -n "$head" && "$(cat "$BUILT_MARKER" 2>/dev/null)" == "$head" ]]
}

deploy() {
    title "Schritt 5/5 · Server starten"
    log "Baue und starte (erster Start lädt Docker-Bilder inkl. Slicer, dauert ein paar Minuten) …"
    cd "$INSTALL_DIR"
    clean_old
    sudo -u "$SERVICE_USER" docker compose build || err "Build fehlgeschlagen. Details: sudo bambu logs"
    fix_data_perms
    sudo -u "$SERVICE_USER" docker compose up -d || err "Start fehlgeschlagen. Details: sudo bambu logs"
    log "Warte, bis der Server antwortet …"
    local ok_health=0
    for _ in $(seq 1 40); do
        if curl -sf http://localhost:8000/health >/dev/null 2>&1; then ok_health=1; break; fi
        sleep 3
    done
    if [[ "$ok_health" -eq 1 ]]; then
        ok "Server läuft!"
        reset_pairing_state
        mark_built
        local health
        health=$(curl -sf http://localhost:8000/health 2>/dev/null || echo "")
        echo "  $health" | grep -q '"printer_connected":true' \
            && ok "Drucker verbunden!" \
            || warn "Server läuft, Drucker meldet sich noch nicht. Einrichtung läuft komplett in der iPhone-App (Pi antippen → Verbinden → Drucker). Logs: 'sudo bambu logs'."
    else
        err "Server antwortet nicht. Details ansehen mit: sudo bambu logs"
    fi
}

write_iphone_sheet() {
    # Lokal bleiben: Heimnetz-IP zuerst. Der Fernzugriff über den Cloudflare
    # Quick Tunnel (kein Login) kommt später in der App dazu.
    local lan_ip api_token server_url
    lan_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    api_token=$(grep "^API_TOKEN=" "$ENV_FILE" | cut -d= -f2)
    server_url="http://$lan_ip:8000"
    {
        echo "Bambu Pi Controller — iPhone Einrichtung"
        echo "========================================"
        echo ""
        echo "Normalfall: App öffnen, den Pi antippen, 'Verbinden' — nichts tippen."
        echo "Nur falls der Pi nicht automatisch gefunden wird, diese Werte eingeben:"
        echo ""
        echo "  Server URL:  $server_url"
        echo "  API Token:   $api_token"
        echo ""
         echo "Fernzugriff von unterwegs: in der App unter Einstellungen → Verbindung → Remote."
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
    echo "  3. Drucker in der App wählen (der Pi sucht ihn selbst) — fertig."
    echo "  4. Fernzugriff von unterwegs: App → Einstellungen → Fernzugriff aktivieren."
    echo ""
    echo "  Falls der Pi nicht automatisch gefunden wird, diese 2 Werte eingeben:"
    echo -e "     ${BOLD}Server URL:${NC}  $IPHONE_URL"
    echo -e "     ${BOLD}API Token:${NC}   $IPHONE_TOKEN"
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
    echo "  sudo bambu reconfigure  Zugangs-Token neu erzeugen"
    echo "  sudo bambu tunnel       Fernzugriff (Cloudflare Quick Tunnel) starten"
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
        update_repo || true
        # Helfer aktualisieren (nach dem Datei-Update!)
        if [[ -f "$INSTALL_DIR/pi_helpers/bambu" ]]; then
            cp "$INSTALL_DIR/pi_helpers/bambu" /usr/local/bin/bambu
            chmod +x /usr/local/bin/bambu
        fi
        setup_mdns
        cd "$INSTALL_DIR"
        # Nur neu bauen, wenn sich der Commit wirklich geändert hat. Sonst
        # reicht ein (idempotentes) Starten. Docker-Layer-Cache bleibt erhalten,
        # dadurch wird nie unnötig der große Orca-Download wiederholt.
        if built_is_current && image_ready; then
            log "Bereits auf dem neuesten Stand ($(git -C "$INSTALL_DIR" rev-parse --short HEAD)) — kein Neubau nötig."
            sudo -u "$SERVICE_USER" docker compose up -d
        else
            log "Baue nur die Änderungen neu (Docker-Cache) …"
            sudo -u "$SERVICE_USER" docker compose build
            fix_data_perms
            sudo -u "$SERVICE_USER" docker compose up -d
            # Alte, jetzt verwaiste Images freigeben — Cache bleibt fürs nächste Update.
            sudo -u "$SERVICE_USER" docker image prune -f >/dev/null 2>&1 || true
        fi
        reset_pairing_when_ready
        if curl -sf http://localhost:8000/health >/dev/null 2>&1; then mark_built; fi
        ok "Aktualisiert ($(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null || echo '?'))."
        exit 0
    fi

    if [[ "$MODE" == "configure" ]]; then
        [[ -f "$INSTALL_DIR/pi_backend/.env.example" ]] || err "Nichts installiert. Erst normal installieren."
        # Alte Werte als Vorschlag laden
        wizard
        setup_mdns
        cd "$INSTALL_DIR"
        # Nur .env geändert -> kein Neubau nötig, Container übernimmt neue Werte.
        fix_data_perms
        sudo -u "$SERVICE_USER" docker compose up -d
        reset_pairing_when_ready
        if curl -sf http://localhost:8000/health >/dev/null 2>&1; then mark_built; fi
        ok "Neu konfiguriert und neu gestartet."
        print_summary
        exit 0
    fi

    preflight
    install_base
    install_docker
    install_compose
    setup_user_repo
    wizard
    setup_mdns
    deploy
    print_summary
}

main "$@"
