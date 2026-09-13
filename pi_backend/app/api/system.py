"""System API routes."""
import asyncio
import ipaddress
import json
import os
import platform
import re
import shutil
import socket
import time
from collections import deque
from pathlib import Path

import psutil
from fastapi import APIRouter, HTTPException
from loguru import logger
from pydantic import BaseModel, Field

from app.core import state as app_state
from app.core.config import persisted_printer_file, settings

router = APIRouter()


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
async def get_printer_config() -> dict:
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
async def set_printer_config(request: PrinterConfigRequest) -> PrinterConfigResult:
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

    # Erst prüfen, ob der Drucker überhaupt erreichbar ist (Port 8883).
    # Wenn der Port zu ist, KEINE MQTT-Versuche mehr: die würden nur je
    # ~14 s (6 s TCP/TLS + 8 s CONNACK-Wait) kosten und die App in ihren
    # 60-s-Timeout laufen lassen. Fail-fast mit klarer Meldung stattdessen.
    reachable = await _printer_port_open(host, settings.printer_port)
    if not reachable:
        detail = app_state.last_connect_error or (
            app_state.printer_client.last_error if app_state.printer_client else ""
        )
        detail_txt = f" Fehler: {detail}" if detail else ""
        return PrinterConfigResult(
            success=True, printer_connected=False,
            message=f"Drucker unter {host} nicht erreichbar (Port {settings.printer_port}). "
                    "Gleiches WLAN? Drucker an? LAN-Modus + Entwicklermodus "
                    "am Drucker an? IP prüfen." + detail_txt)
    # Port offen → MQTT verbinden, max. 2 Versuche (je ~14 s). WLAN braucht
    # manchmal einen Moment, mehr als 2 Versuche sprengen das App-Timeout.
    connected = False
    for attempt in range(2):
        connected = await app_state.reconnect_printer()
        if connected:
            break
        import asyncio as _aio
        await _aio.sleep(2.0)

    if connected:
        return PrinterConfigResult(success=True, printer_connected=True,
                                   message="Drucker verbunden! 🎉")
    detail = app_state.last_connect_error or (
        app_state.printer_client.last_error if app_state.printer_client else ""
    )
    detail_txt = f" Fehler: {detail}" if detail else ""
    return PrinterConfigResult(
        success=True, printer_connected=False,
        message="Drucker ist erreichbar, lehnt aber die Verbindung ab. "
                "Access Code (8 Zeichen) und Seriennummer prüfen — "
                "LAN-/Entwicklermodus am Drucker an?" + detail_txt)


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


# --------------------------------------------------- remote access (Cloudflare) ---

class RemoteAccessResult(BaseModel):
    installed: bool
    state: str
    provider: str = "cloudflare"
    remote_url: str = ""
    message: str = ""
    auth_url: str = ""
    tailscale_ip: str | None = None
    target: str = ""
    binary: str = ""
    detail: str = ""


CLOUDFLARED = "cloudflared"
# Deterministisch IPv4-Loopback: `localhost` kann zuerst ::1 auflösen, während
# Uvicorn nur auf IPv4 lauscht. Der Container läuft im Host-Netz, daher ist
# 127.0.0.1:8000 immer der eigene API-Server.
CF_TARGET = "http://127.0.0.1:8000"
CF_URL_TIMEOUT = 30.0
CF_READY_TIMEOUT = 15.0
CF_CANDIDATES: tuple[str, ...] = ("/usr/local/bin/cloudflared", "/usr/bin/cloudflared")
CF_URL_RE = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")
CF_CONNECTED_RE = re.compile(r"Registered tunnel connection", re.IGNORECASE)
CF_MISSING_MSG = ("cloudflared fehlt auf dem Pi. Bitte das Backend aktualisieren: "
                  "sudo bambu update")

_cf_proc: asyncio.subprocess.Process | None = None
_cf_url = ""
_cf_connected = False
_cf_task: asyncio.Task[None] | None = None
_cf_lock = asyncio.Lock()
_cf_log: deque[str] = deque(maxlen=50)


def _cf_bin() -> str | None:
    """Pfad zur cloudflared-CLI. Nur echte, ausführbare Dateien zählen —
    Docker legt für fehlende Host-Mounts sonst ein VERZEICHNIS am Mount-Point
    an, das `which` fälschlich findet."""
    candidates = [shutil.which(CLOUDFLARED) or "", *CF_CANDIDATES]
    for path in candidates:
        if path and os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def _extract_remote_url(text: str) -> str:
    """Öffentliche Quick-Tunnel-URL aus einer cloudflared-Logzeile ziehen."""
    match = CF_URL_RE.search(text)
    return match.group(0) if match else ""


def _cf_result(installed: bool, state: str, message: str = "",
               remote_url: str = "", detail: str = "",
               binary: str = "") -> RemoteAccessResult:
    return RemoteAccessResult(installed=installed, state=state,
                              remote_url=remote_url, message=message,
                              target=CF_TARGET if installed else "",
                              binary=binary, detail=detail)


def _cf_note(line: str) -> None:
    """Eine cloudflared-Logzeile merken und daraus URL/Edge-Status ableiten."""
    global _cf_url, _cf_connected
    _cf_log.append(line)
    url = _extract_remote_url(line)
    if url and not _cf_url:
        _cf_url = url
        logger.info(f"cloudflared tunnel URL: {url}")
    if not _cf_connected and CF_CONNECTED_RE.search(line):
        _cf_connected = True
        logger.info("cloudflared edge connection registered")


def _cf_log_tail(limit: int = 5, max_len: int = 800) -> str:
    return " | ".join(list(_cf_log)[-limit:])[:max_len]


def _cf_error_summary(limit: int = 3, max_len: int = 600) -> str:
    matches = [line for line in _cf_log
               if re.search(r"ERR|error|failed|failure|unable|cannot|refused|timeout",
                            line, re.IGNORECASE)]
    interesting = matches[-limit:] or list(_cf_log)[-limit:]
    return " | ".join(interesting)[:max_len]


async def _cf_pump_stderr(proc: asyncio.subprocess.Process) -> None:
    stream = proc.stderr
    if stream is None:
        return
    while True:
        raw = await stream.readline()
        if not raw:
            break
        line = raw.decode("utf-8", "replace").strip()
        if not line:
            continue
        logger.info(f"cloudflared: {line}")
        _cf_note(line)


async def _cf_drain(stream: asyncio.StreamReader | None) -> None:
    if stream is None:
        return
    try:
        while await stream.read(4096):
            pass
    except Exception as e:
        logger.debug(f"cloudflared stdout drain stopped: {e}")


async def _cf_supervise(proc: asyncio.subprocess.Process) -> None:
    global _cf_proc, _cf_url, _cf_connected
    try:
        await asyncio.gather(_cf_pump_stderr(proc), _cf_drain(proc.stdout))
        await proc.wait()
    except asyncio.CancelledError:
        raise
    except Exception as e:
        logger.warning(f"cloudflared supervisor error: {e}")
    finally:
        if _cf_proc is proc:
            _cf_proc = None
            _cf_url = ""
            _cf_connected = False
            _cf_log.append(f"cloudflared beendet (code={proc.returncode})")
            logger.info("cloudflared beendet")


async def _cf_stop() -> None:
    global _cf_proc, _cf_url, _cf_connected, _cf_task
    proc, task = _cf_proc, _cf_task
    _cf_proc = None
    _cf_url = ""
    _cf_connected = False
    _cf_task = None
    if proc is not None and proc.returncode is None:
        try:
            proc.terminate()
        except ProcessLookupError:
            pass
        try:
            await asyncio.wait_for(proc.wait(), timeout=5.0)
        except (TimeoutError, ProcessLookupError):
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            try:
                await proc.wait()
            except Exception:
                pass
    if task is not None and task is not asyncio.current_task():
        if not task.done():
            task.cancel()
        try:
            await task
        except BaseException:
            pass


@router.get("/remote-access", response_model=RemoteAccessResult)
async def remote_access_status() -> RemoteAccessResult:
    """Aktueller Fernzugriff-Status (reines Lesen, keine Nebenwirkungen)."""
    binary = _cf_bin()
    if binary is None:
        return _cf_result(False, "unavailable", CF_MISSING_MSG)
    if _cf_proc is not None and _cf_proc.returncode is None:
        if _cf_url and _cf_connected:
            return _cf_result(True, "Running", "Fernzugriff aktiv.", _cf_url,
                              binary=binary)
        if _cf_url:
            return _cf_result(
                True, "starting",
                "Tunnel-URL erzeugt, Edge-Verbindung wird aufgebaut …",
                _cf_url, _cf_log_tail(), binary)
        return _cf_result(True, "starting", "Tunnel startet …",
                          detail=_cf_log_tail(), binary=binary)
    return _cf_result(True, "stopped", "Fernzugriff gestoppt.",
                      detail=_cf_log_tail(), binary=binary)


@router.post("/remote-access", response_model=RemoteAccessResult)
async def remote_access_start() -> RemoteAccessResult:
    """Cloudflare Quick Tunnel starten (kein Login, kein Konto).

    Läuft der Tunnel bereits, wird seine URL zurückgegeben. Sonst wird
    cloudflared gestartet und zuerst auf die öffentliche URL, danach auf die
    tatsächlich registrierte Edge-Verbindung gewartet. Erst beides zusammen
    bedeutet „Running".
    """
    global _cf_proc, _cf_url, _cf_connected, _cf_task
    async with _cf_lock:
        binary = _cf_bin()
        if binary is None:
            return _cf_result(False, "unavailable", CF_MISSING_MSG)
        if (_cf_proc is not None and _cf_proc.returncode is None
                and _cf_url and _cf_connected):
            return _cf_result(True, "Running", "Fernzugriff aktiv.", _cf_url,
                              binary=binary)
        await _cf_stop()
        _cf_log.clear()
        try:
            proc = await asyncio.create_subprocess_exec(
                binary, "tunnel", "--url", CF_TARGET, "--no-autoupdate",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        except Exception as e:
            _cf_log.append(f"cloudflared start failed: {e}")
            return _cf_result(True, "error",
                              f"cloudflared konnte nicht starten: {e}",
                              detail=_cf_log_tail(), binary=binary)
        _cf_proc = proc
        _cf_url = ""
        _cf_connected = False
        _cf_task = asyncio.create_task(_cf_supervise(proc))
        loop = asyncio.get_running_loop()
        url_deadline = loop.time() + CF_URL_TIMEOUT
        while loop.time() < url_deadline:
            if _cf_url:
                break
            if proc.returncode is not None:
                break
            await asyncio.sleep(0.25)
        if not _cf_url:
            await _cf_stop()
            detail = _cf_error_summary() or "keine cloudflared-Ausgabe"
            return _cf_result(True, "error",
                              "cloudflared liefert keine öffentliche URL. "
                              "Bitte später erneut versuchen.",
                              detail=detail, binary=binary)
        ready_deadline = loop.time() + CF_READY_TIMEOUT
        while loop.time() < ready_deadline:
            if _cf_connected:
                return _cf_result(True, "Running", "Fernzugriff aktiv.",
                                  _cf_url, binary=binary)
            if proc.returncode is not None:
                break
            await asyncio.sleep(0.5)
        if proc.returncode is not None:
            await _cf_stop()
            return _cf_result(True, "error",
                              "cloudflared wurde unerwartet beendet.",
                              detail=_cf_error_summary(), binary=binary)
        return _cf_result(
            True, "starting",
            "Tunnel-URL erzeugt, Edge-Verbindung wird aufgebaut …",
            _cf_url, _cf_log_tail(), binary)


@router.delete("/remote-access", response_model=RemoteAccessResult)
async def remote_access_stop() -> RemoteAccessResult:
    """Cloudflare Quick Tunnel stoppen."""
    async with _cf_lock:
        binary = _cf_bin()
        await _cf_stop()
    return _cf_result(binary is not None, "stopped", "Fernzugriff gestoppt.",
                      detail=_cf_log_tail(), binary=binary or "")


@router.get("/info")
async def system_info() -> dict:
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
async def network_info() -> dict:
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
            except TimeoutError:
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
async def printer_scan(deep: bool = True) -> dict:
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
