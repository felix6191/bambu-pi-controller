# Bambu Pi Controller

Dein Bambu Lab A1 — vom iPhone aus überwachen und steuern, von überall. Der Raspberry Pi ist die Brücke, Tailscale der sichere Tunnel. Keine Vorkenntnisse nötig.

> ## ⚡ Schnellinstallation auf dem Pi — 1 Befehl
> Standard **Raspberry Pi OS (64-bit)** per offiziellem **Raspberry Pi Imager** flashen, Pi starten, Terminal öffnen, einfügen, Enter:
> ```bash
> curl -fsSL https://raw.githubusercontent.com/felix6191/bambu-pi-controller/main/install.sh | sudo bash
> ```
> Bei allen Fragen einfach **ENTER** drücken (nichts tippen — der Rest passiert in der App). Danach: App öffnen → Pi antippen → **Verbinden** → Drucker wählen → ✅ fertig.

## 🚀 In 3 Schritten startklar (kein Vorwissen nötig, kein Custom-Image)

**Schritt 1 · Pi vorbereiten:** Ganz normales **Raspberry Pi OS (64-bit)** per offiziellem **Raspberry Pi Imager** auf SD-Karte flashen, Pi starten, ins gleiche WLAN wie den Drucker bringen. Es ist kein spezielles Image nötig.

**Schritt 2 · Ein Befehl auf dem Pi** (Terminal öffnen, einfügen, Enter — der Rest läuft von selbst):

```bash
curl -fsSL https://raw.githubusercontent.com/felix6191/bambu-pi-controller/main/install.sh | sudo bash
```

Der Installer prüft alles selbst (System, Docker, Auto-Discovery per mDNS) und installiert den OrcaSlicer mit (STL→G-code auf dem Pi, kein separater Download). **Der Installer fragt keinerlei Druckerdaten ab und verlangt keinen Login** — der Pi startet einfach. Alles Weitere (Drucker finden, verbinden, STL slicen, Fernzugriff) passiert in der iPhone-App. Optional zeigt er die 2 Werte (Server-URL + Token) für den Notfall; gespeichert in `IPHONE_SETUP.txt`, jederzeit via `sudo bambu iphone`.

**Schritt 3 · iPhone:** App öffnen → Einrichtung folgen (oder Demo-Modus zum Ausprobieren) → der Pi **erscheint von allein** → antippen → **„Verbinden"** (nichts abtippen, Token kommt per Pairing automatisch) → der Pi sucht den Drucker im WLAN → IP/Code bestätigen → ✅ fertig. Fernzugriff von unterwegs aktivierst du später in der App unter **Einstellungen → Fernzugriff (Tailscale)**.

**Später auf dem Pi (alles mit einem Wort):**
| Befehl | Was passiert |
|---|---|
| `sudo bambu status` | Läuft alles? Adressen anzeigen |
| `sudo bambu iphone` | Server-URL + Token erneut anzeigen |
| `sudo bambu logs` | Live-Protokoll |
| `sudo bambu update` | Aktualisieren (lädt neue Dateien, räumt alte Container/Images/Build-Cache auf, baut neu) |
| `sudo bambu reconfigure` | Zugangs-Token neu erzeugen |
| `sudo bambu tailscale` | Fernzugriff per Tailscale-Login aktivieren |

---

## Architektur

```
┌─────────────┐     MQTT (LAN)      ┌──────────────┐
│ Bambu A1    │ ◄─────────────────► │ Raspberry Pi │
│ 3D-Drucker  │                     │  (FastAPI)   │
└─────────────┘                     └──────┬───────┘
                                            │
                              ┌─────────────┴─────────────┐
                              │       Tailscale VPN        │
                              └─────────────┬─────────────┘
                                            │
                              ┌─────────────▼─────────────┐
                              │      iPhone (iOS App)      │
                              │     (SwiftUI + WS)         │
                              └────────────────────────────┘
```

## Features

- **Echtzeit-Status**: Temperatur, Fortschritt, Layer, Filament via WebSocket
- **Druckersteuerung**: Start, Pause, Fortsetzen, Stopp
- **Temperaturregelung**: Düse, Bett, Kammer
- **Speed & Flow**: Druckgeschwindigkeit und Flow-Rate anpassen
- **Kamera**: MJPEG-Stream & Snapshots vom A1
- **Remote-Zugriff**: Weltweit über Tailscale (keine Port-Forwarding nötig)
- **Sicherheit**: Token-basierte Auth, lokaler MQTT, verschlüsseltes VPN

## Voraussetzungen

### Raspberry Pi (kein Custom-Image nötig)
- Standard Raspberry Pi OS (64-bit) oder Ubuntu Server 22.04+
- Im gleichen LAN wie der Bambu A1

### Bambu Lab A1
- Entwicklermodus aktiviert (Einstellungen → Allgemein → Entwicklermodus)
- MQTT-Zugangsdaten notieren:
  - IP-Adresse des Druckers
  - Seriennummer (auf Aufkleber/Verpackung)
  - Zugangscode (8-stellig, in Bambu Handy App unter Gerät → Einstellungen → MQTT)

### iPhone
- iOS 17+
- Xcode 15+ zum Bauen
- Tailscale App installiert

## Manuelle Installation (falls gewünscht)

### 1. Repository klonen
```bash
git clone <repo-url>
cd bambu-pi-controller
```

### 2. Pi Backend konfigurieren
```bash
cd pi_backend
cp .env.example .env
# .env bearbeiten mit deinen Drucker-Daten
```

### 3. Tailscale einrichten (optional, erst für Fernzugriff)
```bash
# Installation passiert schon durch install.sh; Login bei Bedarf:
sudo bambu tailscale
# Oder aus der App: Einstellungen → Fernzugriff aktivieren
```

### 4. Docker Compose starten
```bash
cd ..
docker compose up -d --build
```

### 5. iOS App bauen
1. `ios_app/BambuController.xcodeproj` in Xcode öffnen
2. Team & Bundle Identifier setzen
3. Auf iPhone deployen (Cmd+R)

### 6. App konfigurieren
Normalfall: nichts tippen — App öffnen, Pi antippen, „Verbinden".
Nur als Fallback (z. B. Tailscale von unterwegs) in der App unter **Einstellungen**:
- **Server URL**: `http://<tailscale-ip-des-pi>:8000`
- **API Token**: Der gleiche wie in `.env` auf dem Pi (`sudo bambu iphone` zeigt ihn)
- **Tailscale verwenden**: AN
- **Auto-Verbinden**: AN
- **Verbindung testen** tippen

## Projektstruktur

```
bambu-pi-controller/
├── pi_backend/                 # Python FastAPI Backend
│   ├── app/
│   │   ├── api/               # REST Endpoints (inkl. Pairing ohne Tippen)
│   │   ├── core/              # Config, Settings
│   │   ├── mqtt/              # Bambu MQTT Client & Protocol
│   │   └── main.py            # FastAPI App + WebSocket
│   ├── Dockerfile
│   ├── pyproject.toml
│   └── .env.example
├── ios_app/
│   └── BambuController/       # SwiftUI iOS App
│       ├── Models/            # Data Models
│       ├── Services/          # APIService, WebSocketService, PiDiscovery (mDNS)
│       ├── ViewModels/        # PrinterViewModel
│       ├── Views/             # Dashboard, Controls, Camera, Settings, SetupFlow
│       └── Extensions/        # Color extensions
├── pi_helpers/
│   ├── bambu                  # Helfer: sudo bambu {status|iphone|logs|update|…}
│   └── bambu-pi-avahi.service # mDNS-Anzeige _bambu-pi._tcp (richtet install.sh ein)
├── docker-compose.yml         # Pi + Tailscale
├── install.sh                 # One-Click Installer (einziger Installationsweg)
├── deploy.sh                  # Deploy helper
└── README.md
```

## API Endpunkte

| Endpoint | Methode | Beschreibung |
|----------|---------|--------------|
| `/health` | GET | Health Check |
| `/ws` | WS | Real-time Updates |
| `/api/v1/printer/status` | GET | Drucker Status |
| `/api/v1/printer/print/start` | POST | Druck starten |
| `/api/v1/printer/print/pause` | POST | Pausieren |
| `/api/v1/printer/print/resume` | POST | Fortsetzen |
| `/api/v1/printer/print/stop` | POST | Stopp |
| `/api/v1/printer/temperature` | POST | Temps setzen |
| `/api/v1/printer/speed` | POST | Speed setzen (%, wird auf 1–4 Presets gemappt) |
| `/api/v1/printer/speed-level` | POST | Offizielles Speed-Preset (1=Silent, 2=Standard, 3=Sport, 4=Ludicrous) |
| `/api/v1/printer/flow` | POST | Flow setzen (M221) |
| `/api/v1/printer/light` | POST | Bauraumlicht an/aus |
| `/api/v1/printer/capabilities` | GET | Offizielle A1-Limits (Düse 300 °C, Bett 100 °C, Speed-Presets) |
| `/api/v1/camera/stream` | GET | MJPEG Stream |
| `/api/v1/camera/snapshot` | GET | Einzelbild |
| `/api/v1/system/printer-config` | GET/POST | Druckerdaten lesen / per iPhone setzen + verbinden |
| `/api/v1/files/upload` | POST | STL/3MF/OBJ/STEP hochladen (multipart, max. 200 MB) |
| `/api/v1/files/jobs` | GET | Alle Slice-/Druckjobs |
| `/api/v1/files/jobs/{id}` | GET/DELETE | Job-Status / löschen |
| `/api/v1/files/jobs/{id}/slice` | POST | Slicen starten (filament, quality, supports, infill) |
| `/api/v1/files/jobs/{id}/print` | POST | Per FTP auf Drucker-SD laden + Druck starten |
| `/api/v1/files/profiles` | GET | Verfügbare Filamente, Qualitäten, Slicer |
| `/api/v1/system/remote-access` | GET/POST | Fernzugriff-Status / Tailscale-Login aus der App starten |

Alle Endpoints (außer `/health`) benötigen `Authorization: Bearer <API_TOKEN>`.

## STL → Druck (Teilen → Slicen → Drucken)

App: Datei importieren → Filament (PLA/PETG/TPU/ASA), Qualität (Entwurf/Standard/Fein), Stützen, Infill wählen → Slicen → Drucken. Status live: `uploaded → queued → slicing → sliced → uploading → starting → printing`.

**Slicer ist im Docker-Image enthalten** — kein manueller Download nötig. Der Backend-Container basiert auf Ubuntu 24.04 und bringt das offizielle **OrcaSlicer ARM64** mit (nur so passt das glibc des AppImages). Der Slicer nutzt die mitgelieferten Bambu-A1-Profile und legt die App-Optionen (Stützen/Infill/Schichthöhe/Temperaturen) als Override-Obendrauf. Steuerung per `SLICER_MODE=orca`, `SLICER_CMD=orcaslicer`, `ORCA_PROFILES=/opt/orcaslicer/resources/profiles/BBL` (Dockerfile).

Für den alten PrusaSlicer-kompatiblen Weg: `SLICER_MODE=prusa` setzen und Profile in `pi_backend/profiles/` (A1-Community-Presets, Düse 300 °C / Bett 100 °C) verwenden. Template-Platzhalter: `{cmd} {out} {machine} {filament} {process} {input}` (+ `{overrides}`).

Der G-Code landet per FTP (Port 22, Fallback 21, User `bblp`) auf der Drucker-SD und wird per `gcode_file`-MQTT-Befehl gestartet.

## Entwicklung

### Pi Backend
```bash
cd pi_backend
python -m venv venv && source venv/bin/activate
pip install -e ".[dev]"
ruff check . && ruff format .
mypy app
pytest
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

### iOS App
```bash
cd ios_app
# In Xcode öffnen und bauen (Cmd+R)
```

## Troubleshooting

### Drucker verbindet nicht
- Der Pi findet den Drucker per **SSDP** (Standard-Discovery von Bambu Lab) — der Drucker muss dafür im **LAN-/Entwicklermodus** sein (nicht Cloud-Modus). Fallback ist ein Port-Scan der Heimnetz-IPs auf 8883.
- Der Container läuft im **Host-Netz**; nach dem Update einmal neu bauen: `sudo bambu update`.
- Entwicklermodus an? IP korrekt? Access Code (8 Zeichen) und Seriennummer korrekt?
- Der Pi prüft erst, ob Port 8883 offen ist, und unterscheidet in der App „nicht erreichbar" von „erreichbar, aber Zugangsdaten falsch".
- Logs: `docker compose logs bambu-controller`
- MQTT testen: `mosquitto_sub -h <PRINTER_IP> -u bblp -P <ACCESS_CODE> -t 'device/+/push'`

### App merkt sich alte Einrichtung
- Solange das Tutorial **nicht komplett abgeschlossen** wurde, setzt die App ihre Einstellungen bei jedem frischen Start zurück (Pi wird wieder freigegeben und neu gesucht). Nach abgeschlossenem Setup bleiben die Einstellungen erhalten.

### Kein Remote-Zugriff
- Erst in der App: **Einstellungen → Fernzugriff aktivieren** (öffnet die Tailscale-Anmeldung).
- Alternativ am Pi: `sudo bambu tailscale`
- `tailscale ip -4` auf Pi zeigt 100.x.x.x? Dann in der App „Diese Adresse jetzt nutzen".

### Pairing schlägt fehl (Fehler 500)
- Früher verursachten falsche Rechte am Docker-Volume `/data` den 500er — ist behoben.
- Nach dem Update einmal neu bauen: `sudo bambu update`
- Logs: `docker compose logs bambu-controller`

### Slicen schlägt fehl
- Logs ansehen: `sudo bambu logs` — der genaue OrcaSlicer-Fehler steht dort.
- Image neu bauen (enthält den Slicer): `sudo bambu update`

### Kamera geht nicht
- A1 Kamera-Stream URL: `http://<PRINTER_IP>:8080/stream`
- In `.env`: `CAMERA_URL=http://192.168.1.100:8080/stream`

## Sicherheit

- **API Token**: Zufälligen 32-Byte Token generieren (`openssl rand -hex 32`)
- **Tailscale**: End-to-End verschlüsselt, kein Port-Forwarding nötig
- **MQTT**: Nur im lokalen LAN, keine Internet-Exposition

## Lizenz

MIT License - Frei für private Nutzung.