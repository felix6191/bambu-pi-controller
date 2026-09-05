"""Shared runtime state (avoids circular imports between main and api)."""
from __future__ import annotations
from typing import TYPE_CHECKING
from fastapi import HTTPException

if TYPE_CHECKING:
    from app.mqtt.client import BambuMQTTClient

printer_client: BambuMQTTClient | None = None


def get_printer_client() -> BambuMQTTClient:
    if printer_client is None:
        raise HTTPException(status_code=503, detail="Printer not connected (client not initialized)")
    if not printer_client.connected:
        raise HTTPException(status_code=503, detail="Printer MQTT disconnected")
    return printer_client
