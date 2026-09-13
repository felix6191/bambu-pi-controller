"""Bambu A1/P1 local camera client.

The A1 exposes NO http MJPEG endpoint (there is no ``:8080/stream``).
Instead it runs a proprietary TLS/TCP server on port 6000
(see OpenBambuAPI ``video.md`` + Bambu Wiki "printer network ports",
"LAN mode video 322/6000"):

1. TLS handshake (self-signed printer cert — verification off, LAN only).
2. Send one 80-byte auth packet: payload_size=0x40, type=0x3000,
   flags=0, pad=0, then username (``bblp``) and the 8-digit LAN access
   code, each NUL-padded to 32 bytes.
3. The printer streams frames forever. Each frame is a 16-byte header
   (payload_size u32 little-endian, then 3x u32) followed by
   ``payload_size`` bytes of baseline JPEG (FF D8 … FF D9).

This module speaks that protocol with stdlib only (asyncio + ssl) and
hands complete JPEG frames to the API layer, which re-serves them as
standard MJPEG (``multipart/x-mixed-replace``) and single snapshots —
exactly what the iOS app already expects.
"""
from __future__ import annotations

import asyncio
import ssl
import struct
from typing import AsyncIterator

CAMERA_PORT = 6000
CONNECT_TIMEOUT = 6.0
FRAME_TIMEOUT = 10.0

_AUTH_FMT = "<IIII32s32s"
_AUTH_SIZE = struct.calcsize(_AUTH_FMT)
_HEADER_FMT = "<IIII"
_HEADER_SIZE = struct.calcsize(_HEADER_FMT)


class CameraError(RuntimeError):
    """Raised when the printer camera cannot be reached or speaks garbage."""


def pack_auth(username: str = "bblp", password: str = "") -> bytes:
    """Build the 80-byte auth packet (pure, unit-testable)."""
    return struct.pack(
        _AUTH_FMT,
        0x40,
        0x3000,
        0,
        0,
        username.encode("ascii", "ignore")[:32],
        password.encode("ascii", "ignore")[:32],
    )


def parse_header(raw: bytes) -> int:
    """Return the JPEG payload size from a 16-byte frame header."""
    if len(raw) != _HEADER_SIZE:
        raise CameraError(f"Bad frame header ({len(raw)} bytes)")
    (size, _track, _flags, _pad) = struct.unpack(_HEADER_FMT, raw)
    if size <= 0 or size > 8_000_000:
        raise CameraError(f"Implausible frame size ({size})")
    return size


def _tls_context() -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


async def _read_exactly(reader: asyncio.StreamReader, n: int, timeout: float) -> bytes:
    try:
        return await asyncio.wait_for(reader.readexactly(n), timeout=timeout)
    except (asyncio.TimeoutError, asyncio.IncompleteReadError) as e:
        raise CameraError(f"Kamera antwortet nicht ({e.__class__.__name__})")


async def open_camera(host: str, access_code: str) -> tuple[asyncio.StreamReader, asyncio.StreamWriter]:
    """TLS-connect + authenticate. Caller must close the writer."""
    if not host or not access_code:
        raise CameraError("Drucker-IP oder Access Code fehlt (Drucker erst in der App einrichten)")
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(host, CAMERA_PORT, ssl=_tls_context()),
            timeout=CONNECT_TIMEOUT,
        )
    except (asyncio.TimeoutError, OSError) as e:
        raise CameraError(
            f"Druckerkamera {host}:{CAMERA_PORT} nicht erreichbar ({e}). "
            "LAN-/Entwicklermodus am Drucker an? Gleiches WLAN?"
        )
    writer.write(pack_auth("bblp", access_code))
    try:
        await writer.drain()
    except OSError as e:
        writer.close()
        raise CameraError(f"Kamera-Login fehlgeschlagen ({e})")
    return reader, writer


async def read_frame(reader: asyncio.StreamReader) -> bytes:
    """Read one complete JPEG frame."""
    header = await _read_exactly(reader, _HEADER_SIZE, FRAME_TIMEOUT)
    size = parse_header(header)
    frame = await _read_exactly(reader, size, FRAME_TIMEOUT)
    if len(frame) < 4 or frame[0] != 0xFF or frame[1] != 0xD8:
        raise CameraError("Kamera liefert kein JPEG (Access Code falsch?)")
    return frame


async def fetch_snapshot(host: str, access_code: str) -> bytes:
    """Connect, grab the first frame, disconnect."""
    reader, writer = await open_camera(host, access_code)
    try:
        return await read_frame(reader)
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass


async def stream_frames(host: str, access_code: str) -> AsyncIterator[bytes]:
    """Yield JPEG frames until cancelled or the printer drops the connection."""
    reader, writer = await open_camera(host, access_code)
    try:
        while True:
            yield await read_frame(reader)
    finally:
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
