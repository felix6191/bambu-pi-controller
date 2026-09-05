"""Shared runtime state (avoids circular imports between main and api).

Also owns the WebSocket fan-out and the live printer (re)connect used by
the phone-based setup flow (POST /system/printer-config).
"""
from __future__ import annotations
import asyncio
from typing import Any, Callable, Awaitable, TYPE_CHECKING
from fastapi import HTTPException, WebSocket
from loguru import logger

if TYPE_CHECKING:
    from app.mqtt.client import BambuMQTTClient
    from app.mqtt.protocol import PrinterStatus, IncomingMessage

printer_client: BambuMQTTClient | None = None
status_subscribers: set[WebSocket] = set()
_connect_lock = asyncio.Lock()


def get_printer_client() -> BambuMQTTClient:
    if printer_client is None:
        raise HTTPException(status_code=503, detail="Printer not connected (client not initialized)")
    if not printer_client.connected:
        raise HTTPException(status_code=503, detail="Printer MQTT disconnected")
    return printer_client


async def broadcast_status(status_data: dict[str, Any]) -> None:
    for ws in list(status_subscribers):
        try:
            await ws.send_json(status_data)
        except Exception:
            status_subscribers.discard(ws)


async def on_printer_status_update(printer_status: PrinterStatus) -> None:
    await broadcast_status({"type": "status", "data": printer_status.model_dump(mode="json")})


async def on_printer_push_event(push_msg: IncomingMessage) -> None:
    await broadcast_status({"type": "event", "data": push_msg.model_dump(mode="json")})


async def reconnect_printer() -> bool:
    """(Re)connect the MQTT client using the *current* settings values.

    Serialized with a lock so concurrent phone taps can't spawn two clients.
    Returns True when the printer is reachable afterwards.
    """
    from app.core.config import settings
    from app.mqtt.client import BambuMQTTClient

    global printer_client
    async with _connect_lock:
        if not settings.printer_host or not settings.printer_serial:
            logger.warning("reconnect_printer: host/serial missing, skipping")
            return False
        old = printer_client
        printer_client = BambuMQTTClient(
            host=settings.printer_host,
            serial=settings.printer_serial,
            access_code=settings.printer_access_code,
            port=settings.printer_port,
            use_tls=settings.printer_use_tls,
            on_status_update=on_printer_status_update,
            on_push_event=on_printer_push_event,
        )
        try:
            await printer_client.connect()
            logger.info("Printer reconnected via phone setup")
            if old is not None:
                try:
                    await old.disconnect()
                except Exception:
                    pass
            return True
        except Exception as e:
            logger.error(f"reconnect_printer failed: {e}")
            # Keep the new (disconnected) client so status endpoints report cleanly
            if old is not None and old.connected:
                printer_client = old
            return False
