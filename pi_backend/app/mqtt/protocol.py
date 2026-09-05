"""Bambu Lab local MQTT protocol.

Reference: OpenBambuAPI (community reverse-engineering of Bambu Studio / Handy).
Local broker: <printer-ip>:8883, MQTT over TLS, user ``bblp``,
password = LAN access code. All payloads are JSON.

Request envelope:  {"<type>": {"sequence_id": "<n>", "command": "<cmd>", ...}}
Report envelope:   {"<type>": {"sequence_id": "<n>", "command": "<cmd>",
                               "result": "success", ...}}
Unsolicited status pushes carry no matching sequence_id.
"""
import json
import time
from enum import Enum
from typing import Any
from pydantic import BaseModel, Field


class BambuTopic(str, Enum):
    REQUEST = "device/{serial}/request"
    REPORT = "device/{serial}/report"


class MessageType(str, Enum):
    PRINT = "print"
    PUSHING = "pushing"
    INFO = "info"
    SYSTEM = "system"
    MC_PRINT = "mc_print"
    CAMERA = "camera"


class PrintCommand(str, Enum):
    PAUSE = "pause"
    RESUME = "resume"
    STOP = "stop"
    PRINT_SPEED = "print_speed"
    GCODE_LINE = "gcode_line"
    PROJECT_FILE = "project_file"
    PUSH_STATUS = "push_status"


class SpeedLevel(int, Enum):
    """Official Bambu speed presets (print_speed param is the level as string)."""
    SILENT = 1
    STANDARD = 2
    SPORT = 3
    LUDICROUS = 4

    @property
    def display_name(self) -> str:
        return {1: "Silent", 2: "Standard", 3: "Sport", 4: "Ludicrous"}[self.value]

    @property
    def effective_percent(self) -> int:
        return {1: 50, 2: 100, 3: 124, 4: 166}[self.value]

    @classmethod
    def from_percent(cls, percent: int) -> SpeedLevel:
        if percent <= 62:
            return cls.SILENT
        if percent <= 112:
            return cls.STANDARD
        if percent <= 137:
            return cls.SPORT
        return cls.LUDICROUS


class PrinterState(str, Enum):
    IDLE = "idle"
    PRINTING = "printing"
    PAUSED = "paused"
    BUSY = "busy"
    ERROR = "error"
    UNKNOWN = "unknown"


class IncomingMessage(BaseModel):
    """Any decoded MQTT payload: envelope type + inner object."""
    msg_type: str
    command: str = ""
    sequence_id: str = ""
    result: str = ""
    payload: dict[str, Any] = Field(default_factory=dict)

    @property
    def ok(self) -> bool:
        return self.result.lower() == "success" if self.result else True


class PrintJobInfo(BaseModel):
    name: str = ""
    progress: float = 0.0
    current_layer: int = 0
    total_layers: int = 0
    elapsed_time: int = 0  # seconds
    remaining_time: int = 0  # seconds
    filament_type: str = ""
    filament_color: str = ""
    subtask_id: str = ""
    task_id: str = ""

    @staticmethod
    def _format(seconds: int) -> str:
        seconds = max(0, seconds)
        h, m = seconds // 3600, (seconds % 3600) // 60
        return f"{h}h {m}m" if h else f"{m}m"

    @property
    def formatted_elapsed(self) -> str:
        return self._format(self.elapsed_time)

    @property
    def formatted_remaining(self) -> str:
        return self._format(self.remaining_time)


class PrinterStatus(BaseModel):
    state: PrinterState = PrinterState.UNKNOWN
    nozzle_temp: float = 0.0
    nozzle_target_temp: float = 0.0
    bed_temp: float = 0.0
    bed_target_temp: float = 0.0
    chamber_temp: float = 0.0
    print_job: PrintJobInfo = Field(default_factory=PrintJobInfo)
    wifi_signal: int = 0  # dBm, e.g. -45
    error_code: int = 0
    fan_speed: int = 0  # part cooling fan %
    aux_fan_speed: int = 0
    chamber_fan_speed: int = 0
    speed_level: int = 2  # 1=silent 2=standard 3=sport 4=ludicrous
    print_speed: int = 100  # effective percent (spd_mag)
    flow_rate: int = 100
    nozzle_diameter: str = "0.4"
    sdcard: bool = True
    chamber_light: str = "unknown"  # on/off/unknown
    gcode_state_raw: str = ""


def build_envelope(msg_type: str, sequence_id: str, command: str, extra: dict[str, Any] | None = None) -> str:
    inner: dict[str, Any] = {"sequence_id": sequence_id, "command": command}
    if extra:
        inner.update(extra)
    return json.dumps({msg_type: inner})


def parse_incoming(payload: str) -> IncomingMessage | None:
    """Decode any Bambu envelope into a normalized message."""
    try:
        data = json.loads(payload)
    except Exception:
        return None
    if not isinstance(data, dict) or len(data) != 1:
        return None
    msg_type, inner = next(iter(data.items()))
    if not isinstance(inner, dict):
        return None
    return IncomingMessage(
        msg_type=str(msg_type),
        command=str(inner.get("command", "")),
        sequence_id=str(inner.get("sequence_id", "")),
        result=str(inner.get("result", "")),
        payload={k: v for k, v in inner.items() if k not in ("sequence_id", "command", "result")},
    )


def _fnum(value: Any, default: float = 0.0) -> float:
    try:
        return float(str(value).strip().rstrip("%"))
    except (TypeError, ValueError, AttributeError):
        return default


def _inum(value: Any, default: int = 0) -> int:
    try:
        return int(float(str(value).strip().rstrip("%")))
    except (TypeError, ValueError, AttributeError):
        return default


def _wifi_dbm(value: Any) -> int:
    try:
        return int(str(value).replace("dBm", "").strip())
    except (TypeError, ValueError):
        return 0


_STATE_MAP = {
    "idle": PrinterState.IDLE,
    "running": PrinterState.PRINTING,
    "pause": PrinterState.PAUSED,
    "paused": PrinterState.PAUSED,
    "finish": PrinterState.IDLE,
    "failed": PrinterState.ERROR,
    "fail": PrinterState.ERROR,
}


def status_from_print(print_data: dict[str, Any], prev: PrinterStatus) -> PrinterStatus:
    """Merge a `print` object (push_status or pushall) into previous status.

    A1/P1 deltas only contain changed keys, so every field falls back
    to the previous value when absent.
    """
    job = prev.print_job
    name = str(print_data.get("subtask_name", "") or print_data.get("gcode_file", "") or job.name)
    if "/" in name:
        name = name.rsplit("/", 1)[-1]

    remaining_min = print_data.get("mc_remaining_time", None)
    remaining = _inum(remaining_min, job.remaining_time // 60) * 60 if remaining_min is not None else job.remaining_time

    start = print_data.get("gcode_start_time", "0")
    try:
        start_ts = int(str(start))
    except (TypeError, ValueError):
        start_ts = 0
    elapsed = int(time.time()) - start_ts if start_ts > 0 else job.elapsed_time

    gcode_state = str(print_data.get("gcode_state", "") or "")
    new_state = _STATE_MAP.get(gcode_state.lower(), prev.state if not gcode_state else PrinterState.UNKNOWN)

    spd_lvl = _inum(print_data.get("spd_lvl", prev.speed_level), prev.speed_level)
    spd_mag = _inum(print_data.get("spd_mag", prev.print_speed), prev.print_speed)
    if spd_lvl in (1, 2, 3, 4) and "spd_mag" not in print_data:
        spd_mag = SpeedLevel(spd_lvl).effective_percent

    light = prev.chamber_light
    lights = print_data.get("lights_report", None)
    if isinstance(lights, list):
        for entry in lights:
            if isinstance(entry, dict) and entry.get("node") == "chamber_light":
                light = str(entry.get("mode", light))

    return PrinterStatus(
        state=new_state,
        nozzle_temp=_fnum(print_data.get("nozzle_temper", prev.nozzle_temp), prev.nozzle_temp),
        nozzle_target_temp=_fnum(print_data.get("nozzle_target_temper", prev.nozzle_target_temp), prev.nozzle_target_temp),
        bed_temp=_fnum(print_data.get("bed_temper", prev.bed_temp), prev.bed_temp),
        bed_target_temp=_fnum(print_data.get("bed_target_temper", prev.bed_target_temp), prev.bed_target_temp),
        chamber_temp=_fnum(print_data.get("chamber_temper", prev.chamber_temp), prev.chamber_temp),
        print_job=PrintJobInfo(
            name=name,
            progress=max(0.0, min(100.0, _fnum(print_data.get("mc_percent", job.progress), job.progress))),
            current_layer=_inum(print_data.get("layer_num", job.current_layer), job.current_layer),
            total_layers=_inum(print_data.get("total_layer_num", job.total_layers), job.total_layers),
            elapsed_time=max(0, elapsed),
            remaining_time=max(0, remaining),
            filament_type=job.filament_type,
            filament_color=job.filament_color,
            subtask_id=str(print_data.get("subtask_id", job.subtask_id)),
            task_id=str(print_data.get("task_id", job.task_id)),
        ),
        wifi_signal=_wifi_dbm(print_data.get("wifi_signal", prev.wifi_signal)) if "wifi_signal" in print_data else prev.wifi_signal,
        error_code=_inum(print_data.get("print_error", prev.error_code), prev.error_code),
        fan_speed=_inum(print_data.get("cooling_fan_speed", prev.fan_speed), prev.fan_speed),
        aux_fan_speed=_inum(print_data.get("big_fan1_speed", prev.aux_fan_speed), prev.aux_fan_speed),
        chamber_fan_speed=_inum(print_data.get("big_fan2_speed", prev.chamber_fan_speed), prev.chamber_fan_speed),
        speed_level=spd_lvl if spd_lvl in (1, 2, 3, 4) else prev.speed_level,
        print_speed=max(0, spd_mag),
        flow_rate=prev.flow_rate,
        nozzle_diameter=str(print_data.get("nozzle_diameter", prev.nozzle_diameter)),
        sdcard=bool(print_data.get("sdcard", prev.sdcard)),
        chamber_light=light,
        gcode_state_raw=gcode_state,
    )


# Backwards-compatible aliases used by older code/tests
def build_request(sequence: str, command: str, data: dict[str, Any] | None = None) -> str:
    inner = {"sequence_id": sequence, "command": command}
    if data:
        inner.update(data)
    return json.dumps({"print": inner})


class PushMessage(BaseModel):
    sequence: str = ""
    command: str = ""
    data: dict[str, Any] = Field(default_factory=dict)


class ReportMessage(BaseModel):
    sequence: str = ""
    command: str = ""
    data: dict[str, Any] = Field(default_factory=dict)
    result: int = 0


def parse_push_message(payload: str) -> PushMessage | None:
    msg = parse_incoming(payload)
    if msg is None or msg.msg_type != MessageType.PRINT.value:
        return None
    return PushMessage(sequence=msg.sequence_id, command=msg.command, data=msg.payload)


def parse_report_message(payload: str) -> ReportMessage | None:
    msg = parse_incoming(payload)
    if msg is None:
        return None
    return ReportMessage(sequence=msg.sequence_id, command=msg.command, data=msg.payload, result=1 if msg.ok else 0)
