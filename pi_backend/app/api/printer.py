"""Printer API routes."""
from fastapi import APIRouter, Depends, HTTPException, status
from pydantic import BaseModel, Field

from app.mqtt.client import BambuMQTTClient
from app.main import get_printer_client

router = APIRouter()


class TemperatureRequest(BaseModel):
    nozzle: int | None = Field(None, ge=0, le=300)
    bed: int | None = Field(None, ge=0, le=120)


class SpeedRequest(BaseModel):
    speed: int = Field(..., ge=50, le=200)


class FlowRequest(BaseModel):
    flow: int = Field(..., ge=50, le=150)


class PrintStartRequest(BaseModel):
    filename: str = Field(..., min_length=1)
    bed_temp: int = Field(0, ge=0, le=120)
    nozzle_temp: int = Field(0, ge=0, le=300)

    class Config:
        populate_by_name = True


@router.get("/status")
async def get_status(client: BambuMQTTClient = Depends(get_printer_client)):
    return client.status.model_dump(mode="json")


@router.post("/print/start")
async def start_print(request: PrintStartRequest, client: BambuMQTTClient = Depends(get_printer_client)):
    success = await client.start_print(filename=request.filename, bed_temp=request.bed_temp, nozzle_temp=request.nozzle_temp)
    if not success:
        raise HTTPException(status_code=500, detail="Failed to start print")
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


@router.post("/temperature")
async def set_temperature(request: TemperatureRequest, client: BambuMQTTClient = Depends(get_printer_client)):
    success = await client.set_temperatures(nozzle=request.nozzle, bed=request.bed)
    if not success:
        raise HTTPException(status_code=500, detail="Failed to set temperature")
    return {"success": True}


@router.post("/speed")
async def set_speed(request: SpeedRequest, client: BambuMQTTClient = Depends(get_printer_client)):
    success = await client.set_print_speed(request.speed)
    if not success:
        raise HTTPException(status_code=500, detail="Failed to set speed")
    return {"success": True}


@router.post("/flow")
async def set_flow(request: FlowRequest, client: BambuMQTTClient = Depends(get_printer_client)):
    success = await client.set_flow_rate(request.flow)
    if not success:
        raise HTTPException(status_code=500, detail="Failed to set flow rate")
    return {"success": True}


@router.get("/files")
async def list_files(client: BambuMQTTClient = Depends(get_printer_client)):
    return {"files": []}