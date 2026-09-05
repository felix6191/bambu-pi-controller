"""File pipeline: upload STL/3MF → slice on Pi → FTP to printer SD → start print.

Stages: uploaded → queued → slicing → sliced → uploading → starting → printing → done/failed
Only one slice/print job runs at a time (Pi 4 CPU). Progress is broadcast
over the existing WebSocket as {"type": "job", "data": {...}}.
"""
import asyncio
import ftplib
import json
import os
import shutil
import socket
import subprocess
import uuid
from dataclasses import dataclass, field, asdict
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, UploadFile, File, Form
from pydantic import BaseModel, Field
from loguru import logger

from app.core.config import settings
from app.core import state as app_state
from app.mqtt.client import BambuMQTTClient

router = APIRouter()

ALLOWED_EXTS = {".stl", ".3mf", ".obj", ".step"}
MAX_UPLOAD_MB = int(os.environ.get("MAX_UPLOAD_MB", "200"))


class JobStage(str, Enum):
    UPLOADED = "uploaded"
    QUEUED = "queued"
    SLICING = "slicing"
    SLICED = "sliced"
    UPLOADING = "uploading"
    STARTING = "starting"
    PRINTING = "printing"
    DONE = "done"
    FAILED = "failed"


@dataclass
class SliceJob:
    id: str
    filename: str
    size_bytes: int
    stage: str = JobStage.UPLOADED.value
    progress: float = 0.0  # 0-100 within current stage context
    filament: str = "pla"
    quality: str = "standard"
    supports: bool = False
    infill: int = 15
    gcode_name: str = ""
    error: str = ""
    created_at: str = ""
    updated_at: str = ""

    def touch(self) -> None:
        self.updated_at = datetime.now(timezone.utc).isoformat()


_JOBS: dict[str, SliceJob] = {}
_WORKER_LOCK = asyncio.Lock()


def storage_dir() -> Path:
    root = Path(os.environ.get("STORAGE_DIR", Path(__file__).resolve().parents[2] / "storage"))
    root.mkdir(parents=True, exist_ok=True)
    (root / "uploads").mkdir(exist_ok=True)
    (root / "gcode").mkdir(exist_ok=True)
    return root


def profiles_dir() -> Path:
    return Path(__file__).resolve().parents[2] / "profiles"


def _jobs_file() -> Path:
    return storage_dir() / "jobs.json"


def _persist() -> None:
    try:
        _jobs_file().write_text(json.dumps({k: asdict(v) for k, v in _JOBS.items()}), encoding="utf-8")
    except Exception as e:
        logger.warning(f"job persist failed: {e}")


def _load_persisted() -> None:
    try:
        raw = json.loads(_jobs_file().read_text(encoding="utf-8"))
        for jid, d in raw.items():
            job = SliceJob(**{k: d.get(k, getattr(SliceJob, k, "")) for k in SliceJob.__dataclass_fields__})
            # Anything mid-flight during a restart goes back to a safe stage
            if job.stage in (JobStage.QUEUED.value, JobStage.SLICING.value,
                             JobStage.UPLOADING.value, JobStage.STARTING.value):
                job.stage = JobStage.UPLOADED.value if not job.gcode_name else JobStage.SLICED.value
            _JOBS[jid] = job
    except Exception:
        pass


_load_persisted()


async def _broadcast(job: SliceJob) -> None:
    job.touch()
    _persist()
    await app_state.broadcast_status({"type": "job", "data": asdict(job)})


def _set(job: SliceJob, stage: JobStage, progress: float = 0.0, error: str = "") -> None:
    job.stage = stage.value
    job.progress = progress
    if error:
        job.error = error


def _slicer_cmd() -> str:
    return os.environ.get("SLICER_CMD", "prusa-slicer")


def _slicer_template() -> str:
    # PrusaSlicer-compatible flags by default; OrcaSlicer users override, e.g.:
    # orcaslicer --slice -o {out} --load {machine} --load {filament} --load {process} {input}
    return os.environ.get(
        "SLICER_TEMPLATE",
        "{cmd} --export-gcode --output {out} --load {machine} --load {filament} --load {process} {input}",
    )


def _filament_temps(key: str) -> tuple[int, int]:
    try:
        data = json.loads((profiles_dir() / "filaments.json").read_text(encoding="utf-8"))
        f = data.get(key.lower(), data["pla"])
        return int(f["nozzle"]), int(f["bed"])
    except Exception:
        return 220, 65


def _render_machine_profile(filament: str, job_dir: Path) -> Path:
    nozzle, bed = _filament_temps(filament)
    src = (profiles_dir() / "machine_a1.ini").read_text(encoding="utf-8")
    merged = src.replace("{{NOZZLE}}", str(nozzle)).replace("{{BED}}", str(bed))
    out = job_dir / "machine_merged.ini"
    out.write_text(merged, encoding="utf-8")
    # Optional per-job overrides (supports / infill) as extra load file
    return out


async def _run_slice(job: SliceJob) -> None:
    """Background worker: slice exactly one job at a time."""
    async with _WORKER_LOCK:
        try:
            _set(job, JobStage.SLICING, 5.0)
            await _broadcast(job)

            uploads = storage_dir() / "uploads"
            src = uploads / f"{job.id}_{job.filename}"
            if not src.exists():
                raise RuntimeError("Upload-Datei nicht gefunden (evtl. gelöscht)")
            job_dir = storage_dir() / "gcode" / job.id
            job_dir.mkdir(parents=True, exist_ok=True)

            machine = _render_machine_profile(job.filament, job_dir)
            filament = profiles_dir() / f"filament_{job.filament.lower()}.ini"
            process = profiles_dir() / f"process_{job.quality.lower()}.ini"
            if not filament.exists():
                raise RuntimeError(f"Filament-Profil '{job.filament}' fehlt")
            if not process.exists():
                raise RuntimeError(f"Qualitäts-Profil '{job.quality}' fehlt")
            overrides = job_dir / "overrides.ini"
            overrides.write_text(
                "[print]\n"
                f"fill_density = {max(0, min(100, job.infill))}%\n"
                f"support_material = {1 if job.supports else 0}\n",
                encoding="utf-8",
            )
            out = job_dir / f"{Path(job.filename).stem}.gcode"

            cmd = _slicer_cmd()
            if shutil.which(cmd.split()[0]) is None:
                raise RuntimeError(
                    f"Slicer '{cmd}' nicht auf dem Pi installiert. "
                    "ARM64-Build (PrusaSlicer/OrcaSlicer) installieren und ggf. SLICER_CMD/SLICER_TEMPLATE setzen — siehe README."
                )
            command = _slicer_template().format(
                cmd=cmd, out=str(out), machine=str(machine),
                filament=str(filament), process=str(process),
                overrides=str(overrides), input=str(src),
            )
            # Load overrides too (harmless if slicer ignores the extra --load)
            if "--load {overrides}" not in os.environ.get("SLICER_TEMPLATE", ""):
                command = command.replace(str(process), f"{process} --load {overrides}")
            logger.info(f"Slicing {job.id}: {command}")
            _set(job, JobStage.SLICING, 15.0)
            await _broadcast(job)

            loop = asyncio.get_running_loop()
            proc = await loop.run_in_executor(
                None,
                lambda: subprocess.run(command, shell=True, capture_output=True, text=True, timeout=int(os.environ.get("SLICE_TIMEOUT_S", "1800"))),
            )
            tail = (proc.stderr or proc.stdout or "")[-2000:]
            if proc.returncode != 0 or not out.exists():
                raise RuntimeError(f"Slicen fehlgeschlagen (Code {proc.returncode}). {tail[-500:]}")

            job.gcode_name = out.name
            _set(job, JobStage.SLICED, 100.0)
            await _broadcast(job)
            logger.info(f"Sliced {job.id} -> {out} ({out.stat().st_size} bytes)")
        except Exception as e:
            logger.error(f"Slice failed {job.id}: {e}")
            _set(job, JobStage.FAILED, 0.0, error=str(e)[:500])
            await _broadcast(job)


def _ftp_upload(local: Path, remote_name: str, host: str, code: str, port: int) -> None:
    ftp: ftplib.FTP | None = None
    try:
        ftp = ftplib.FTP()
        ftp.connect(host, port, timeout=30)
        ftp.login("bblp", code)
        ftp.set_pasv(True)
        with local.open("rb") as fh:
            ftp.storbinary(f"STOR {remote_name}", fh)
    finally:
        try:
            if ftp:
                ftp.quit()
        except Exception:
            pass


async def _run_print_to_printer(job: SliceJob, client: BambuMQTTClient) -> None:
    async with _WORKER_LOCK:
        try:
            gcode = storage_dir() / "gcode" / job.id / job.gcode_name
            if not job.gcode_name or not gcode.exists():
                raise RuntimeError("Kein G-Code vorhanden — erst slicen")
            _set(job, JobStage.UPLOADING, 10.0)
            await _broadcast(job)

            host = settings.printer_host
            code = settings.printer_access_code
            ports: list[int] = []
            try:
                ports.append(int(os.environ.get("FTP_PORT", "22")))
            except ValueError:
                ports.append(22)
            if 22 in ports:
                ports.append(21)
            else:
                ports.append(22)
            loop = asyncio.get_running_loop()
            last_err = "unbekannt"
            for port in ports:
                try:
                    await loop.run_in_executor(None, _ftp_upload, gcode, job.gcode_name, host, code, port)
                    last_err = ""
                    break
                except (OSError, ftplib.all_errors, socket.timeout) as e:
                    last_err = str(e)[:200]
            if last_err:
                raise RuntimeError(f"FTP-Upload gescheitert (Ports 22/21 versucht): {last_err}")
            _set(job, JobStage.UPLOADING, 90.0)
            await _broadcast(job)

            _set(job, JobStage.STARTING, 50.0)
            await _broadcast(job)
            ok = await client.start_gcode_file(f"/{job.gcode_name}")
            if not ok:
                raise RuntimeError("Drucker hat den Start abgelehnt (Datei auf SD prüfen)")
            _set(job, JobStage.PRINTING, 100.0)
            await _broadcast(job)
        except Exception as e:
            logger.error(f"Print failed {job.id}: {e}")
            _set(job, JobStage.FAILED, 0.0, error=str(e)[:500])
            await _broadcast(job)


# ------------------------------------------------------------------ models ---

class SliceRequest(BaseModel):
    filament: str = Field(default="pla", pattern="^(pla|petg|tpu)$")
    quality: str = Field(default="standard", pattern="^(draft|standard|fine)$")
    supports: bool = False
    infill: int = Field(default=15, ge=0, le=100)


def _public(job: SliceJob) -> dict:
    d = asdict(job)
    return d


def _get_job_or_404(job_id: str) -> SliceJob:
    job = _JOBS.get(job_id)
    if job is None:
        from fastapi import HTTPException as HE
        raise HE(status_code=404, detail="Job nicht gefunden")
    return job


# ------------------------------------------------------------------ routes ---

@router.post("/upload")
async def upload_file(file: UploadFile = File(...)):
    name = Path(file.filename or "model.stl").name
    ext = Path(name).suffix.lower()
    if ext not in ALLOWED_EXTS:
        from fastapi import HTTPException as HE
        raise HE(status_code=400, detail=f"Nur {sorted(ALLOWED_EXTS)} werden unterstützt")
    job_id = uuid.uuid4().hex[:12]
    dest = storage_dir() / "uploads" / f"{job_id}_{name}"
    size = 0
    with dest.open("wb") as fh:
        while chunk := await file.read(1024 * 1024):
            size += len(chunk)
            if size > MAX_UPLOAD_MB * 1024 * 1024:
                dest.unlink(missing_ok=True)
                from fastapi import HTTPException as HE
                raise HE(status_code=413, detail=f"Datei zu groß (max. {MAX_UPLOAD_MB} MB)")
            fh.write(chunk)
    job = SliceJob(id=job_id, filename=name, size_bytes=size)
    job.created_at = job.updated_at = datetime.now(timezone.utc).isoformat()
    _JOBS[job_id] = job
    _persist()
    await app_state.broadcast_status({"type": "job", "data": asdict(job)})
    return _public(job)


@router.get("/jobs")
async def list_jobs():
    return {"jobs": [_public(j) for j in sorted(_JOBS.values(), key=lambda j: j.created_at, reverse=True)]}


@router.get("/jobs/{job_id}")
async def get_job(job_id: str):
    return _public(_get_job_or_404(job_id))


@router.delete("/jobs/{job_id}")
async def delete_job(job_id: str):
    job = _get_job_or_404(job_id)
    if job.stage in (JobStage.SLICING.value, JobStage.UPLOADING.value, JobStage.STARTING.value):
        from fastapi import HTTPException as HE
        raise HE(status_code=409, detail="Job läuft gerade — bitte warten")
    (storage_dir() / "uploads" / f"{job.id}_{job.filename}").unlink(missing_ok=True)
    shutil.rmtree(storage_dir() / "gcode" / job.id, ignore_errors=True)
    del _JOBS[job_id]
    _persist()
    return {"success": True}


@router.post("/jobs/{job_id}/slice")
async def slice_job(job_id: str, req: SliceRequest):
    job = _get_job_or_404(job_id)
    if job.stage in (JobStage.SLICING.value, JobStage.UPLOADING.value, JobStage.STARTING.value, JobStage.PRINTING.value):
        from fastapi import HTTPException as HE
        raise HE(status_code=409, detail="Job läuft bereits")
    job.filament = req.filament
    job.quality = req.quality
    job.supports = req.supports
    job.infill = req.infill
    job.error = ""
    _set(job, JobStage.QUEUED, 0.0)
    await _broadcast(job)
    asyncio.create_task(_run_slice(job))
    return _public(job)


@router.post("/jobs/{job_id}/print")
async def print_job(job_id: str, client: BambuMQTTClient = Depends(app_state.get_printer_client)):
    job = _get_job_or_404(job_id)
    if not job.gcode_name:
        from fastapi import HTTPException as HE
        raise HE(status_code=400, detail="Erst slicen, dann drucken")
    if job.stage in (JobStage.UPLOADING.value, JobStage.STARTING.value, JobStage.PRINTING.value):
        from fastapi import HTTPException as HE
        raise HE(status_code=409, detail="Job läuft bereits")
    job.error = ""
    asyncio.create_task(_run_print_to_printer(job, client))
    return _public(job)


@router.get("/profiles")
async def list_profiles():
    try:
        filaments = json.loads((profiles_dir() / "filaments.json").read_text(encoding="utf-8"))
        filaments.pop("_note", None)
    except Exception:
        filaments = {}
    return {
        "filaments": filaments,
        "qualities": {
            "draft": {"name": "Entwurf", "layer_mm": 0.28, "note": "Schnell & grob"},
            "standard": {"name": "Standard", "layer_mm": 0.20, "note": "Ausgewogen"},
            "fine": {"name": "Fein", "layer_mm": 0.12, "note": "Langsam & detailliert"},
        },
        "slicer": _slicer_cmd(),
    }
