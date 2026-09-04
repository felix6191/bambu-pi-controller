"""Bambu Lab MQTT Protocol constants and message models."""
import json
from enum import Enum
from typing import Any
from pydantic import BaseModel, Field


class BambuTopic(str, Enum):
    """MQTT topics for Bambu Lab printers."""
    REQUEST = "device/{serial}/request"
    REPORT = "device/{serial}/report"
    PUSH = "device/{serial}/push"
    PUSH_ALL = "device/+/push"


class PrintCommand(str, Enum):
    """Printer control commands."""
    START_PRINT = "start_print"
    PAUSE_PRINT = "pause_print"
    RESUME_PRINT = "resume_print"
    STOP_PRINT = "stop_print"
    PRINT_PREPARE = "print_prepare"


class PushEvent(str, Enum):
    """Push notification events from printer."""
    PRINT_START = "print_start"
    PRINT_PAUSE = "print_pause"
    PRINT_RESUME = "print_resume"
    PRINT_FINISH = "print_finish"
    PRINT_FAIL = "print_fail"
    PRINT_LAYER_CHANGE = "print_layer_change"
    CAMERA_IMAGE = "camera_image"


class PrinterState(str, Enum):
    """Printer operational states."""
    IDLE = "idle"
    PRINTING = "printing"
    PAUSED = "paused"
    BUSY = "busy"
    ERROR = "error"
    UNKNOWN = "unknown"


class PushMessage(BaseModel):
    """Incoming push message from printer."""
    sequence: str
    command: str
    data: dict[str, Any] = Field(default_factory=dict)


class ReportMessage(BaseModel):
    """Report response from printer."""
    sequence: str
    command: str
    data: dict[str, Any] = Field(default_factory=dict)
    result: int = 0


class PrintJobInfo(BaseModel):
    """Current print job information."""
    name: str = ""
    progress: float = 0.0
    current_layer: int = 0
    total_layers: int = 0
    elapsed_time: int = 0
    remaining_time: int = 0
    filament_type: str = ""
    filament_color: str = ""


class PrinterStatus(BaseModel):
    """Complete printer status."""
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
    """Build a request payload for the printer."""
    return json.dumps({
        "sequence": sequence,
        "command": command,
        "data": data or {}
    })


def parse_push_message(payload: str) -> PushMessage | None:
    """Parse incoming push message."""
    try:
        data = json.loads(payload)
        return PushMessage(**data)
    except Exception:
        return None


def parse_report_message(payload: str) -> ReportMessage | None:
    """Parse incoming report message."""
    try:
        data = json.loads(payload)
        return ReportMessage(**data)
    except Exception:
        return None