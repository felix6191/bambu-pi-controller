# Bambu Pi Controller

Dein Bambu Lab A1 — vom iPhone aus überwachen und steuern, von überall. Der Raspberry Pi ist die Brücke, Tailscale der sichere Tunnel. Keine Vorkenntnisse nötig.

## 🚀 In 3 Schritten startklar (kein Vorwissen nötig)

**Schritt 1 · Pi vorbereiten:** Raspberry Pi OS auf SD-Karte flashen, Pi starten, ins gleiche WLAN wie den Drucker bringen.

**Schritt 2 · Ein Befehl auf dem Pi** (Terminal öffnen, einfügen, Enter — der Rest ist ein geführter Dialog auf Deutsch):

```bash
curl -fsSL https://raw.githubusercontent.com/felix6191/bambu-pi-controller/main/install.sh | sudo bash
```

Der Installer prüft alles selbst und fragt dich Schritt für Schritt: Drucker-IP, Seriennummer, Access Code (steht alles am Drucker-Display bzw. auf dem Aufkleber — mit Anleitung). Falsche Eingaben werden sofort bemängelt, die Drucker-Erreichbarkeit wird getestet, Tailscale-Login geht per Link. Am Ende zeigt er dir **genau die 2 Werte, die du ins iPhone tippen musst** (werden auch in `IPHONE_SETUP.txt` gespeichert, jederzeit via `sudo bambu iphone` erneut anzeigbar).

**Schritt 3 · iPhone:** App öffnen → Einrichtung folgen (oder Demo-Modus zum Ausprobieren) → die 2 Werte vom Pi-Bildschirm eintragen → „Verbindung testen" → ✅ fertig.

**Später auf dem Pi (alles mit einem Wort):**
| Befehl | Was passiert |
|---|---|
| `sudo bambu status` | Läuft alles? Adressen anzeigen |
| `sudo bambu iphone` | Server-URL + Token erneut anzeigen |
| `sudo bambu logs` | Live-Protokoll |
| `sudo bambu update` | Aktualisieren |
| `sudo bambu reconfigure` | Druckerdaten korrigieren |

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

### Raspberry Pi 4
- Raspberry Pi OS (64-bit) oder Ubuntu Server 22.04+
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

### 3. Tailscale einrichten
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
# Auth-Key erstellen: https://login.tailscale.com/admin/settings/keys
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
In der App unter **Einstellungen**:
- **Server URL**: `http://<tailscale-ip-des-pi>:8000`
- **API Token**: Der gleiche wie in `.env` auf dem Pi
- **Tailscale verwenden**: AN
- **Auto-Verbinden**: AN
- **Verbindung testen** tippen

## Projektstruktur

```
bambu-pi-controller/
├── pi_backend/                 # Python FastAPI Backend
│   ├── app/
│   │   ├── api/               # REST Endpoints
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
├── install.sh                 # One-click installer
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

Alle Endpoints (außer `/health`) benötigen `Authorization: Bearer <API_TOKEN>`.

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
- Entwicklermodus an? IP korrekt? Access Code korrekt?
- Logs: `docker compose logs bambu-controller`
- MQTT testen: `mosquitto_sub -h <PRINTER_IP> -u bblp -P <ACCESS_CODE> -t 'device/+/push'`

### Kein Remote-Zugriff
- Tailscale auf Pi & iPhone laufen?
- `tailscale ip -4` auf Pi zeigt 100.x.x.x?
- In App: Tailscale-IP des Pi nutzen, nicht LAN-IP

### Kamera geht nicht
- A1 Kamera-Stream URL: `http://<PRINTER_IP>:8080/stream`
- In `.env`: `CAMERA_URL=http://192.168.1.100:8080/stream`

## Sicherheit

- **API Token**: Zufälligen 32-Byte Token generieren (`openssl rand -hex 32`)
- **Tailscale**: End-to-End verschlüsselt, kein Port-Forwarding nötig
- **MQTT**: Nur im lokalen LAN, keine Internet-Exposition

## Lizenz

MIT License - Frei für private Nutzung.