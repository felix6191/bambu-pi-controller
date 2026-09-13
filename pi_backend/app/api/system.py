"""System API routes."""
import ipaddress
import json
import os
import shutil
import socket
import subprocess
import time
from pathlib import Path
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
import psutil
import platform
from loguru import logger

from app.core.config import settings, persisted_printer_file
from app.core import state as app_state

router = APIRouter()

TAILSCALE = "tailscale"
TS_HOSTNAME = "bambu-pi"


def _env_file() -> Path:
    # <repo>/pi_backend/.env regardless of the process working directory
    return Path(__file__).resolve().parents[2] / ".env"


class PrinterConfigRequest(BaseModel):
    printer_host: str = Field(..., min_length=7, max_length=45)
    printer_serial: str = Field(..., min_length=4, max_length=64)
    printer_access_code: str = Field(..., min_length=8, max_length=8)


class PrinterConfigResult(BaseModel):
    success: bool
    printer_connected: bool
    message: str


@router.get("/printer-config")
async def get_printer_config():
    """What the Pi currently knows (never exposes the access code)."""
    client = app_state.printer_client
    return {
        "configured": bool(settings.printer_host and settings.printer_serial),
        "printer_host": settings.printer_host or None,
        "printer_serial": settings.printer_serial or None,
        "printer_port": settings.printer_port,
        "printer_connected": bool(client is not None and client.connected),
    }


@router.post("/printer-config", response_model=PrinterConfigResult)
async def set_printer_config(request: PrinterConfigRequest):
    """Phone-based setup: store printer credentials on the Pi and connect now.

    Lets users walk to the printer with their phone, type the values shown on
    the display/sticker, and tap continue — no SSH needed.
    """
    host = request.printer_host.strip()
    try:
        ipaddress.ip_address(host)
    except ValueError:
        raise HTTPException(status_code=400, detail="Keine gültige IP-Adresse (z. B. 192.168.1.50)")
    if not request.printer_serial.strip():
        raise HTTPException(status_code=400, detail="Seriennummer fehlt")

    settings.printer_host = host
    settings.printer_serial = request.printer_serial.strip()
    settings.printer_access_code = request.printer_access_code

    # Dauerhaft im Volume speichern — die .env im Container würde bei jedem
    # Neubau verworfen. Beim Start lädt config.py diese Datei.
    try:
        path = persisted_printer_file()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "printer_host": settings.printer_host,
            "printer_serial": settings.printer_serial,
            "printer_access_code": settings.printer_access_code,
        }), encoding="utf-8")
        try:
            os.chmod(path, 0o600)
        except Exception:
            pass
    except Exception as e:
        logger.error(f"Failed to persist printer config: {e}")
        raise HTTPException(status_code=500, detail="Konnte Konfiguration nicht speichern")

    # Erst prüfen, ob der Drucker überhaupt erreichbar ist (Port 8883),
    # dann MQTT verbinden — mit ein paar Versuchen (WLAN braucht manchmal kurz).
    reachable = await _printer_port_open(host, settings.printer_port)
    connected = False
    for attempt in range(3):
        connected = await app_state.reconnect_printer()
        if connected:
            break
        import asyncio as _aio
        await _aio.sleep(1.5 * (attempt + 1))

    if connected:
        return PrinterConfigResult(success=True, printer_connected=True,
                                   message="Drucker verbunden! 🎉")
    detail = app_state.last_connect_error or (
        app_state.printer_client.last_error if app_state.printer_client else ""
    )
    detail_txt = f" Fehler: {detail}" if detail else ""
    if not reachable:
        return PrinterConfigResult(
            success=True, printer_connected=False,
            message=f"Drucker unter {host} nicht erreichbar (Port {settings.printer_port}). "
                    "Gleiches WLAN? Drucker an? LAN-Modus am Drucker an? IP prüfen." + detail_txt)
    return PrinterConfigResult(
        success=True, printer_connected=False,
        message="Drucker ist erreichbar, lehnt aber die Verbindung ab. "
                "Access Code (8 Zeichen) und Seriennummer prüfen — LAN-/Entwicklermodus am Drucker an?" + detail_txt)


async def _printer_port_open(host: str, port: int, timeout: float = 3.0) -> bool:
    """TCP-Test: ist der Drucker-MQTT-Port offen? (kein TLS-Handshake nötig)"""
    import asyncio as _aio
    try:
        conn = _aio.open_connection(host, port)
        _reader, writer = await _aio.wait_for(conn, timeout=timeout)
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
        return True
    except Exception:
        return False


# ------------------------------------------------------- remote access (Tailscale) ---

class RemoteAccessResult(BaseModel):
    installed: bool
    state: str
    auth_url: str = ""
    tailscale_ip: str | None = None
    message: str = ""


def _ts_bin() -> str | None:
    return shutil.which(TAILSCALE)


def _ts_status_sync() -> dict | None:
    """`tailscale status --json` im Host-Netz (Socket ist in den Container gemountet)."""
    binary = _ts_bin()
    if binary is None:
        return None
    try:
        proc = subprocess.run([binary, "status", "--json"], capture_output=True, text=True, timeout=6)
    except Exception:
        return None
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        return json.loads(proc.stdout)
    except Exception:
        return None


async def _ts_status() -> dict | None:
    import asyncio as _aio
    return await _aio.get_running_loop().run_in_executor(None, _ts_status_sync)


def _ts_result(data: dict | None, fallback_msg: str = "") -> RemoteAccessResult:
    if data is None:
        return RemoteAccessResult(installed=False, state="unavailable", message=fallback_msg)
    state = str(data.get("BackendState", "unknown"))
    auth = str(data.get("AuthURL", "") or "")
    ips = [ip for ip in (data.get("TailscaleIPs") or []) if ":" not in ip]
    return RemoteAccessResult(installed=True, state=state, auth_url=auth,
                              tailscale_ip=(ips[0] if ips else None))


@router.get("/remote-access", response_model=RemoteAccessResult)
async def remote_access_status():
    """Aktueller Fernzugriff-Status (ohne Login)."""
    if _ts_bin() is None:
        return RemoteAccessResult(installed=False, state="unavailable",
            message="Tailscale fehlt auf dem Pi. Einmal ausführen: sudo bambu tailscale")
    return _ts_result(await _ts_status(), "Tailscale antwortet nicht. Auf dem Pi: sudo bambu tailscale")


@router.post("/remote-access", response_model=RemoteAccessResult)
async def remote_access_start():
    """Fernzugriff aus der App starten: `tailscale up` im Hintergrund, Login-Link liefern."""
    import asyncio as _aio
    binary = _ts_bin()
    if binary is None:
        return RemoteAccessResult(installed=False, state="unavailable",
            message="Tailscale fehlt auf dem Pi. Einmal ausführen: sudo bambu tailscale")
    try:
        subprocess.Popen([binary, "up", "--hostname", TS_HOSTNAME, "--accept-routes"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as e:
        logger.error(f"tailscale up failed: {e}")
        return RemoteAccessResult(installed=True, state="error", message=f"Start fehlgeschlagen: {e}")
    # Kurz warten, bis Login-Link oder Verbindung bereitsteht
    for _ in range(15):
        data = await _ts_status()
        if data is not None:
            state = str(data.get("BackendState", "unknown"))
            auth = str(data.get("AuthURL", "") or "")
            ips = [ip for ip in (data.get("TailscaleIPs") or []) if ":" not in ip]
            if state == "Running" and ips:
                return RemoteAccessResult(installed=True, state=state, tailscale_ip=ips[0],
                                          message="Fernzugriff aktiv.")
            if auth:
                return RemoteAccessResult(installed=True, state=state, auth_url=auth,
                                          message="Zum Aktivieren Link öffnen und anmelden.")
        await _aio.sleep(1)
    return RemoteAccessResult(installed=True, state="starting",
                              message="Anmeldung läuft — bitte gleich den Link öffnen.")


@router.get("/info")
async def system_info():
    return {
        "hostname": platform.node(),
        "platform": platform.platform(),
        "python_version": platform.python_version(),
        "cpu_count": psutil.cpu_count(),
        "cpu_percent": psutil.cpu_percent(interval=0.1),
        "memory": {
            "total": psutil.virtual_memory().total,
            "available": psutil.virtual_memory().available,
            "percent": psutil.virtual_memory().percent,
        },
        "disk": {
            "total": psutil.disk_usage("/").total,
            "free": psutil.disk_usage("/").free,
            "percent": psutil.disk_usage("/").percent,
        },
    }


@router.get("/network")
async def network_info():
    interfaces = {}
    for name, addrs in psutil.net_if_addrs().items():
        interfaces[name] = [
            {"family": str(addr.family), "address": addr.address, "netmask": addr.netmask}
            for addr in addrs
        ]
    return {"interfaces": interfaces}


def _local_prefix() -> str:
    """Eigenes /24 bestimmen (UDP-Trick, kein Traffic). Fallback Heimnetz."""
    import socket as _s
    try:
        sk = _s.socket(_s.AF_INET, _s.SOCK_DGRAM)
        sk.connect(("8.8.8.8", 80))
        ip = sk.getsockname()[0]
        sk.close()
        return ".".join(ip.split(".")[:3])
    except Exception:
        return "192.168.1"


def _is_scan_net(ip: str) -> bool:
    """Nur echte Heimnetz-Interfaces scannen (kein Docker/Tailscale/Loopback)."""
    try:
        a = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if a.is_loopback or a.is_link_local or not a.is_private:
        return False
    # 100.64.0.0/10 = Tailscale/CGNAT, 172.17+/16 = Docker-Bridges
    if str(a).startswith("100.") or ip.startswith("172.17.") or ip.startswith("172.18."):
        return False
    return True


def _local_prefixes() -> list[str]:
    """Alle /24-Präfixe der Heimnetz-Interfaces (host network) + Drucker-IP."""
    prefixes: set[str] = set()
    for name, addrs in psutil.net_if_addrs().items():
        lname = name.lower()
        if lname.startswith(("lo", "docker", "br-", "veth", "tailscale", "tun", "wg")):
            continue
        for addr in addrs:
            if addr.family == socket.AF_INET and _is_scan_net(addr.address):
                prefixes.add(".".join(addr.address.split(".")[:3]))
    # Bereits konfigurierten Drucker direkt mitnehmen
    if settings.printer_host and _is_scan_net(settings.printer_host):
        prefixes.add(".".join(settings.printer_host.split(".")[:3]))
    if not prefixes:
        prefixes.add(_local_prefix())
    return sorted(prefixes)


# Bambu-Drucker melden sich per SSDP (Standardweg, den auch Bambu Studio und
# die Home-Assistant-Integration nutzen) — kein Port-Scan nötig.
SSDP_GROUP = "239.255.255.250"
SSDP_PORT = 1900
SSDP_ST = "urn:bambulab-com:device:3dprinter:1"


def _ssdp_discover_sync(timeout: float = 4.0) -> dict[str, int]:
    """SSDP M-SEARCH senden und Antworten der Bambu-Drucker einsammeln."""
    msg = "\r\n".join([
        "M-SEARCH * HTTP/1.1",
        f"HOST: {SSDP_GROUP}:{SSDP_PORT}",
        'MAN: "ssdp:discover"',
        "MX: 2",
        f"ST: {SSDP_ST}",
        "", "",
    ]).encode()
    found: dict[str, int] = {}
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
        sock.settimeout(0.5)
        sock.bind(("", 0))
        t0 = time.monotonic()
        last_send = 0.0
        end = t0 + timeout
        while time.monotonic() < end:
            # M-SEARCH mehrfach senden — Geräte verpassen den ersten Schuss gern.
            if time.monotonic() - last_send > 1.2:
                try:
                    sock.sendto(msg, (SSDP_GROUP, SSDP_PORT))
                except OSError:
                    pass
                last_send = time.monotonic()
            try:
                data, addr = sock.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            text = data.decode("utf-8", "ignore")
            # Antwort muss von einem Bambu-Drucker kommen (ST/Server/USN prüfen)
            if "bambulab" in text.lower() or SSDP_ST.lower() in text.lower():
                ip = addr[0]
                found[ip] = int((time.monotonic() - t0) * 1000)
        sock.close()
    except Exception as e:
        logger.warning(f"SSDP discovery failed: {e}")
    return found


@router.post("/printer-scan")
async def printer_scan(deep: bool = True):
    """Drucker im Heimnetz finden.

    1) SSDP (Bambu-Standard) — schnell und zuverlässig.
    2) Fallback: TCP-Scan der eigenen /24-Netze auf Port 8883.
    """
    import asyncio as _aio
    loop = _aio.get_running_loop()

    # 1) SSDP
    ssdp = await loop.run_in_executor(None, _ssdp_discover_sync, 4.0)
    found: dict[str, dict] = {ip: {"ip": ip, "ms": ms, "via": "ssdp"} for ip, ms in ssdp.items()}

    # 2) Fallback-Port-Scan, wenn SSDP nichts fand
    if not found:
        prefixes = _local_prefixes()
        timeout = 2.5 if deep else 1.0
        rounds = 2 if deep else 1

        async def probe(ip: str) -> dict | None:
            t0 = loop.time()
            try:
                conn = _aio.open_connection(ip, 8883)
                _reader, writer = await _aio.wait_for(conn, timeout=timeout)
                writer.close()
                try:
                    await writer.wait_closed()
                except Exception:
                    pass
                return {"ip": ip, "ms": int((loop.time() - t0) * 1000), "via": "tcp"}
            except Exception:
                return None

        sem = _aio.Semaphore(128)

        async def guarded(ip: str) -> None:
            async with sem:
                r = await probe(ip)
                if r and r["ip"] not in found:
                    found[r["ip"]] = r

        for _round in range(rounds):
            targets = [f"{p}.{i}" for p in prefixes for i in range(1, 255)]
            await _aio.gather(*[guarded(ip) for ip in targets])
            if found:
                break

    results = sorted(found.values(), key=lambda r: r["ms"])
    return {"prefix": ", ".join(f"{p}.0/24" for p in _local_prefixes()), "candidates": results}