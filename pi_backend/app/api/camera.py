"""Camera API routes."""
from fastapi import APIRouter, Depends, HTTPException, Response
from fastapi.responses import StreamingResponse
import httpx

from app.core.config import settings

router = APIRouter()


@router.get("/stream")
async def camera_stream():
    if not settings.camera_url:
        raise HTTPException(status_code=404, detail="Camera not configured")

    async def stream_generator():
        async with httpx.AsyncClient(
            auth=(settings.camera_username, settings.camera_password) if settings.camera_username else None,
            timeout=30.0,
        ) as client:
            async with client.stream("GET", settings.camera_url) as response:
                async for chunk in response.aiter_bytes(8192):
                    yield chunk

    return StreamingResponse(stream_generator(), media_type="multipart/x-mixed-replace; boundary=frame")


@router.get("/snapshot")
async def camera_snapshot():
    if not settings.camera_url:
        raise HTTPException(status_code=404, detail="Camera not configured")

    snapshot_url = settings.camera_url.replace("/stream", "/snapshot") if "/stream" in settings.camera_url else settings.camera_url

    async with httpx.AsyncClient(
        auth=(settings.camera_username, settings.camera_password) if settings.camera_username else None,
        timeout=10.0,
    ) as client:
        try:
            response = await client.get(snapshot_url)
            return Response(content=response.content, media_type="image/jpeg")
        except Exception:
            raise HTTPException(status_code=500, detail="Failed to get snapshot")