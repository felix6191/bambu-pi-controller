"""Camera API routes.

Two sources, in order:

1. ``CAMERA_URL`` (optional override, e.g. USB camera) — proxied as before.
2. The Bambu A1/P1 itself: proprietary TLS/JPEG stream on port 6000
   (auth ``bblp`` + LAN access code). Served as standard MJPEG
   (``multipart/x-mixed-replace``) and single JPEG snapshots — exactly
   what the iOS app expects. No printer-side configuration needed
   beyond the normal app setup (IP + access code).
"""
import asyncio
from collections.abc import AsyncIterator

import httpx
from fastapi import APIRouter, HTTPException, Response
from fastapi.responses import StreamingResponse
from loguru import logger

from app.camera.printer_cam import CameraError, fetch_snapshot, stream_frames
from app.core.config import settings

router = APIRouter()

BOUNDARY = "frame"
NO_STORE_HEADERS = {
    "Cache-Control": "no-store, no-cache, must-revalidate",
    "Pragma": "no-cache",
    "X-Accel-Buffering": "no",
}
MAX_CONNECT_FAILURES = 3
RECONNECT_DELAY = 1.0


def _printer_cam() -> tuple[str, str]:
    host = (settings.printer_host or "").strip()
    code = (settings.printer_access_code or "").strip()
    if not host or not code:
        raise HTTPException(
            status_code=404,
            detail="Keine Kamera: Drucker erst in der App einrichten (IP + Access Code)",
        )
    return host, code


def mjpeg_part(jpeg: bytes) -> bytes:
    return (
        f"--{BOUNDARY}\r\n"
        "Content-Type: image/jpeg\r\n"
        f"Content-Length: {len(jpeg)}\r\n\r\n"
    ).encode() + jpeg + b"\r\n"


async def _proxy_mjpeg(url: str) -> AsyncIterator[bytes]:
    async with httpx.AsyncClient(timeout=30.0) as client:
        async with client.stream("GET", url) as response:
            async for chunk in response.aiter_bytes(8192):
                yield chunk


async def printer_mjpeg(host: str, code: str) -> AsyncIterator[bytes]:
    """Yield MJPEG parts and reconnect to the printer with backoff, so a
    dropped camera connection (A1 allows few clients; the app's snapshot
    may race the stream connect) does not kill the stream. Stops after
    repeated connect failures."""
    failures = 0
    while True:
        try:
            async for jpeg in stream_frames(host, code):
                failures = 0
                yield mjpeg_part(jpeg)
        except asyncio.CancelledError:
            raise
        except CameraError as e:
            logger.warning(f"Printer camera stream ended: {e}")
        failures += 1
        if failures >= MAX_CONNECT_FAILURES:
            logger.warning("Printer camera stream: giving up after repeated failures")
            return
        await asyncio.sleep(RECONNECT_DELAY)


@router.get("/stream")
async def camera_stream() -> StreamingResponse:
    # 1) Override (z. B. USB-Kamera am Pi)
    if settings.camera_url:
        return StreamingResponse(
            _proxy_mjpeg(settings.camera_url),
            media_type=f"multipart/x-mixed-replace; boundary={BOUNDARY}",
            headers=NO_STORE_HEADERS,
        )
    # 2) Druckerkamera (A1/P1, Port 6000)
    host, code = _printer_cam()
    return StreamingResponse(
        printer_mjpeg(host, code),
        media_type=f"multipart/x-mixed-replace; boundary={BOUNDARY}",
        headers=NO_STORE_HEADERS,
    )


@router.get("/snapshot")
async def camera_snapshot() -> Response:
    # 1) Override
    if settings.camera_url:
        snapshot_url = (
            settings.camera_url.replace("/stream", "/snapshot")
            if "/stream" in settings.camera_url
            else settings.camera_url
        )
        async with httpx.AsyncClient(timeout=10.0) as client:
            try:
                response = await client.get(snapshot_url)
                return Response(
                    content=response.content,
                    media_type="image/jpeg",
                    headers={"Cache-Control": "no-store"},
                )
            except Exception:
                raise HTTPException(status_code=500, detail="Snapshot fehlgeschlagen")
    # 2) Druckerkamera: erstes Frame nehmen
    host, code = _printer_cam()
    try:
        jpeg = await fetch_snapshot(host, code)
        return Response(
            content=jpeg,
            media_type="image/jpeg",
            headers={"Cache-Control": "no-store"},
        )
    except CameraError as e:
        raise HTTPException(status_code=503, detail=str(e))
