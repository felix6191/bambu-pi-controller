"""Bambu Lab local MQTT client.

Talks the real Bambu protocol (see app/mqtt/protocol.py + OpenBambuAPI):
publishes to ``device/{serial}/request``, subscribes to
``device/{serial}/report``. Temperatures/flow have no dedicated MQTT
command, so they go through ``print.gcode_line`` (M104/M140/M221).
"""
import asyncio
import ssl
import uuid
from contextlib import asynccontextmanager
from typing import Any, Callable, Awaitable

import paho.mqtt.client as mqtt
from loguru import logger

from app.mqtt.protocol import (
    BambuTopic,
    IncomingMessage,
    MessageType,
    PrintCommand,
    PrinterStatus,
    SpeedLevel,
    build_envelope,
    parse_incoming,
    status_from_print,
)


class BambuMQTTClient:
    def __init__(
        self,
        host: str,
        serial: str,
        access_code: str,
        port: int = 8883,
        use_tls: bool = True,
        on_status_update: Callable[[PrinterStatus], Awaitable[None]] | None = None,
        on_push_event: Callable[[IncomingMessage], Awaitable[None]] | None = None,
    ):
        self.host = host
        self.serial = serial
        self.access_code = access_code
        self.port = port
        self.use_tls = use_tls and port != 1883
        self._on_status_update = on_status_update
        self._on_push_event = on_push_event
        self._client: mqtt.Client | None = None
        self._status = PrinterStatus()
        self._pending: dict[str, asyncio.Future] = {}
        self._connected = False
        self._sequence = 0
        self._loop: asyncio.AbstractEventLoop | None = None

    @property
    def status(self) -> PrinterStatus:
        return self._status

    @property
    def connected(self) -> bool:
        return self._connected

    async def connect(self) -> None:
        if not self.host or not self.serial:
            raise RuntimeError("Printer host/serial not configured")
        loop = asyncio.get_running_loop()
        self._loop = loop
        self._client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"bambu-pi-{uuid.uuid4().hex[:8]}",
            protocol=mqtt.MQTTv5,
        )
        self._client.username_pw_set("bblp", self.access_code)
        if self.use_tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            self._client.tls_set_context(ctx)
            self._client.tls_insecure_set(True)
        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect
        self._client.on_message = self._on_message

        await loop.run_in_executor(None, self._client.connect, self.host, self.port, 60)
        self._client.loop_start()

        for _ in range(30):
            if self._connected:
                break
            await asyncio.sleep(0.5)
        else:
            raise TimeoutError(f"No MQTT connection to {self.host}:{self.port}")

        report = BambuTopic.REPORT.value.format(serial=self.serial)
        self._client.subscribe(report, qos=1)
        logger.info(f"Connected to Bambu printer {self.serial} at {self.host}:{self.port} (tls={self.use_tls})")
        # Ask for a full state dump (A1/P1 only send deltas otherwise)
        try:
            await self.push_all()
        except Exception as e:
            logger.warning(f"pushall failed (non-fatal): {e}")

    async def disconnect(self) -> None:
        if self._client:
            self._client.loop_stop()
            try:
                await asyncio.get_running_loop().run_in_executor(None, self._client.disconnect)
            except Exception:
                pass
            self._connected = False

    # -- paho callbacks (network thread) ------------------------------------

    def _on_connect(self, client: mqtt.Client, userdata: Any, flags: dict, reason_code: int, properties: Any) -> None:
        if reason_code == 0:
            self._connected = True
            logger.debug("MQTT connected")
        else:
            logger.error(f"MQTT connection failed: {reason_code}")

    def _on_disconnect(self, client: mqtt.Client, userdata: Any, reason_code: int, properties: Any) -> None:
        self._connected = False
        logger.warning(f"MQTT disconnected: {reason_code}")

    def _on_message(self, client: mqtt.Client, userdata: Any, msg: mqtt.MQTTMessage) -> None:
        try:
            payload = msg.payload.decode("utf-8")
        except Exception:
            return
        parsed = parse_incoming(payload)
        if parsed is None or self._loop is None:
            return
        self._loop.call_soon_threadsafe(self._loop.create_task, self._dispatch(parsed))

    async def _dispatch(self, msg: IncomingMessage) -> None:
        try:
            if msg.msg_type == MessageType.PRINT.value:
                if "sequence_id" in msg.payload or msg.sequence_id:
                    # Command acknowledgement?
                    fut = self._pending.pop(msg.sequence_id, None)
                    if fut and not fut.done():
                        fut.set_result(msg)
                        if msg.command not in ("push_status",):
                            return
                # Status push (full or delta)
                keys = set(msg.payload.keys()) | ({"print"} if msg.msg_type == "print" else set())
                _ = keys
                print_obj = msg.payload
                self._status = status_from_print(print_obj, self._status)
                if self._on_status_update:
                    await self._on_status_update(self._status)
                if self._on_push_event:
                    await self._on_push_event(msg)
            else:
                # pushing/info/system/mc_print responses or events
                fut = self._pending.pop(msg.sequence_id, None) if msg.sequence_id else None
                if fut and not fut.done():
                    fut.set_result(msg)
                if self._on_push_event:
                    await self._on_push_event(msg)
        except Exception as e:
            logger.error(f"Error dispatching MQTT message: {e}")

    # -- low level -----------------------------------------------------------

    def _next_sequence(self) -> str:
        self._sequence += 1
        return str(self._sequence)

    async def _request(
        self,
        msg_type: str,
        command: str,
        extra: dict[str, Any] | None = None,
        timeout: float = 10.0,
        qos: int = 1,
    ) -> IncomingMessage | None:
        if not self._connected or not self._client:
            raise RuntimeError("Not connected to printer")
        seq = self._next_sequence()
        payload = build_envelope(msg_type, seq, command, extra)
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self._pending[seq] = fut
        self._client.publish(BambuTopic.REQUEST.value.format(serial=self.serial), payload, qos=qos)
        try:
            msg = await asyncio.wait_for(fut, timeout=timeout)
            if not msg.ok:
                logger.warning(f"Printer NACK for {command}: {msg.payload}")
                return None
            return msg
        except asyncio.TimeoutError:
            self._pending.pop(seq, None)
            logger.error(f"Command {command} timed out")
            return None

    async def _print(self, command: str, extra: dict[str, Any] | None = None, timeout: float = 10.0) -> bool:
        msg = await self._request(MessageType.PRINT.value, command, extra, timeout=timeout, qos=1)
        return msg is not None

    async def wait_for_status(self, predicate, timeout: float = 8.0, interval: float = 0.4) -> bool:
        """Poll current status until predicate holds (i.e. the printer adopted the value).

        Bambu sends full/delta pushes continuously, so polling is robust without
        extra event plumbing. Returns False on timeout — the command itself may
        still have been accepted (ack), only the confirmation is missing.
        """
        import time as _time
        end = _time.monotonic() + timeout
        while True:
            try:
                if predicate(self._status):
                    return True
            except Exception:
                pass
            if _time.monotonic() >= end:
                return False
            await asyncio.sleep(interval)

    # -- public API ----------------------------------------------------------

    async def push_all(self) -> bool:
        msg = await self._request(
            MessageType.PUSHING.value, "pushall",
            {"version": 1, "push_target": 1}, timeout=15.0,
        )
        return msg is not None

    async def pause_print(self) -> bool:
        return await self._print(PrintCommand.PAUSE.value)

    async def resume_print(self) -> bool:
        return await self._print(PrintCommand.RESUME.value)

    async def stop_print(self) -> bool:
        return await self._print(PrintCommand.STOP.value)

    async def start_print(
        self,
        filename: str,
        bed_levelling: bool = True,
        flow_cali: bool = False,
        vibration_cali: bool = False,
        timelapse: bool = True,
    ) -> bool:
        """Start a file already on the printer SD card (FTP/SD browser upload is out of scope)."""
        name = filename.strip()
        if not name:
            return False
        return await self._print(
            PrintCommand.PROJECT_FILE.value,
            {
                "param": f"Metadata/{name}" if not name.startswith(("Metadata/", "/")) else name,
                "project_id": "0",
                "profile_id": "0",
                "task_id": "0",
                "subtask_id": "0",
                "subtask_name": name.rsplit("/", 1)[-1],
                "file": "",
                "url": "file:///mnt/sdcard",
                "timelapse": timelapse,
                "bed_type": "auto",
                "bed_levelling": bed_levelling,
                "flow_cali": flow_cali,
                "vibration_cali": vibration_cali,
                "layer_inspect": True,
                "use_ams": False,
            },
            timeout=15.0,
        )

    async def _gcode(self, line: str) -> bool:
        return await self._print(PrintCommand.GCODE_LINE.value, {"param": line})

    async def set_temperatures(self, nozzle: int | None = None, bed: int | None = None) -> dict[str, Any]:
        """Set targets via G-code, then verify against reported target temps.

        Returns dict(ok, verified, via, requested, actual) — the app shows
        whether the printer really adopted the value (callback semantics).
        """
        want_nozzle = max(0, min(300, nozzle)) if nozzle is not None else None
        want_bed = max(0, min(100, bed)) if bed is not None else None
        lines: list[str] = []
        if want_nozzle is not None:
            lines.append(f"M104 S{want_nozzle}")
        if want_bed is not None:
            lines.append(f"M140 S{want_bed}")
        if not lines:
            return {"ok": True, "verified": True, "via": "none", "requested": {}, "actual": {}}
        if not await self._gcode("\n".join(lines)):
            return {"ok": False, "verified": False, "via": "none",
                    "requested": {"nozzle": want_nozzle, "bed": want_bed}, "actual": {}}

        def adopted(s) -> bool:
            ok_n = want_nozzle is None or abs(s.nozzle_target_temp - want_nozzle) < 0.5
            ok_b = want_bed is None or abs(s.bed_target_temp - want_bed) < 0.5
            return ok_n and ok_b

        verified = await self.wait_for_status(adopted, timeout=8.0)
        return {"ok": True, "verified": verified, "via": "status" if verified else "ack",
                "requested": {"nozzle": want_nozzle, "bed": want_bed},
                "actual": {"nozzle": self._status.nozzle_target_temp, "bed": self._status.bed_target_temp}}

    async def set_speed_level(self, level: int) -> dict[str, Any]:
        if level not in (1, 2, 3, 4):
            return {"ok": False, "verified": False, "via": "none", "requested": level, "actual": None}
        if not await self._print(PrintCommand.PRINT_SPEED.value, {"param": str(level)}):
            return {"ok": False, "verified": False, "via": "none", "requested": level, "actual": None}
        # No optimistic assignment — verification must come from a real printer push
        verified = await self.wait_for_status(lambda s: s.speed_level == level, timeout=8.0)
        return {"ok": True, "verified": verified, "via": "status" if verified else "ack",
                "requested": level, "actual": self._status.speed_level}

    async def set_print_speed(self, speed: int) -> dict[str, Any]:
        """Percent-based convenience wrapper mapping onto official 1-4 presets."""
        return await self.set_speed_level(SpeedLevel.from_percent(max(50, min(200, speed))).value)

    async def set_flow_rate(self, flow: int) -> dict[str, Any]:
        want = max(50, min(150, flow))
        if not await self._gcode(f"M221 S{want}"):
            return {"ok": False, "verified": False, "via": "none", "requested": want, "actual": None}
        # Bambu reports no flow-ratio field, so an accepted command is the best
        # confirmation available.
        return {"ok": True, "verified": True, "via": "ack", "requested": want, "actual": None}

    async def set_chamber_light(self, on: bool) -> dict[str, Any]:
        msg = await self._request(
            MessageType.SYSTEM.value, "ledctrl",
            {
                "led_node": "chamber_light",
                "led_mode": "on" if on else "off",
                "led_on_time": 500,
                "led_off_time": 500,
                "loop_times": 1,
                "interval_time": 1000,
            },
        )
        if msg is None:
            return {"ok": False, "verified": False, "via": "none", "requested": on, "actual": None}
        want = "on" if on else "off"
        verified = await self.wait_for_status(lambda s: s.chamber_light == want, timeout=8.0)
        if verified:
            self._status.chamber_light = want
        return {"ok": True, "verified": verified, "via": "status" if verified else "ack",
                "requested": on, "actual": self._status.chamber_light}


@asynccontextmanager
async def bambu_client(
    host: str,
    serial: str,
    access_code: str,
    port: int = 8883,
    use_tls: bool = True,
    on_status_update=None,
    on_push_event=None,
):
    client = BambuMQTTClient(
        host=host, serial=serial, access_code=access_code, port=port, use_tls=use_tls,
        on_status_update=on_status_update, on_push_event=on_push_event,
    )
    try:
        await client.connect()
        yield client
    finally:
        await client.disconnect()
