"""Bambu Lab MQTT Protocol constants and message models."""
import json
from enum import Enum
from typing import Any
from pydantic import BaseModel, Field


class BambuTopic(str, Enum):
    REQUEST = "device/{serial}/request"
    REPORT = "device/{serial}/report"
    PUSH = "device/{serial}/push"


class PrintCommand(str, Enum):
    START_PRINT = "start_print"
    PAUSE_PRINT = "pause_print"
    RESUME_PRINT = "resume_print"
    STOP_PRINT = "stop_print"
    PRINT_PREPARE = "print_prepare"


class PrinterState(str, Enum):
    IDLE = "idle"
    PRINTING = "printing"
    PAUSED = "paused"
    BUSY = "busy"
    ERROR = "error"
    UNKNOWN = "unknown"


class PushMessage(BaseModel):
    sequence: str
    command: str
    data: dict[str, Any] = Field(default_factory=dict)


class ReportMessage(BaseModel):
    sequence: str
    command: str
    data: dict[str, Any] = Field(default_factory=dict)
    result: int = 0


class PrintJobInfo(BaseModel):
    name: str = ""
    progress: float = 0.0
    current_layer: int = 0
    total_layers: int = 0
    elapsed_time: int = 0
    remaining_time: int = 0
    filament_type: str = ""
    filament_color: str = ""


class PrinterStatus(BaseModel):
    state: PrinterState = PrinterState.UNKNOWN
    nozzle_temp: float = 0.0
    nozzle_target_temp: float = 0.0
    bed_temp: float = 0.0
    bed_target_temp: float = 0.0
    chamber_temp: float = 0.0
    print_job: PrintJobInfo = Field(default_factory=PrintJobInfo)
    wifi_signal: int = 0
    error_code: int = 0
    fan_speed: int = 0
    print_speed: int = 100
    flow_rate: int = 100


def build_request(sequence: str, command: str, data: dict[str, Any] | None = None) -> str:
    return json.dumps({"sequence": sequence, "command": command, "data": data or {}})


def parse_push_message(payload: str) -> PushMessage | None:
    try:
        return PushMessage(**json.loads(payload))
    except Exception:
        return None


def parse_report_message(payload: str) -> ReportMessage | None:
    try:
        return ReportMessage(**json.loads(payload))
    except Exception:
        return None