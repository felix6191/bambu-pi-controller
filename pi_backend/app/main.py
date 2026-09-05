"""Main FastAPI application."""
import sys
from contextlib import asynccontextmanager

from fastapi import FastAPI, WebSocket, WebSocketDisconnect, Depends, HTTPException, Query, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from loguru import logger

from app.core.config import settings
from app.core import state as app_state
from app.api import printer, camera, system

logger.remove()
logger.add(sys.stderr, level=settings.log_level.upper())


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("Starting Bambu Pi Controller...")

    if not settings.printer_host or not settings.printer_serial or not settings.api_token:
        logger.warning("PRINTER_HOST/SERIAL/API_TOKEN missing — API boots, printer calls return 503 until configured (use the iPhone setup or POST /system/printer-config)")

    if settings.printer_host:
        for attempt in range(1, 4):
            if await app_state.reconnect_printer():
                logger.info("Printer connected successfully")
                break
            logger.error(f"Printer connect attempt {attempt}/3 failed")
            if attempt == 3:
                logger.warning("Continuing without printer connection; will retry on demand")
    else:
        logger.warning("No PRINTER_HOST configured, skipping MQTT connect")

    yield

    logger.info("Shutting down...")
    if app_state.printer_client:
        await app_state.printer_client.disconnect()


app = FastAPI(
    title="Bambu Pi Controller",
    description="Local API for controlling Bambu Lab A1 via Raspberry Pi",
    version="0.1.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

security = HTTPBearer(auto_error=False)


async def verify_token(credentials: HTTPAuthorizationCredentials = Depends(security)) -> str:
    if not settings.api_token:
        raise HTTPException(status_code=500, detail="API token not configured on server")
    if not credentials or credentials.credentials != settings.api_token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return credentials.credentials


async def verify_token_or_query(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    token: str | None = Query(default=None),
) -> str:
    """Accept Bearer header (preferred) or ?token= query (for <img>/MJPEG where headers can't be set)."""
    if not settings.api_token:
        raise HTTPException(status_code=500, detail="API token not configured on server")
    candidate = credentials.credentials if credentials else token
    if candidate != settings.api_token:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API token",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return settings.api_token


app.include_router(printer.router, prefix="/api/v1/printer", tags=["printer"], dependencies=[Depends(verify_token)])
app.include_router(camera.router, prefix="/api/v1/camera", tags=["camera"], dependencies=[Depends(verify_token_or_query)])
app.include_router(system.router, prefix="/api/v1/system", tags=["system"], dependencies=[Depends(verify_token)])


@app.get("/health")
async def health_check() -> dict[str, bool | str]:
    connected = app_state.printer_client is not None and app_state.printer_client.connected
    return {"status": "ok", "printer_connected": connected}


@app.websocket("/ws")
async def websocket_endpoint(websocket: WebSocket) -> None:
    await websocket.accept()
    token = websocket.query_params.get("token")
    if not settings.api_token or token != settings.api_token:
        await websocket.close(code=4001, reason="Invalid token")
        return

    app_state.status_subscribers.add(websocket)
    logger.info(f"WebSocket connected. Total: {len(app_state.status_subscribers)}")

    try:
        if app_state.printer_client:
            await websocket.send_json({"type": "status", "data": app_state.printer_client.status.model_dump(mode="json")})
        while True:
            try:
                msg = await websocket.receive_text()
                if msg == "ping":
                    await websocket.send_text("pong")
            except WebSocketDisconnect:
                break
    except WebSocketDisconnect:
        pass
    except Exception as e:
        logger.error(f"WebSocket error: {e}")
    finally:
        app_state.status_subscribers.discard(websocket)
        logger.info(f"WebSocket disconnected. Total: {len(app_state.status_subscribers)}")
