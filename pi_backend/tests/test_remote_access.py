"""Tests für die Fernzugriff-Endpunkte (Tailscale) mit Fake-CLI.

Das Fake-CLI verhält sich wie das echte tailscale: `status --json` liest
einen Zustand aus einer Datei, `up` schaltet ihn um. So lassen sich der
Login-Flow (AuthURL) und der Running-Flow (Tailscale-IP) testen, ohne dass
tailscaled laufen muss.
"""
import asyncio
import json
import os

from app.api import system as system_mod


def _install_fake_cli(monkeypatch, tmp_path: "object", flip_on_up: bool = False) -> str:
    """Fake-tailscale auf PATH legen + Zustandsdatei anlegen. Gibt den Pfad zurück.

    flip_on_up=True simuliert einen bereits authentifizierten Knoten: `up`
    schaltet sofort auf Running um. False (Standard) simuliert eine offene
    Anmeldung: `up` wartet, der Status bleibt NeedsLogin mit AuthURL.
    """
    state_file = tmp_path / "ts_state.json"
    state_file.write_text(json.dumps({"BackendState": "NeedsLogin",
                                      "AuthURL": "https://login.tailscale.com/a/abc123"}))
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    fake = bin_dir / "tailscale"
    flip_line = ('/bin/echo \'{"BackendState": "Running", '
                 '"TailscaleIPs": ["100.64.0.2"]}\' > "$STATE"') if flip_on_up else ":"
    script = "\n".join([
        "#!/bin/bash",
        f'STATE="{state_file}"',
        'if [ "$1" = "status" ]; then',
        '  /bin/cat "$STATE"',
        "else",
        f"  {flip_line}",
        "fi",
        "",
    ])
    fake.write_text(script)
    fake.chmod(0o755)
    monkeypatch.setenv("PATH", str(bin_dir))
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    sock = tmp_path / "tailscaled.sock"
    sock.touch()
    monkeypatch.setattr(system_mod, "TS_SOCK", str(sock))
    return str(state_file)


def test_post_start_login_returns_auth_url(monkeypatch, tmp_path):
    _install_fake_cli(monkeypatch, tmp_path)
    result = asyncio.run(system_mod.remote_access_start())
    assert result.state == "NeedsLogin"
    assert result.auth_url == "https://login.tailscale.com/a/abc123"
    assert result.installed is True
    # JSON-Vertrag zur Swift-App (RemoteAccessStatus in Models.swift)
    data = json.loads(result.model_dump_json())
    assert set(data.keys()) == {"installed", "state", "auth_url", "tailscale_ip", "message"}
    assert data["auth_url"] == "https://login.tailscale.com/a/abc123"


def test_post_start_already_running_returns_ip(monkeypatch, tmp_path):
    state = _install_fake_cli(monkeypatch, tmp_path)
    # Zustand direkt auf „verbunden" setzen
    import pathlib
    pathlib.Path(state).write_text(json.dumps(
        {"BackendState": "Running", "TailscaleIPs": ["100.64.0.2", "fd7a::2"]}))
    result = asyncio.run(system_mod.remote_access_start())
    assert result.state == "Running"
    assert result.tailscale_ip == "100.64.0.2"      # nur IPv4, nicht fd7a::2
    assert result.auth_url == ""
    assert "aktiv" in result.message


def test_post_after_up_flip_reports_ip(monkeypatch, tmp_path):
    """POST mit NeedsLogin-Start: das Fake-CLI schaltet bei `up` auf Running um
    (bereits angemeldet) → POST liefert direkt die Tailscale-IP."""
    _install_fake_cli(monkeypatch, tmp_path, flip_on_up=True)
    result = asyncio.run(system_mod.remote_access_start())
    assert result.state == "Running"
    assert result.tailscale_ip == "100.64.0.2"


def test_get_status_missing_binary(monkeypatch, tmp_path):
    monkeypatch.setenv("PATH", str(tmp_path))       # kein tailscale dort
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    result = asyncio.run(system_mod.remote_access_status())
    assert result.installed is False
    assert "sudo bambu tailscale" in result.message


def test_get_status_daemon_down(monkeypatch, tmp_path):
    _install_fake_cli(monkeypatch, tmp_path)
    monkeypatch.setattr(system_mod, "TS_SOCK", str(tmp_path / "does-not-exist.sock"))
    result = asyncio.run(system_mod.remote_access_status())
    assert result.installed is True
    assert "läuft nicht" in result.message


def test_ts_bin_skips_docker_mount_dir(monkeypatch, tmp_path):
    """Docker legt für fehlende Host-Mounts ein VERZEICHNIS an — das darf
    nicht als CLI erkannt werden (sonst schlägt der Aufruf still fehl)."""
    bin_dir = tmp_path / "bin"
    (bin_dir / "tailscale").mkdir(parents=True)
    monkeypatch.setenv("PATH", str(bin_dir))
    assert system_mod._ts_bin() is None
