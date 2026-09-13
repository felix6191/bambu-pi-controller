"""Unit tests for the Bambu camera protocol helpers (no printer needed)."""
import struct

import pytest

from app.camera.printer_cam import pack_auth, parse_header


def test_auth_packet_layout():
    pkt = pack_auth("bblp", "12345678")
    assert len(pkt) == 80
    size, typ, flags, pad = struct.unpack("<IIII", pkt[:16])
    assert size == 0x40
    assert typ == 0x3000
    assert flags == 0 and pad == 0
    assert pkt[16:20] == b"bblp"
    assert pkt[16:48] == b"bblp" + b"\x00" * 28
    assert pkt[48:56] == b"12345678"
    assert pkt[48:80] == b"12345678" + b"\x00" * 24


def test_parse_header_ok():
    raw = struct.pack("<IIII", 12345, 0, 1, 0)
    assert parse_header(raw) == 12345


def test_parse_header_rejects_garbage():
    with pytest.raises(Exception):
        parse_header(b"short")
    with pytest.raises(Exception):
        parse_header(struct.pack("<IIII", 0, 0, 0, 0))
    with pytest.raises(Exception):
        parse_header(struct.pack("<IIII", 99_000_000, 0, 0, 0))


# ---------------------------------------------------------------------------
# MJPEG response framing + reconnect (printer simulated, no printer needed)
# ---------------------------------------------------------------------------
from app.api import camera as camera_api  # noqa: E402
from app.camera.printer_cam import CameraError  # noqa: E402
from app.core.config import settings  # noqa: E402

FRAME_1 = b"\xff\xd8AAA\xff\xd9"
FRAME_2 = b"\xff\xd8BBBB\xff\xd9"


def _setup_printer_settings(monkeypatch):
    monkeypatch.setattr(settings, "printer_host", "1.2.3.4")
    monkeypatch.setattr(settings, "printer_access_code", "12345678")
    monkeypatch.setattr(settings, "api_token", "testtoken")
    monkeypatch.setattr(settings, "camera_url", None)


def test_mjpeg_part_framing():
    part = camera_api.mjpeg_part(FRAME_1)
    expected = (
        b"--frame\r\n"
        b"Content-Type: image/jpeg\r\n"
        + f"Content-Length: {len(FRAME_1)}\r\n\r\n".encode()
        + FRAME_1 + b"\r\n"
    )
    assert part == expected


@pytest.mark.asyncio
async def test_printer_mjpeg_yields_framed_parts(monkeypatch):
    _setup_printer_settings(monkeypatch)

    async def fake_stream(host, code):
        assert host == "1.2.3.4" and code == "12345678"
        yield FRAME_1
        yield FRAME_2

    monkeypatch.setattr(camera_api, "stream_frames", fake_stream)
    monkeypatch.setattr(camera_api, "RECONNECT_DELAY", 0)

    parts = []
    async for part in camera_api.printer_mjpeg("1.2.3.4", "12345678"):
        parts.append(part)
        if len(parts) == 2:
            break
    assert len(parts) == 2
    assert parts[0].endswith(FRAME_1 + b"\r\n")
    assert parts[1].endswith(FRAME_2 + b"\r\n")
    for part in parts:
        head, _, rest = part.partition(b"\r\n\r\n")
        assert head.startswith(b"--frame\r\nContent-Type: image/jpeg\r\n")
        size = int(head.split(b"Content-Length: ")[1])
        assert rest[:size] == rest[:size]
        assert rest[size - 2:size] == b"\xff\xd9"
        assert len(rest) == size + 2


@pytest.mark.asyncio
async def test_printer_mjpeg_reconnects_after_failure(monkeypatch):
    _setup_printer_settings(monkeypatch)
    calls = {"n": 0}

    async def flaky_stream(host, code):
        calls["n"] += 1
        if calls["n"] == 1:
            raise CameraError("Kamera antwortet nicht (simuliert)")
        yield FRAME_1

    monkeypatch.setattr(camera_api, "stream_frames", flaky_stream)
    monkeypatch.setattr(camera_api, "RECONNECT_DELAY", 0)
    monkeypatch.setattr(camera_api, "MAX_CONNECT_FAILURES", 5)

    parts = []
    async for part in camera_api.printer_mjpeg("1.2.3.4", "12345678"):
        parts.append(part)
        break
    assert calls["n"] == 2
    assert len(parts) == 1 and parts[0].endswith(FRAME_1 + b"\r\n")


@pytest.mark.asyncio
async def test_printer_mjpeg_gives_up_after_repeated_failures(monkeypatch):
    _setup_printer_settings(monkeypatch)

    async def dead_stream(host, code):
        raise CameraError("Druckerkamera nicht erreichbar")
        yield  # pragma: no cover

    monkeypatch.setattr(camera_api, "stream_frames", dead_stream)
    monkeypatch.setattr(camera_api, "RECONNECT_DELAY", 0)
    monkeypatch.setattr(camera_api, "MAX_CONNECT_FAILURES", 2)

    parts = []
    async for part in camera_api.printer_mjpeg("1.2.3.4", "12345678"):
        parts.append(part)
    assert parts == []


@pytest.mark.asyncio
async def test_stream_endpoint_framing(monkeypatch):
    """Full HTTP path: multipart/x-mixed-replace with parseable frames."""
    import httpx

    from app.main import app

    _setup_printer_settings(monkeypatch)

    async def fake_stream(host, code):
        yield FRAME_1
        yield FRAME_2

    monkeypatch.setattr(camera_api, "stream_frames", fake_stream)
    monkeypatch.setattr(camera_api, "RECONNECT_DELAY", 0)
    monkeypatch.setattr(camera_api, "MAX_CONNECT_FAILURES", 1)

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        async with client.stream("GET", "/api/v1/camera/stream?token=testtoken") as resp:
            assert resp.status_code == 200
            ct = resp.headers["content-type"]
            assert ct.startswith("multipart/x-mixed-replace; boundary=frame")
            assert "no-store" in resp.headers.get("cache-control", "")
            body = b""
            async for chunk in resp.aiter_bytes():
                body += chunk
    assert body.endswith(FRAME_2 + b"\r\n")
    for frame in (FRAME_1, FRAME_2):
        part = (
            b"--frame\r\nContent-Type: image/jpeg\r\n"
            + f"Content-Length: {len(frame)}\r\n\r\n".encode()
            + frame + b"\r\n"
        )
        assert part in body


@pytest.mark.asyncio
async def test_stream_endpoint_404_when_not_configured(monkeypatch):
    import httpx

    from app.main import app

    monkeypatch.setattr(settings, "printer_host", "")
    monkeypatch.setattr(settings, "printer_access_code", "")
    monkeypatch.setattr(settings, "api_token", "testtoken")
    monkeypatch.setattr(settings, "camera_url", None)

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/api/v1/camera/stream?token=testtoken")
        assert resp.status_code == 404


@pytest.mark.asyncio
async def test_stream_endpoint_rejects_bad_token(monkeypatch):
    import httpx

    from app.main import app

    _setup_printer_settings(monkeypatch)

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/api/v1/camera/stream?token=wrong")
        assert resp.status_code == 401


@pytest.mark.asyncio
async def test_snapshot_endpoint(monkeypatch):
    import httpx

    from app.main import app

    _setup_printer_settings(monkeypatch)

    async def fake_snapshot(host, code):
        return FRAME_1

    monkeypatch.setattr(camera_api, "fetch_snapshot", fake_snapshot)

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/api/v1/camera/snapshot?token=testtoken")
        assert resp.status_code == 200
        assert resp.headers["content-type"] == "image/jpeg"
        assert resp.content == FRAME_1


@pytest.mark.asyncio
async def test_snapshot_endpoint_camera_down(monkeypatch):
    import httpx

    from app.main import app

    _setup_printer_settings(monkeypatch)

    async def dead_snapshot(host, code):
        raise CameraError("Druckerkamera nicht erreichbar")

    monkeypatch.setattr(camera_api, "fetch_snapshot", dead_snapshot)

    transport = httpx.ASGITransport(app=app)
    async with httpx.AsyncClient(transport=transport, base_url="http://test") as client:
        resp = await client.get("/api/v1/camera/snapshot?token=testtoken")
        assert resp.status_code == 503
