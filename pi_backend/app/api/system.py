"""System API routes."""
from fastapi import APIRouter, Depends
import psutil
import platform

router = APIRouter()


@router.get("/info")
async def system_info():
    """Get system information."""
    return {
        "hostname": platform.node(),
        "platform": platform.platform(),
        "python_version": platform.python_version(),
        "cpu_count": psutil.cpu_count(),
        "cpu_percent": psutil.cpu_percent(interval=0.1),
        "memory": {
            "total": psutil.virtual_memory().total,
            "available": psutil.virtual_memory().available,
            "percent": psutil.virtual_memory().percent,
        },
        "disk": {
            "total": psutil.disk_usage("/").total,
            "free": psutil.disk_usage("/").free,
            "percent": psutil.disk_usage("/").percent,
        },
    }


@router.get("/network")
async def network_info():
    """Get network interface information."""
    interfaces = {}
    for name, addrs in psutil.net_if_addrs().items():
        interfaces[name] = [
            {"family": str(addr.family), "address": addr.address, "netmask": addr.netmask}
            for addr in addrs
        ]
    return {"interfaces": interfaces}