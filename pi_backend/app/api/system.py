"""System API routes."""
import ipaddress
from pathlib import Path
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
import psutil
import platform
from loguru import logger

from app.core.config import settings
from app.core import state as app_state

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

    # Persist atomically so a restart keeps the phone-provided values
    env = _env_file()
    try:
        lines: dict[str, str] = {}
        order: list[str] = []
        if env.exists():
            for line in env.read_text(encoding="utf-8").splitlines():
                if "=" in line and not line.lstrip().startswith("#"):
                    k, v = line.split("=", 1)
                    lines[k.strip()] = v
                    order.append(k.strip())
        lines["PRINTER_HOST"] = host
        lines["PRINTER_SERIAL"] = settings.printer_serial
        lines["PRINTER_ACCESS_CODE"] = settings.printer_access_code
        for k in ("PRINTER_HOST", "PRINTER_SERIAL", "PRINTER_ACCESS_CODE"):
            if k not in order:
                order.append(k)
        env.write_text("".join(f"{k}={lines[k]}\n" for k in order), encoding="utf-8")
        try:
            import os
            os.chmod(env, 0o600)
        except Exception:
            pass
    except Exception as e:
        logger.error(f"Failed to persist printer config: {e}")
        raise HTTPException(status_code=500, detail="Konnte Konfiguration nicht speichern")

    connected = await app_state.reconnect_printer()
    if connected:
        return PrinterConfigResult(success=True, printer_connected=True,
                                   message="Drucker verbunden! 🎉")
    return PrinterConfigResult(success=True, printer_connected=False,
                               message="Gespeichert, aber Drucker antwortet nicht. Gleiches WLAN? Drucker an? LAN-Modus an?")


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