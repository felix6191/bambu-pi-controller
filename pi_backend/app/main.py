"""Main FastAPI application."""
import asyncio
from contextlib import asynccontextmanager
from typing import Any

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Depends, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from loguru import logger

from app.core.config import settings
from app.mqtt.client import BambuMQTTClient, bambu_client
from app.api import printer, camera, system


# Global printer client
printer_client: BambuMQTTClient | None = None
status_subscribers: set[WebSocket] = set()


async def broadcast_status(status_data: dict[str, Any]) -> None:
    """Broadcast status to all WebSocket subscribers."""
    disconnected = set()
    for ws in status_subscribers:
        try:
            await ws.send_json(status_data)
        except Exception:
            disconnected.add(ws)

    status_subscribers -= disconnected


async def on_printer_status_update(status) -> None:
    """Callback when printer status updates."""
    await broadcast_status({
        "type": "status",
        "data": status.model_dump(mode="json"),
    })


async def on_printer_push_event(push_msg) -> None:
    """Callback for push events."""
    await broadcast_status({
        "type": "event",
        "data": push_msg.model_dump(mode="json"),
    })


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Application lifespan manager."""
    global printer_client

    logger.info("Starting Bambu Pi Controller...")

    # Connect to printer
    printer_client = BambuMQTTClient(
        host=settings.printer_host,
        serial=settings.printer_serial,
        access_code=settings.printer_access_code,
        on_status_update=on_printer_status_update,
        on_push_event=on_printer_push_event,
    )

    try:
        await printer_client.connect()
        logger.info("Printer connected successfully")
    except Exception as e:
        logger.error(f"Failed to connect to printer: {e}")

    yield

    # Shutdown
    logger.info("Shutting down...")
    if printer_client:
        await printer_client.disconnect()


app = FastAPI(
    title="Bambu Pi Controller",
    description="Local API for controlling Bambu Lab A1 via Raspberry Pi",
    version="0.1.0",
    lifespan=lifespan,
)

# CORS for iOS app
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, restrict to Tailscale IPs
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Security
security = HTTPBearer(auto_error=False)


async def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    """Verify API token."""
    if not credentials or credentials.credentials != settings.api_token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return credentials.credentials


# Include routers
app.include_router(printer.router, prefix="/api/v1/printer", tags=["printer"], dependencies=[Depends(verify_token)])
app.include_router(camera.router, prefix="/api/v1/camera", tags=["camera"], dependencies=[Depends(verify_token)])
app.include_router(system.router, prefix="/api/v1/system", tags=["system"], dependencies=[Depends(verify_token)])


@app.get("/health")
async def health_check() -> dict[str, str]:
    """Health check endpoint."""
    return {
        "status": "ok",
        "printer_connected": "true" if printer_client and printer_client.connected else "false",
    }


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    """WebSocket for real-time printer updates."""
    await websocket.accept()

    # Verify token from query params
    token = websocket.query_params.get("token")
    if token != settings.api_token:
        await websocket.close(code=4001, reason="Invalid token")
        return

    status_subscribers.add(websocket)
    logger.info(f"WebSocket connected. Total: {len(status_subscribers)}")

    try:
        # Send initial status
        if printer_client:
            await websocket.send_json({
                "type": "status",
                "data": printer_client.status.model_dump(mode="json"),
            })

        # Keep connection alive
        while True:
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
    finally:
        status_subscribers.discard(websocket)
        logger.info(f"WebSocket disconnected. Total: {len(status_subscribers)}")


def get_printer_client() -> BambuMQTTClient:
    """Dependency to get printer client."""
    if not printer_client:
        raise HTTPException(status_code=503, detail="Printer not connected")
    return printer_client