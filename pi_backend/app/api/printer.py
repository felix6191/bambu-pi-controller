"""Printer API routes (real Bambu local protocol)."""
from typing import Any
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from app.mqtt.client import BambuMQTTClient
from app.core.state import get_printer_client

router = APIRouter()


class CommandResult(BaseModel):
    """Every mutating endpoint reports whether the printer adopted the value.

    verified=true  → a later printer status push confirmed the value (via=status)
    verified=false → command was accepted but no confirmation push arrived yet (via=ack)
    """

    success: bool
    verified: bool = False
    via: str = "none"
    requested: Any | None = None
    actual: Any | None = None


class TemperatureRequest(BaseModel):
    nozzle: int | None = Field(default=None, ge=0, le=300)
    bed: int | None = Field(default=None, ge=0, le=100)


class SpeedRequest(BaseModel):
    speed: int = Field(..., ge=50, le=200)


class SpeedLevelRequest(BaseModel):
    level: int = Field(..., ge=1, le=4)


class FlowRequest(BaseModel):
    flow: int = Field(..., ge=50, le=150)


class LightRequest(BaseModel):
    on: bool


class PrintStartRequest(BaseModel):
    filename: str = Field(..., min_length=1)
    bed_temp: int = Field(default=0, ge=0, le=100)
    nozzle_temp: int = Field(default=0, ge=0, le=300)
    bed_levelling: bool = True
    timelapse: bool = True

    class Config:
        populate_by_name = True


@router.get("/capabilities")
async def get_capabilities():
    """Official Bambu Lab A1 limits — the app clamps every value to these."""
    return {
        "model": "Bambu Lab A1",
        "nozzle_max_temp": 300,
        "bed_max_temp": 100,
        "chamber_heated": False,
        "build_volume_mm": [256, 256, 256],
        "nozzle_diameter_mm": 0.4,
        "filament_diameter_mm": 1.75,
        "speed_levels": [
            {"level": 1, "name": "Silent", "percent": 50},
            {"level": 2, "name": "Standard", "percent": 100},
            {"level": 3, "name": "Sport", "percent": 124},
            {"level": 4, "name": "Ludicrous", "percent": 166},
        ],
        "flow_range": [50, 150],
        "fan_range": [0, 100],
    }


@router.get("/status")
async def get_status(client: BambuMQTTClient = Depends(get_printer_client)):
    return client.status.model_dump(mode="json")


@router.post("/print/start")
async def start_print(request: PrintStartRequest, client: BambuMQTTClient = Depends(get_printer_client)):
    # project_file takes no temps — preheat first via G-code if requested
    if request.nozzle_temp or request.bed_temp:
        await client.set_temperatures(
            nozzle=request.nozzle_temp or None,
            bed=request.bed_temp or None,
        )
    success = await client.start_print(
        filename=request.filename,
        bed_levelling=request.bed_levelling,
        timelapse=request.timelapse,
    )
    if not success:
        raise HTTPException(status_code=500, detail="Failed to start print (file must exist on printer SD card)")
    return {"success": True}


@router.post("/print/pause")
async def pause_print(client: BambuMQTTClient = Depends(get_printer_client)):
    success = await client.pause_print()
    if not success:
        raise HTTPException(status_code=500, detail="Failed to pause print")
    return {"success": True}


@router.post("/print/resume")
async def resume_print(client: BambuMQTTClient = Depends(get_printer_client)):
    success = await client.resume_print()
    if not success:
        raise HTTPException(status_code=500, detail="Failed to resume print")
    return {"success": True}


@router.post("/print/stop")
async def stop_print(client: BambuMQTTClient = Depends(get_printer_client)):
    success = await client.stop_print()
    if not success:
        raise HTTPException(status_code=500, detail="Failed to stop print")
    return {"success": True}


@router.post("/temperature", response_model=CommandResult)
async def set_temperature(request: TemperatureRequest, client: BambuMQTTClient = Depends(get_printer_client)):
    if request.nozzle is None and request.bed is None:
        raise HTTPException(status_code=400, detail="Provide at least nozzle or bed temperature")
    res = await client.set_temperatures(nozzle=request.nozzle, bed=request.bed)
    if not res["ok"]:
        raise HTTPException(status_code=500, detail="Failed to set temperature")
    return CommandResult(success=True, verified=res["verified"], via=res["via"],
                         requested=res["requested"], actual=res["actual"])


@router.post("/speed", response_model=CommandResult)
async def set_speed(request: SpeedRequest, client: BambuMQTTClient = Depends(get_printer_client)):
    """Percent-based speed; mapped onto official 1-4 presets on the printer."""
    res = await client.set_print_speed(request.speed)
    if not res["ok"]:
        raise HTTPException(status_code=500, detail="Failed to set speed")
    return CommandResult(success=True, verified=res["verified"], via=res["via"],
                         requested=res["requested"], actual=res["actual"])


@router.post("/speed-level", response_model=CommandResult)
async def set_speed_level(request: SpeedLevelRequest, client: BambuMQTTClient = Depends(get_printer_client)):
    """Official speed preset: 1=Silent, 2=Standard, 3=Sport, 4=Ludicrous."""
    res = await client.set_speed_level(request.level)
    if not res["ok"]:
        raise HTTPException(status_code=500, detail="Failed to set speed level")
    return CommandResult(success=True, verified=res["verified"], via=res["via"],
                         requested=res["requested"], actual=res["actual"])


@router.post("/flow", response_model=CommandResult)
async def set_flow(request: FlowRequest, client: BambuMQTTClient = Depends(get_printer_client)):
    res = await client.set_flow_rate(request.flow)
    if not res["ok"]:
        raise HTTPException(status_code=500, detail="Failed to set flow rate")
    return CommandResult(success=True, verified=res["verified"], via=res["via"],
                         requested=res["requested"], actual=res["actual"])


@router.post("/light", response_model=CommandResult)
async def set_light(request: LightRequest, client: BambuMQTTClient = Depends(get_printer_client)):
    res = await client.set_chamber_light(request.on)
    if not res["ok"]:
        raise HTTPException(status_code=500, detail="Failed to switch chamber light")
    return CommandResult(success=True, verified=res["verified"], via=res["via"],
                         requested=res["requested"], actual=res["actual"])


@router.get("/files")
async def list_files(client: BambuMQTTClient = Depends(get_printer_client)):
    return {"files": []}
