"""Unit tests for the Bambu camera protocol helpers (no printer needed)."""
import struct

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
    import pytest

    with pytest.raises(Exception):
        parse_header(b"short")
    with pytest.raises(Exception):
        parse_header(struct.pack("<IIII", 0, 0, 0, 0))
    with pytest.raises(Exception):
        parse_header(struct.pack("<IIII", 99_000_000, 0, 0, 0))
