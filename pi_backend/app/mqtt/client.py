"""Bambu Lab MQTT Client for local printer communication."""
import asyncio
import json
import uuid
from contextlib import asynccontextmanager
from typing import Any, Callable, Awaitable

import paho.mqtt.client as mqtt
from loguru import logger

from app.mqtt.protocol import (
    BambuTopic,
    PrintCommand,
    PrinterStatus,
    PrintJobInfo,
    PrinterState,
    PushMessage,
    ReportMessage,
    build_request,
    parse_push_message,
    parse_report_message,
)


class BambuMQTTClient:
    """Async MQTT client for Bambu Lab printers."""

    def __init__(
        self,
        host: str,
        serial: str,
        access_code: str,
        port: int = 1883,
        on_status_update: Callable[[PrinterStatus], Awaitable[None]] | None = None,
        on_push_event: Callable[[PushMessage], Awaitable[None]] | None = None,
    ):
        self.host = host
        self.serial = serial
        self.access_code = access_code
        self.port = port

        self._on_status_update = on_status_update
        self._on_push_event = on_push_event

        self._client: mqtt.Client | None = None
        self._status = PrinterStatus()
        self._pending_requests: dict[str, asyncio.Future] = {}
        self._connected = False
        self._sequence_counter = 0

    @property
    def status(self) -> PrinterStatus:
        return self._status

    @property
    def connected(self) -> bool:
        return self._connected

    async def connect(self) -> None:
        """Connect to the printer via MQTT."""
        loop = asyncio.get_event_loop()

        self._client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2,
            client_id=f"bambu-pi-{uuid.uuid4().hex[:8]}",
            protocol=mqtt.MQTTv5,
        )

        self._client.username_pw_set("bblp", self.access_code)
        self._client.on_connect = self._on_connect
        self._client.on_disconnect = self._on_disconnect
        self._client.on_message = self._on_message

        await loop.run_in_executor(None, self._client.connect, self.host, self.port, 60)
        self._client.loop_start()

        # Wait for connection
        for _ in range(30):
            if self._connected:
                break
            await asyncio.sleep(0.5)
        else:
            raise TimeoutError("Failed to connect to printer")

        # Subscribe to push and report topics
        push_topic = BambuTopic.PUSH.value.format(serial=self.serial)
        report_topic = BambuTopic.REPORT.value.format(serial=self.serial)
        self._client.subscribe(push_topic, qos=1)
        self._client.subscribe(report_topic, qos=1)

        logger.info(f"Connected to Bambu printer {self.serial} at {self.host}")

    async def disconnect(self) -> None:
        """Disconnect from printer."""
        if self._client:
            self._client.loop_stop()
            await asyncio.get_event_loop().run_in_executor(None, self._client.disconnect)
            self._connected = False
            logger.info("Disconnected from printer")

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
        payload = msg.payload.decode("utf-8")
        topic = msg.topic

        if topic.endswith("/push"):
            push_msg = parse_push_message(payload)
            if push_msg:
                asyncio.create_task(self._handle_push(push_msg))

        elif topic.endswith("/report"):
            report_msg = parse_report_message(payload)
            if report_msg:
                self._handle_report(report_msg)

    async def _handle_push(self, push_msg: PushMessage) -> None:
        """Handle push notification from printer."""
        try:
            self._update_status_from_push(push_msg)

            if self._on_status_update:
                await self._on_status_update(self._status)

            if self._on_push_event:
                await self._on_push_event(push_msg)

        except Exception as e:
            logger.error(f"Error handling push: {e}")

    def _handle_report(self, report_msg: ReportMessage) -> None:
        """Handle report response from printer."""
        future = self._pending_requests.pop(report_msg.sequence, None)
        if future and not future.done():
            future.set_result(report_msg)

    def _update_status_from_push(self, push_msg: PushMessage) -> None:
        """Update internal status from push message."""
        data = push_msg.data

        if "print" in data:
            print_data = data["print"]
            self._status.print_job = PrintJobInfo(
                name=print_data.get("gcode_file", ""),
                progress=float(print_data.get("mc_percent", 0)),
                current_layer=int(print_data.get("layer_num", 0)),
                total_layers=int(print_data.get("total_layer_num", 0)),
                elapsed_time=int(print_data.get("mc_remaining_time", 0)),
                remaining_time=int(print_data.get("mc_remaining_time", 0)),
            )

        if "temp" in data:
            temp = data["temp"]
            self._status.nozzle_temp = float(temp.get("nozzle_temp", 0))
            self._status.nozzle_target_temp = float(temp.get("nozzle_target_temper", 0))
            self._status.bed_temp = float(temp.get("bed_temp", 0))
            self._status.bed_target_temp = float(temp.get("bed_target_temper", 0))
            self._status.chamber_temp = float(temp.get("chamber_temp", 0))

        if "fan" in data:
            self._status.fan_speed = int(data["fan"].get("cooling_fan_speed", 0))

        if "speed" in data:
            self._status.print_speed = int(data["speed"].get("spd_lvl", 100))

        if "flow" in data:
            self._status.flow_rate = int(data["flow"].get("flow_ratio", 100))

        # Update state based on print status
        print_status = data.get("print", {}).get("status", "")
        state_map = {
            "printing": PrinterState.PRINTING,
            "paused": PrinterState.PAUSED,
            "idle": PrinterState.IDLE,
            "failed": PrinterState.ERROR,
            "finish": PrinterState.IDLE,
        }
        self._status.state = state_map.get(print_status, PrinterState.UNKNOWN)

        if "wifi" in data:
            self._status.wifi_signal = int(data["wifi"].get("rssi", 0))

    def _next_sequence(self) -> str:
        self._sequence_counter += 1
        return f"{self._sequence_counter:04d}"

    async def send_command(
        self,
        command: PrintCommand,
        data: dict[str, Any] | None = None,
        timeout: float = 10.0,
    ) -> ReportMessage | None:
        """Send command to printer and wait for response."""
        if not self._connected or not self._client:
            raise RuntimeError("Not connected to printer")

        sequence = self._next_sequence()
        payload = build_request(sequence, command.value, data)

        future: asyncio.Future = asyncio.get_event_loop().create_future()
        self._pending_requests[sequence] = future

        topic = BambuTopic.REQUEST.value.format(serial=self.serial)
        self._client.publish(topic, payload, qos=1)

        try:
            return await asyncio.wait_for(future, timeout=timeout)
        except asyncio.TimeoutError:
            self._pending_requests.pop(sequence, None)
            logger.error(f"Command {command} timed out")
            return None

    async def start_print(self, filename: str, bed_temp: int = 0, nozzle_temp: int = 0) -> bool:
        """Start a print job."""
        data = {
            "print_file": filename,
            "bed_temp": bed_temp,
            "nozzle_temp": nozzle_temp,
        }
        result = await self.send_command(PrintCommand.START_PRINT, data)
        return result is not None and result.result == 0

    async def pause_print(self) -> bool:
        """Pause current print."""
        result = await self.send_command(PrintCommand.PAUSE_PRINT)
        return result is not None and result.result == 0

    async def resume_print(self) -> bool:
        """Resume paused print."""
        result = await self.send_command(PrintCommand.RESUME_PRINT)
        return result is not None and result.result == 0

    async def stop_print(self) -> bool:
        """Stop current print."""
        result = await self.send_command(PrintCommand.STOP_PRINT)
        return result is not None and result.result == 0

    async def set_temperatures(self, nozzle: int | None = None, bed: int | None = None) -> bool:
        """Set target temperatures."""
        data = {}
        if nozzle is not None:
            data["nozzle_target_temper"] = nozzle
        if bed is not None:
            data["bed_target_temper"] = bed

        if not data:
            return True

        # Use print_prepare command for temperature changes
        result = await self.send_command(PrintCommand.PRINT_PREPARE, data)
        return result is not None and result.result == 0

    async def set_print_speed(self, speed: int) -> bool:
        """Set print speed percentage (50-200)."""
        data = {"spd_lvl": max(50, min(200, speed))}
        result = await self.send_command(PrintCommand.PRINT_PREPARE, data)
        return result is not None and result.result == 0

    async def set_flow_rate(self, flow: int) -> bool:
        """Set flow rate percentage (50-150)."""
        data = {"flow_ratio": max(50, min(150, flow))}
        result = await self.send_command(PrintCommand.PRINT_PREPARE, data)
        return result is not None and result.result == 0


@asynccontextmanager
async def bambu_client(
    host: str,
    serial: str,
    access_code: str,
    on_status_update: Callable[[PrinterStatus], Awaitable[None]] | None = None,
    on_push_event: Callable[[PushMessage], Awaitable[None]] | None = None,
) -> BambuMQTTClient:
    """Context manager for Bambu MQTT client."""
    client = BambuMQTTClient(
        host=host,
        serial=serial,
        access_code=access_code,
        on_status_update=on_status_update,
        on_push_event=on_push_event,
    )
    try:
        await client.connect()
        yield client
    finally:
        await client.disconnect()