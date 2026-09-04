# Bambu Pi Controller

Lokale Steuerung für Bambu Lab A1 3D-Drucker über Raspberry Pi mit iOS App (SwiftUI) und sicherer Remote-Zugriff via Tailscale.

## 🚀 One-Click Installation (Empfohlen)

**Auf dem Raspberry Pi ausführen:**

```bash
curl -fsSL https://raw.githubusercontent.com/DEIN_USERNAME/bambu-pi-controller/main/install.sh | sudo bash
```

Oder lokal nach Clone:
```bash
git clone https://github.com/DEIN_USERNAME/bambu-pi-controller.git
cd bambu-pi-controller
sudo ./install.sh
```

Der Installer macht **alles automatisch**:
- ✅ Docker & Docker Compose installieren
- ✅ Tailscale installieren & verbinden
- ✅ Repository klonen
- ✅ **Interaktiv Drucker-Daten abfragen** (IP, Serial, Access Code)
- ✅ Sicheren API-Token generieren
- ✅ Container bauen & starten
- ✅ Health Check warten
- ✅ Zusammenfassung mit allen Zugriffsdaten anzeigen

**Danach:** iOS App in Xcode öffnen → auf iPhone installieren → Einstellungen eintragen → läuft weltweit.

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

### Raspberry Pi 4
- Raspberry Pi OS (64-bit) oder Ubuntu Server 22.04+
- Docker & Docker Compose
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

## Installation

### 1. Repository klonen
```bash
git clone <repo-url>
cd bambu-pi-controller
```

### 2. Pi Backend konfigurieren
```bash
cd pi_backend
cp .env.example .env
# .env bearbeiten mit deinen Drucker-Daten:
# PRINTER_HOST=192.168.1.100
# PRINTER_SERIAL=01S00A123456789
# PRINTER_ACCESS_CODE=12345678
# API_TOKEN=<openssl rand -hex 32>
```

### 3. Tailscale einrichten (für Remote-Zugriff)
```bash
# Auf dem Pi:
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up

# Auth-Key erstellen: https://login.tailscale.com/admin/settings/keys
# In .env eintragen:
# TAILSCALE_AUTHKEY=tskey-xxxxxx
```

### 4. Docker Compose starten
```bash
cd ..
docker compose up -d --build
```

Logs prüfen:
```bash
docker compose logs -f bambu-controller
```

Health Check:
```bash
curl http://localhost:8000/health
# {"status":"ok","printer_connected":"true"}
```

### 5. iOS App bauen
1. `ios_app/BambuController.xcodeproj` in Xcode öffnen
2. Team & Bundle Identifier setzen
3. Auf iPhone deployen (Cmd+R)

### 6. App konfigurieren
In der App unter **Einstellungen**:
- **Server URL**: `http://<tailscale-ip-des-pi>:8000` (z.B. `http://100.x.x.x:8000`)
- **API Token**: Der gleiche wie in `.env` auf dem Pi
- **Tailscale verwenden**: AN
- **Auto-Verbinden**: AN
- **Verbindung testen** tippen

## Projektstruktur

```
bambu-pi-controller/
├── pi_backend/                 # Python FastAPI Backend
│   ├── app/
│   │   ├── api/               # REST Endpoints (printer, camera, system)
│   │   ├── core/              # Config, Settings
│   │   ├── mqtt/              # Bambu MQTT Client & Protocol
│   │   └── main.py            # FastAPI App + WebSocket
│   ├── Dockerfile
│   ├── pyproject.toml
│   └── .env.example
├── ios_app/
│   └── BambuController/       # SwiftUI iOS App
│       ├── Models/            # Data Models
│       ├── Services/          # APIService, WebSocketService
│       ├── ViewModels/        # PrinterViewModel
│       ├── Views/             # Dashboard, Controls, Camera, Settings
│       └── Extensions/        # Color extensions
├── docker-compose.yml         # Pi + Tailscale
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
| `/api/v1/printer/speed` | POST | Speed setzen |
| `/api/v1/printer/flow` | POST | Flow setzen |
| `/api/v1/camera/stream` | GET | MJPEG Stream |
| `/api/v1/camera/snapshot` | GET | Einzelbild |

Alle Endpoints (außer `/health`) benötigen `Authorization: Bearer <API_TOKEN>`.

## WebSocket Messages

**Status Update** (regelmäßig):
```json
{
  "type": "status",
  "data": {
    "state": "printing",
    "nozzle_temp": 210.5,
    "nozzle_target_temp": 210,
    "bed_temp": 60.0,
    "bed_target_temp": 60,
    "chamber_temp": 32.5,
    "print_job": {...},
    "wifi_signal": -45,
    "error_code": 0,
    "fan_speed": 80,
    "print_speed": 100,
    "flow_rate": 100
  }
}
```

**Event** (einmalig bei Änderungen):
```json
{
  "type": "event",
  "data": {...}
}
```

## Entwicklung

### Pi Backend
```bash
cd pi_backend
python -m venv venv
source venv/bin/activate
pip install -e ".[dev]"

# Linting
ruff check .
ruff format .

# Type checking
mypy app

# Tests
pytest

# Lokal starten
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

### iOS App
```bash
cd ios_app
# In Xcode öffnen und bauen
# Oder per CLI:
xcodebuild -project BambuController.xcodeproj -scheme BambuController build
```

## Troubleshooting

### Drucker verbindet nicht
- Prüfen: Entwicklermodus an? IP korrekt? Access Code korrekt?
- Logs: `docker compose logs bambu-controller`
- MQTT testen: `mosquitto_sub -h <PRINTER_IP> -u bblp -P <ACCESS_CODE> -t 'device/+/push'`

### Kein Remote-Zugriff
- Tailscale auf Pi & iPhone laufen?
- `tailscale ip -4` auf Pi zeigt 100.x.x.x?
- In App: Tailscale-IP des Pi nutzen, nicht LAN-IP

### Kamera geht nicht
- A1 Kamera-Stream URL: `http://<PRINTER_IP>:8080/stream` (manchmal andere Port)
- In `.env`: `CAMERA_URL=http://192.168.1.100:8080/stream`

## Sicherheit

- **API Token**: Zufälligen 32-Byte Token generieren (`openssl rand -hex 32`)
- **Tailscale**: End-to-End verschlüsselt, kein Port-Forwarding nötig
- **MQTT**: Nur im lokalen LAN, keine Internet-Exposition
- **CORS**: In Produktion auf Tailscale-IPs beschränken

## Lizenz

MIT License - Frei für private Nutzung.