"""Bambu Lab MQTT Client for local printer communication."""
import asyncio
import ssl
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
    def __init__(
        self,
        host: str,
        serial: str,
        access_code: str,
        port: int = 8883,
        use_tls: bool = True,
        on_status_update: Callable[[PrinterStatus], Awaitable[None]] | None = None,
        on_push_event: Callable[[PushMessage], Awaitable[None]] | None = None,
    ):
        self.host = host
        self.serial = serial
        self.access_code = access_code
        self.port = port
        # Bambu LAN uses TLS on 8883; plaintext 1883 only for local dev override
        self.use_tls = use_tls and port != 1883
        self._on_status_update = on_status_update
        self._on_push_event = on_push_event
        self._client: mqtt.Client | None = None
        self._status = PrinterStatus()
        self._pending_requests: dict[str, asyncio.Future] = {}
        self._connected = False
        self._sequence_counter = 0
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
            # Bambu printers use self-signed certs on LAN
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
            raise TimeoutError(f"Failed to connect to printer at {self.host}:{self.port}")

        push_topic = BambuTopic.PUSH.value.format(serial=self.serial)
        report_topic = BambuTopic.REPORT.value.format(serial=self.serial)
        self._client.subscribe(push_topic, qos=1)
        self._client.subscribe(report_topic, qos=1)
        logger.info(f"Connected to Bambu printer {self.serial} at {self.host}:{self.port} (tls={self.use_tls})")

    async def disconnect(self) -> None:
        if self._client:
            self._client.loop_stop()
            try:
                await asyncio.get_running_loop().run_in_executor(None, self._client.disconnect)
            except Exception:
                pass
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
        # Runs in paho network thread — never touch asyncio directly, hop to event loop
        try:
            payload = msg.payload.decode("utf-8")
        except Exception:
            return
        topic = msg.topic
        loop = self._loop
        if loop is None:
            return

        if topic.endswith("/push"):
            push_msg = parse_push_message(payload)
            if push_msg:
                loop.call_soon_threadsafe(loop.create_task, self._handle_push(push_msg))
        elif topic.endswith("/report"):
            report_msg = parse_report_message(payload)
            if report_msg:
                loop.call_soon_threadsafe(self._handle_report, report_msg)

    async def _handle_push(self, push_msg: PushMessage) -> None:
        try:
            self._update_status_from_push(push_msg)
            if self._on_status_update:
                await self._on_status_update(self._status)
            if self._on_push_event:
                await self._on_push_event(push_msg)
        except Exception as e:
            logger.error(f"Error handling push: {e}")

    def _handle_report(self, report_msg: ReportMessage) -> None:
        future = self._pending_requests.pop(report_msg.sequence, None)
        if future and not future.done():
            future.set_result(report_msg)

    def _update_status_from_push(self, push_msg: PushMessage) -> None:
        data = push_msg.data
        prev = self._status.print_job

        if "print" in data:
            print_data = data["print"]
            try:
                progress = float(print_data.get("mc_percent", prev.progress))
            except (TypeError, ValueError):
                progress = prev.progress
            self._status.print_job = PrintJobInfo(
                name=print_data.get("gcode_file", prev.name),
                progress=progress,
                current_layer=int(print_data.get("layer_num", prev.current_layer)),
                total_layers=int(print_data.get("total_layer_num", prev.total_layers)),
                # mc_remaining_time is remaining; keep previous elapsed unless printer sends explicit elapsed
                elapsed_time=int(print_data.get("mc_elapsed_time", print_data.get("elapsed_time", prev.elapsed_time))),
                remaining_time=int(print_data.get("mc_remaining_time", prev.remaining_time)),
                filament_type=print_data.get("filament_type", prev.filament_type),
                filament_color=print_data.get("filament_color", prev.filament_color),
            )

        if "temp" in data:
            temp = data["temp"]
            # Accept both Bambu naming variants
            nozzle = temp.get("nozzle_temp", temp.get("nozzle_temper", self._status.nozzle_temp))
            nozzle_t = temp.get("nozzle_target_temper", temp.get("nozzle_target_temper", self._status.nozzle_target_temp))
            bed = temp.get("bed_temp", temp.get("bed_temper", self._status.bed_temp))
            bed_t = temp.get("bed_target_temper", temp.get("bed_target_temper", self._status.bed_target_temp))
            try:
                self._status.nozzle_temp = float(nozzle)
                self._status.nozzle_target_temp = float(nozzle_t)
                self._status.bed_temp = float(bed)
                self._status.bed_target_temp = float(bed_t)
                self._status.chamber_temp = float(temp.get("chamber_temp", temp.get("chamber_temper", self._status.chamber_temp)))
            except (TypeError, ValueError):
                pass

        if "fan" in data:
            try:
                self._status.fan_speed = int(data["fan"].get("cooling_fan_speed", self._status.fan_speed))
            except (TypeError, ValueError):
                pass
        if "speed" in data:
            try:
                self._status.print_speed = int(data["speed"].get("spd_lvl", self._status.print_speed))
            except (TypeError, ValueError):
                pass
        if "flow" in data:
            try:
                self._status.flow_rate = int(data["flow"].get("flow_ratio", self._status.flow_rate))
            except (TypeError, ValueError):
                pass

        print_data = data.get("print", {})
        print_status = print_data.get("status", print_data.get("gcode_state", ""))
        state_map = {
            "printing": PrinterState.PRINTING,
            "running": PrinterState.PRINTING,
            "pause": PrinterState.PAUSED,
            "paused": PrinterState.PAUSED,
            "idle": PrinterState.IDLE,
            "finish": PrinterState.IDLE,
            "failed": PrinterState.ERROR,
            "fail": PrinterState.ERROR,
        }
        if print_status:
            self._status.state = state_map.get(str(print_status).lower(), PrinterState.UNKNOWN)

        if "wifi" in data:
            try:
                self._status.wifi_signal = int(data["wifi"].get("rssi", self._status.wifi_signal))
            except (TypeError, ValueError):
                pass

    def _next_sequence(self) -> str:
        self._sequence_counter += 1
        return f"{self._sequence_counter:04d}"

    async def send_command(
        self,
        command: PrintCommand,
        data: dict[str, Any] | None = None,
        timeout: float = 10.0,
    ) -> ReportMessage | None:
        if not self._connected or not self._client:
            raise RuntimeError("Not connected to printer")

        sequence = self._next_sequence()
        payload = build_request(sequence, command.value, data)
        future: asyncio.Future = asyncio.get_running_loop().create_future()
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
        data = {"print_file": filename, "bed_temp": bed_temp, "nozzle_temp": nozzle_temp}
        result = await self.send_command(PrintCommand.START_PRINT, data)
        return result is not None and result.result == 0

    async def pause_print(self) -> bool:
        result = await self.send_command(PrintCommand.PAUSE_PRINT)
        return result is not None and result.result == 0

    async def resume_print(self) -> bool:
        result = await self.send_command(PrintCommand.RESUME_PRINT)
        return result is not None and result.result == 0

    async def stop_print(self) -> bool:
        result = await self.send_command(PrintCommand.STOP_PRINT)
        return result is not None and result.result == 0

    async def set_temperatures(self, nozzle: int | None = None, bed: int | None = None) -> bool:
        data: dict[str, Any] = {}
        if nozzle is not None:
            data["nozzle_target_temper"] = nozzle
        if bed is not None:
            data["bed_target_temper"] = bed
        if not data:
            return True
        result = await self.send_command(PrintCommand.PRINT_PREPARE, data)
        return result is not None and result.result == 0

    async def set_print_speed(self, speed: int) -> bool:
        data = {"spd_lvl": max(50, min(200, speed))}
        result = await self.send_command(PrintCommand.PRINT_PREPARE, data)
        return result is not None and result.result == 0

    async def set_flow_rate(self, flow: int) -> bool:
        data = {"flow_ratio": max(50, min(150, flow))}
        result = await self.send_command(PrintCommand.PRINT_PREPARE, data)
        return result is not None and result.result == 0


@asynccontextmanager
async def bambu_client(
    host: str,
    serial: str,
    access_code: str,
    port: int = 8883,
    use_tls: bool = True,
    on_status_update: Callable[[PrinterStatus], Awaitable[None]] | None = None,
    on_push_event: Callable[[PushMessage], Awaitable[None]] | None = None,
):
    client = BambuMQTTClient(
        host=host, serial=serial, access_code=access_code, port=port, use_tls=use_tls,
        on_status_update=on_status_update, on_push_event=on_push_event
    )
    try:
        await client.connect()
        yield client
    finally:
        await client.disconnect()
