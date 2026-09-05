"""Pairing ohne Zahlentippen.

Der Pi sendet per mDNS `_bambu-pi._tcp` (siehe pi_image/). Die App findet ihn
darüber, ein Tap auf „Verbinden" ruft claim auf — Token wird automatisch
übergeben und in der App gespeichert. Keine IP-, keine Token-Eingabe.

Sicherheit: claim geht nur, solange ungepaired. Danach 403 (Repair nur
authentifiziert oder per `sudo bambu repair`). Simples Rates-Limit pro IP.
"""
from __future__ import annotations
import json
import os
import re
import secrets
import time
from datetime import datetime, timezone
from pathlib import Path

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field
from loguru import logger

from app.core.config import settings

router = APIRouter()
auth_router = APIRouter()

PAIRING_VERSION = 1
_CLAIM_WINDOW: dict[str, list[float]] = {}


def _storage() -> Path:
    root = Path(os.environ.get("STORAGE_DIR", Path(__file__).resolve().parents[2] / "storage"))
    root.mkdir(parents=True, exist_ok=True)
    return root


def _pairing_file() -> Path:
    return _storage() / "pairing.json"


def _read_pairing() -> dict:
    try:
        return json.loads(_pairing_file().read_text(encoding="utf-8"))
    except Exception:
        return {}


def _write_pairing(data: dict) -> None:
    _pairing_file().write_text(json.dumps(data), encoding="utf-8")


def _env_file() -> Path:
    return Path(__file__).resolve().parents[2] / ".env"


def pi_id() -> str:
    """Stabile, kurze Pi-Kennung (z. B. Bambu-Pi-AB12) für die Trefferliste."""
    data = _read_pairing()
    if data.get("pi_id"):
        return str(data["pi_id"])
    suffix = secrets.token_hex(2).upper()
    pid = f"Bambu-Pi-{suffix}"
    data["pi_id"] = pid
    _write_pairing(data)
    return pid


def is_paired() -> bool:
    return bool(_read_pairing().get("paired"))


def _ensure_token() -> str:
    """Token erzeugen+persistieren, falls das Image keins hinterlegt hat."""
    if settings.api_token:
        return settings.api_token
    env = _env_file()
    try:
        if env.exists():
            for line in env.read_text(encoding="utf-8").splitlines():
                if line.startswith("API_TOKEN="):
                    tok = line.split("=", 1)[1].strip()
                    if tok and tok != "your-secure-api-token-here":
                        settings.api_token = tok
                        return tok
    except Exception:
        pass
    tok = secrets.token_hex(32)
    settings.api_token = tok
    try:
        lines: list[str] = []
        seen = False
        if env.exists():
            for line in env.read_text(encoding="utf-8").splitlines():
                if line.startswith("API_TOKEN="):
                    lines.append(f"API_TOKEN={tok}")
                    seen = True
                else:
                    lines.append(line)
        if not seen:
            lines.append(f"API_TOKEN={tok}")
        env.write_text("\n".join(lines) + "\n", encoding="utf-8")
        os.chmod(env, 0o600)
    except Exception as e:
        logger.error(f"token persist failed: {e}")
    return tok


def _rate_ok(ip: str) -> bool:
    now = time.monotonic()
    hits = [t for t in _CLAIM_WINDOW.get(ip, []) if now - t < 60]
    if len(hits) >= 5:
        return False
    hits.append(now)
    _CLAIM_WINDOW[ip] = hits
    return True


class ClaimRequest(BaseModel):
    device_name: str = Field(default="iPhone", max_length=64)


class ClaimResult(BaseModel):
    api_token: str
    pi_id: str


@router.get("/status")
async def pairing_status() -> dict:
    """Offen (ohne Auth): lässt die App prüfen, ob dieser Pi noch frei ist."""
    return {"paired": is_paired(), "pi_id": pi_id(), "version": PAIRING_VERSION}


@router.post("/claim", response_model=ClaimResult)
async def claim(request: ClaimRequest, http: Request) -> ClaimResult:
    """Ein Tap in der App verbindet: Token-Austausch, nichts abtippen."""
    if is_paired():
        raise HTTPException(status_code=403, detail="Pi ist schon verbunden (Repair in der App oder 'sudo bambu repair')")
    ip = http.client.host if http.client else "?"
    if not _rate_ok(ip):
        raise HTTPException(status_code=429, detail="Zu viele Versuche — kurz warten")
    name = re.sub(r"[^A-Za-z0-9 _.-]+", "", request.device_name).strip()[:64] or "iPhone"
    token = _ensure_token()
    _write_pairing({
        **_read_pairing(),
        "paired": True,
        "device_name": name,
        "paired_at": datetime.now(timezone.utc).isoformat(),
    })
    logger.info(f"Paired with {name} from {ip}")
    return ClaimResult(api_token=token, pi_id=pi_id())


@auth_router.post("/reset")
async def reset_pairing_authed() -> dict:
    """Repair (nur mit gültigem Token aufrufbar): gibt den Pi für ein neues
    Handy frei, ohne Druckerconfig zu löschen."""
    data = _read_pairing()
    data["paired"] = False
    data.pop("device_name", None)
    _write_pairing(data)
    _CLAIM_WINDOW.clear()
    return {"success": True, "message": "Bereit für neues Handy — in der App erneut verbinden"}
