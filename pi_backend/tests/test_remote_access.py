"""Tests für die Fernzugriff-Endpunkte (Cloudflare Quick Tunnel) mit Fake-CLI.

Das Fake-`cloudflared` gibt die „quick Tunnel"-URL auf stderr aus und bleibt
am Leben (`exec sleep`). So lässt sich der komplette Lebenszyklus
(Start → Status → Stop) ohne echtes cloudflared und ohne Netz testen.
"""
import json

import pytest

from app.api import system as system_mod


def _install_fake_cloudflared(monkeypatch, tmp_path, mode: str = "ok") -> str:
    """Fake-cloudflared auf PATH legen. Gibt die erwartete URL zurück.

    mode="ok"      -> URL plus registrierte Edge-Verbindung, bleibt am Leben.
    mode="no-edge" -> URL ohne Edge-Registrierung, bleibt am Leben.
    mode="fail"    -> sofortiger Abbruch ohne URL.
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    fake = bin_dir / "cloudflared"
    if mode in ("ok", "no-edge"):
        lines = [
            "#!/bin/bash",
            'echo "Your quick Tunnel has been created! '
            'Visit it at https://test-tunnel.trycloudflare.com" 1>&2',
        ]
        if mode == "ok":
            lines.append('echo "INF Registered tunnel connection connIndex=0" 1>&2')
        lines.extend(["exec /bin/sleep 300", ""])
        script = "\n".join(lines)
    else:
        script = "\n".join([
            "#!/bin/bash",
            'echo "failed to start tunnel" 1>&2',
            "exit 1",
            "",
        ])
    fake.write_text(script)
    fake.chmod(0o755)
    monkeypatch.setenv("PATH", str(bin_dir))
    return "https://test-tunnel.trycloudflare.com"


@pytest.fixture(autouse=True)
def _reset_state():
    system_mod._cf_proc = None
    system_mod._cf_url = ""
    system_mod._cf_connected = False
    system_mod._cf_task = None
    system_mod._cf_log.clear()
    yield
    system_mod._cf_proc = None
    system_mod._cf_url = ""
    system_mod._cf_connected = False
    system_mod._cf_task = None
    system_mod._cf_log.clear()


@pytest.mark.asyncio
async def test_start_status_stop_lifecycle(monkeypatch, tmp_path):
    url = _install_fake_cloudflared(monkeypatch, tmp_path)

    start = await system_mod.remote_access_start()
    assert start.installed is True
    assert start.state == "Running"
    assert start.provider == "cloudflare"
    assert start.remote_url == url
    assert start.target == system_mod.CF_TARGET
    assert start.binary
    assert system_mod._cf_connected is True
    proc = system_mod._cf_proc
    assert proc is not None

    # POST erneut: schon laufend -> gleiche URL, KEIN zweiter Prozess
    again = await system_mod.remote_access_start()
    assert again.state == "Running"
    assert again.remote_url == url
    assert system_mod._cf_proc is proc

    # GET ist reines Lesen und liefert dieselbe URL
    status = await system_mod.remote_access_status()
    assert status.state == "Running"
    assert status.remote_url == url
    assert status.installed is True

    stop = await system_mod.remote_access_stop()
    assert stop.state == "stopped"
    assert stop.remote_url == ""
    assert system_mod._cf_proc is None


@pytest.mark.asyncio
async def test_url_without_edge_registration_stays_starting(monkeypatch, tmp_path):
    url = _install_fake_cloudflared(monkeypatch, tmp_path, mode="no-edge")
    monkeypatch.setattr(system_mod, "CF_URL_TIMEOUT", 2.0)
    monkeypatch.setattr(system_mod, "CF_READY_TIMEOUT", 0.2)

    start = await system_mod.remote_access_start()
    try:
        assert start.state == "starting"
        assert start.remote_url == url
        assert system_mod._cf_connected is False
        assert system_mod._cf_proc is not None
    finally:
        await system_mod.remote_access_stop()
    assert system_mod._cf_proc is None


@pytest.mark.asyncio
async def test_missing_binary(monkeypatch, tmp_path):
    monkeypatch.setenv("PATH", str(tmp_path))
    monkeypatch.setattr(system_mod, "CF_CANDIDATES", ())
    result = await system_mod.remote_access_status()
    assert result.installed is False
    assert result.state == "unavailable"
    assert result.message


@pytest.mark.asyncio
async def test_failing_binary_returns_error(monkeypatch, tmp_path):
    _install_fake_cloudflared(monkeypatch, tmp_path, mode="fail")
    result = await system_mod.remote_access_start()
    assert result.installed is True
    assert result.state == "error"
    assert result.message
    assert result.detail
    assert system_mod._cf_proc is None


def test_extract_remote_url():
    line = ("INF Your quick Tunnel has been created! "
            "Visit it at https://foo-bar123.trycloudflare.com")
    assert system_mod._extract_remote_url(line) == "https://foo-bar123.trycloudflare.com"
    assert system_mod._extract_remote_url("no url here") == ""


def test_cf_bin_skips_docker_mount_dir(monkeypatch, tmp_path):
    """Docker legt für fehlende Host-Mounts ein VERZEICHNIS an — das darf
    nicht als CLI erkannt werden (sonst schlägt der Aufruf still fehl)."""
    bin_dir = tmp_path / "bin"
    (bin_dir / "cloudflared").mkdir(parents=True)
    monkeypatch.setenv("PATH", str(bin_dir))
    monkeypatch.setattr(system_mod, "CF_CANDIDATES", ())
    assert system_mod._cf_bin() is None


def test_response_json_keys():
    data = json.loads(system_mod.RemoteAccessResult(
        installed=True, state="Running").model_dump_json())
    assert set(data.keys()) == {
        "installed", "state", "provider", "remote_url", "auth_url",
        "tailscale_ip", "message", "target", "binary", "detail",
    }
    assert data["provider"] == "cloudflare"
    assert data["remote_url"] == ""
    assert data["auth_url"] == ""
    assert data["tailscale_ip"] is None
