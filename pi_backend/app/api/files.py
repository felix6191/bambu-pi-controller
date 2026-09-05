"""File pipeline: upload STL/3MF → slice on Pi → FTP to printer SD → start print.

Stages: uploaded → queued → slicing → sliced → uploading → starting → printing → done/failed
Only one slice/print job runs at a time (Pi 4 CPU). Progress is broadcast
over the existing WebSocket as {"type": "job", "data": {...}}.
"""
import asyncio
import ftplib
import json
import os
import re
import shlex
import shutil
import socket
import struct
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

# A1-Hardlimits (wie /printer/capabilities): G-Code darüber wird nie gedruckt.
MAX_NOZZLE_C = 300
MAX_BED_C = 100
# Bauraum A1 in mm (+ kleiner Toleranzpuffer für Purge-Linien am Rand)
BUILD_MM = 256.0
BUILD_TOL_MM = 10.0

# G-Codes, die in einer geslicten Datei nichts zu suchen haben
# (SD-Löschen, EEPROM, Logging). M112 (Not-Stopp) bleibt erlaubt.
_BLOCKED_GCODE = re.compile(r"^\s*(M30\b|M500\b|M501\b|M502\b|M503\b|M928\b)", re.IGNORECASE)
_TEMP_RE = {
    "nozzle": re.compile(r"^\s*M10[49]\b.*?S\s*(-?\d+\.?\d*)", re.IGNORECASE),
    "bed": re.compile(r"^\s*M(?:140|190)\b.*?S\s*(-?\d+\.?\d*)", re.IGNORECASE),
}
_MOVE_RE = re.compile(r"^\s*G[01]\b([^;]*)", re.IGNORECASE)
_AXIS_RE = re.compile(r"([XYZ])\s*(-?\d+\.?\d*)", re.IGNORECASE)


def _safe_stem(name: str, fallback: str = "model") -> str:
    """Dateiname entgiften: keine Pfade, keine Steuerzeichen, kein FTP-/Shell-Breakout."""
    stem = Path(name).stem.strip().replace("\x00", "")
    stem = re.sub(r"[^A-Za-z0-9._-]+", "_", stem).strip("._")[:60] or fallback
    return stem


def _looks_like_stl(head: bytes, total_hint: int = 0) -> bool:
    """Magic-Check für STL (ASCII 'solid' oder binär mit passender Facet-Zahl)."""
    if head.startswith(b"solid"):
        return True
    if len(head) >= 84:
        try:
            (facets,) = struct.unpack("<I", head[80:84])
        except struct.error:
            return False
        if facets == 0 or facets > 50_000_000:
            return False
        if total_hint > 0:
            # binär: 84 Header + 50 Byte/Facet (+ optionaler Footer)
            expect = 84 + facets * 50
            if abs(total_hint - expect) > 1024:
                return False
        return True
    return False


def _validate_gcode(path: Path) -> tuple[bool, str]:
    """G-Code vor FTP/Druck prüfen: Temps, Bauraum, Blocklist. (ok, grund)."""
    try:
        if path.stat().st_size == 0:
            return False, "G-Code ist leer"
        if path.stat().st_size > 100 * 1024 * 1024:
            return False, "G-Code zu groß (>100 MB)"
    except OSError:
        return False, "G-Code nicht lesbar"
    max_n = max_b = 0.0
    try:
        with path.open("r", encoding="utf-8", errors="ignore") as fh:
            for i, line in enumerate(fh):
                if i > 200_000:
                    break
                s = line.strip()
                if not s or s.startswith(";"):
                    continue
                if _BLOCKED_GCODE.match(s):
                    return False, f"Blockierter Befehl in Zeile {i + 1}: {s[:40]}"
                m = _TEMP_RE["nozzle"].match(s)
                if m:
                    try:
                        max_n = max(max_n, float(m.group(1)))
                    except ValueError:
                        pass
                m = _TEMP_RE["bed"].match(s)
                if m:
                    try:
                        max_b = max(max_b, float(m.group(1)))
                    except ValueError:
                        pass
                m = _MOVE_RE.match(s)
                if m:
                    for ax, val in _AXIS_RE.findall(m.group(1).upper()):
                        try:
                            v = float(val)
                        except ValueError:
                            continue
                        lim = BUILD_MM + BUILD_TOL_MM
                        if ax in ("X", "Y") and not (-lim <= v <= lim):
                            return False, f"Fahrt außerhalb Bauraum ({ax}{v}) in Zeile {i + 1}"
                        if ax == "Z" and not (-5 <= v <= lim):
                            return False, f"Fahrt außerhalb Bauraum (Z{v}) in Zeile {i + 1}"
    except OSError as e:
        return False, f"G-Code nicht lesbar: {e}"
    if max_n > MAX_NOZZLE_C:
        return False, f"Düsentemp {max_n:.0f}°C über A1-Limit ({MAX_NOZZLE_C}°C)"
    if max_b > MAX_BED_C:
        return False, f"Betttemp {max_b:.0f}°C über A1-Limit ({MAX_BED_C}°C)"
    return True, ""


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
    # Erweitert (0 / -1 = Profilwert gilt, s. SliceRequest)
    adv_layer_height: float = 0.0
    adv_walls: int = 0
    adv_brim: int = -1
    adv_nozzle: int = 0
    adv_bed: int = -1

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


def _upload_candidates(job: SliceJob) -> list[Path]:
    uploads = storage_dir() / "uploads"
    ext = Path(job.filename).suffix.lower()
    return [
        uploads / f"{job.id}_{_safe_stem(job.filename)}{ext}",  # neu (sanitized)
        uploads / f"{job.id}_{job.filename}",  # alt (Bestand)
    ]


def _find_upload(job: SliceJob) -> Path | None:
    for p in _upload_candidates(job):
        if p.exists():
            return p
    return None


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


def _render_machine_profile(filament: str, job_dir: Path,
                            nozzle: int | None = None, bed: int | None = None) -> Path:
    base_n, base_b = _filament_temps(filament)
    # Erweitert-Werte gewinnen (geclampt), sonst Profil
    n = max(0, min(MAX_NOZZLE_C, nozzle)) if nozzle else base_n
    b = max(0, min(MAX_BED_C, bed)) if bed is not None else base_b
    src = (profiles_dir() / "machine_a1.ini").read_text(encoding="utf-8")
    merged = src.replace("{{NOZZLE}}", str(n)).replace("{{BED}}", str(b))
    out = job_dir / "machine_merged.ini"
    out.write_text(merged, encoding="utf-8")
    # Optional per-job overrides (supports / infill) as extra load file
    return out


def _render_overrides(job: SliceJob, job_dir: Path) -> Path:
    """Feintuning-Datei (wird als letztes --load angehängt, gewinnt also).
    Nur gesetzte Erweitert-Werte landen hier, sonst gilt das Profil."""
    lines = [
        "[print]",
        f"fill_density = {max(0, min(100, job.infill))}%",
        f"support_material = {1 if job.supports else 0}",
    ]
    if job.adv_layer_height > 0:
        lh = max(0.08, min(0.28, job.adv_layer_height))
        lines += [f"layer_height = {lh}", f"first_layer_height = {lh}"]
    if job.adv_walls > 0:
        lines.append(f"perimeters = {max(1, min(5, job.adv_walls))}")
    if job.adv_brim >= 0:
        lines.append(f"brim_width = {5 if job.adv_brim else 0}")
    if job.adv_nozzle > 0 or job.adv_bed >= 0:
        lines.append("[filament]")
        if job.adv_nozzle > 0:
            nt = max(150, min(MAX_NOZZLE_C, job.adv_nozzle))
            lines += [f"nozzle_temperature = {nt}", f"first_layer_temperature = {nt}"]
        if job.adv_bed >= 0:
            bt = max(0, min(MAX_BED_C, job.adv_bed))
            lines += [f"bed_temperature = {bt}", f"first_layer_bed_temperature = {bt}"]
    out = job_dir / "overrides.ini"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return out


async def _run_slice(job: SliceJob) -> None:
    """Background worker: slice exactly one job at a time."""
    async with _WORKER_LOCK:
        try:
            _set(job, JobStage.SLICING, 5.0)
            await _broadcast(job)

            uploads = storage_dir() / "uploads"
            src = _find_upload(job)
            if src is None:
                raise RuntimeError("Upload-Datei nicht gefunden (evtl. gelöscht)")
            job_dir = storage_dir() / "gcode" / job.id
            job_dir.mkdir(parents=True, exist_ok=True)

            # Re-Check vor dem Slicen (Datei könnte seit Upload ersetzt sein)
            try:
                with src.open("rb") as fh:
                    head = fh.read(4096)
                ext0 = src.suffix.lower()
                if ext0 == ".stl" and not _looks_like_stl(head, total_hint=src.stat().st_size):
                    raise RuntimeError("Upload ist kein gültiges STL mehr — bitte erneut hochladen")
            except OSError:
                raise RuntimeError("Upload-Datei nicht lesbar")

            machine = _render_machine_profile(
                job.filament, job_dir,
                nozzle=job.adv_nozzle or None,
                bed=job.adv_bed if job.adv_bed >= 0 else None,
            )
            filament = profiles_dir() / f"filament_{job.filament.lower()}.ini"
            process = profiles_dir() / f"process_{job.quality.lower()}.ini"
            if not filament.exists():
                raise RuntimeError(f"Filament-Profil '{job.filament}' fehlt")
            if not process.exists():
                raise RuntimeError(f"Qualitäts-Profil '{job.quality}' fehlt")
            overrides = _render_overrides(job, job_dir)
            out = job_dir / f"{_safe_stem(job.filename)}.gcode"

            cmd = _slicer_cmd()
            if shutil.which(shlex.split(cmd)[0]) is None:
                raise RuntimeError(
                    f"Slicer '{cmd}' nicht auf dem Pi installiert. "
                    "ARM64-Build (PrusaSlicer/OrcaSlicer) installieren und ggf. SLICER_CMD/SLICER_TEMPLATE setzen — siehe README."
                )
            # Pfade quoten, dann in argv zerlegen -> kein shell=True, kein
            # Breakout über Leerzeichen/Sonderzeichen in Dateinamen.
            command = _slicer_template().format(
                cmd=cmd, out=shlex.quote(str(out)), machine=shlex.quote(str(machine)),
                filament=shlex.quote(str(filament)), process=shlex.quote(str(process)),
                overrides=shlex.quote(str(overrides)), input=shlex.quote(str(src)),
            )
            # Load overrides too (harmless if slicer ignores the extra --load)
            if "--load {overrides}" not in os.environ.get("SLICER_TEMPLATE", ""):
                command = command.replace(shlex.quote(str(process)), f"{shlex.quote(str(process))} --load {shlex.quote(str(overrides))}")
            argv = shlex.split(command)
            logger.info(f"Slicing {job.id}: {' '.join(argv[:4])} … ({job.filename})")
            _set(job, JobStage.SLICING, 15.0)
            await _broadcast(job)

            loop = asyncio.get_running_loop()
            proc = await loop.run_in_executor(
                None,
                lambda: subprocess.run(argv, shell=False, capture_output=True, text=True, timeout=int(os.environ.get("SLICE_TIMEOUT_S", "1800"))),
            )
            tail = (proc.stderr or proc.stdout or "")[-2000:]
            if proc.returncode != 0 or not out.exists():
                raise RuntimeError(f"Slicen fehlgeschlagen (Code {proc.returncode}). {tail[-500:]}")

            ok, reason = _validate_gcode(out)
            if not ok:
                out.unlink(missing_ok=True)
                raise RuntimeError(f"G-Code abgelehnt (Sicherheitscheck): {reason}")

            job.gcode_name = out.name
            _set(job, JobStage.SLICED, 100.0)
            await _broadcast(job)
            logger.info(f"Sliced {job.id} -> {out} ({out.stat().st_size} bytes)")
        except Exception as e:
            logger.error(f"Slice failed {job.id}: {e}")
            _set(job, JobStage.FAILED, 0.0, error=str(e)[:500])
            await _broadcast(job)


def _ftp_upload(local: Path, remote_name: str, host: str, code: str, port: int) -> None:
    safe = _safe_stem(remote_name) + ".gcode"
    if any(c in remote_name for c in ("\r", "\n", "/", "\\")) or remote_name != safe:
        # Dateiname aus DB/Upload nie blind an FTP durchreichen (Resp-Injection)
        remote_name = safe
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
            if not job.gcode_name or job.gcode_name != _safe_stem(job.gcode_name) + ".gcode":
                raise RuntimeError("Ungültiger G-Code-Name — bitte erneut slicen")
            gcode = storage_dir() / "gcode" / job.id / job.gcode_name
            if not job.gcode_name or not gcode.exists():
                raise RuntimeError("Kein G-Code vorhanden — erst slicen")
            ok, reason = _validate_gcode(gcode)
            if not ok:
                raise RuntimeError(f"G-Code abgelehnt (Sicherheitscheck): {reason}")
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
    filament: str = Field(default="pla", pattern="^(pla|petg|tpu|asa)$")
    quality: str = Field(default="standard", pattern="^(draft|standard|fine)$")
    supports: bool = False
    infill: int = Field(default=15, ge=0, le=100)
    # Erweitert (optional, Desktop-Niveau). None = Profilwert.
    layer_height: float | None = Field(default=None, ge=0.08, le=0.28)
    walls: int | None = Field(default=None, ge=1, le=5)
    brim: bool | None = None
    nozzle_temp: int | None = Field(default=None, ge=150, le=300)
    bed_temp: int | None = Field(default=None, ge=0, le=100)


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
    raw = (file.filename or "model.stl").replace("\x00", "")
    name = Path(raw).name.strip()
    if any(c in name for c in ("\r", "\n", "/", "\\")) or not name or len(name) > 120:
        from fastapi import HTTPException as HE
        raise HE(status_code=400, detail="Ungültiger Dateiname")
    ext = Path(name).suffix.lower()
    if ext not in ALLOWED_EXTS:
        from fastapi import HTTPException as HE
        raise HE(status_code=400, detail=f"Nur {sorted(ALLOWED_EXTS)} werden unterstützt")
    job_id = uuid.uuid4().hex[:12]
    dest = storage_dir() / "uploads" / f"{job_id}_{_safe_stem(name)}{ext}"
    size = 0
    head = b""
    empty = True
    with dest.open("wb") as fh:
        while chunk := await file.read(1024 * 1024):
            empty = False
            size += len(chunk)
            if size > MAX_UPLOAD_MB * 1024 * 1024:
                dest.unlink(missing_ok=True)
                from fastapi import HTTPException as HE
                raise HE(status_code=413, detail=f"Datei zu groß (max. {MAX_UPLOAD_MB} MB)")
            if len(head) < 4096:
                head += chunk[: 4096 - len(head)]
            fh.write(chunk)
    if empty or size < 84:
        dest.unlink(missing_ok=True)
        from fastapi import HTTPException as HE
        raise HE(status_code=400, detail="Datei ist leer oder zu klein")
    # Magic-Check je Typ (kein Blind-Slicen von Müll)
    if ext == ".stl" and not _looks_like_stl(head, total_hint=size):
        dest.unlink(missing_ok=True)
        from fastapi import HTTPException as HE
        raise HE(status_code=400, detail="Kein gültiges STL (Header/Facet-Zahl prüfen)")
    if ext == ".3mf" and not head.startswith(b"PK"):
        dest.unlink(missing_ok=True)
        from fastapi import HTTPException as HE
        raise HE(status_code=400, detail="Kein gültiges 3MF (ZIP-Container erwartet)")
    if ext == ".obj" and not (head.lstrip().startswith((b"v ", b"vt ", b"vn ", b"f ", b"o ", b"g ", b"mtllib", b"#"))):
        dest.unlink(missing_ok=True)
        from fastapi import HTTPException as HE
        raise HE(status_code=400, detail="Kein gültiges OBJ (v/f-Zeilen erwartet)")
    job = SliceJob(id=job_id, filename=name, size_bytes=size)
    job.created_at = job.updated_at = datetime.now(timezone.utc).isoformat()
    _JOBS[job_id] = job
    _persist()
    await app_state.broadcast_status({"type": "job", "data": asdict(job)})
    return _public(job)


@router.get("/jobs")
async def list_jobs():
    return {"jobs": [_public(j) for j in sorted(_JOBS.values(), key=lambda j: j.created_at, reverse=True)]}


@router.get("/uploads/{job_id}")
async def download_upload(job_id: str):
    """Original-Modell für die 3D-Vorschau in der App zurückgeben."""
    import re as _re
    from fastapi.responses import FileResponse as _FR
    if not _re.fullmatch(r"[0-9a-f]{12}", job_id or ""):
        from fastapi import HTTPException as HE
        raise HE(status_code=404, detail="Job nicht gefunden")
    job = _get_job_or_404(job_id)
    src = _find_upload(job)
    if src is None:
        from fastapi import HTTPException as HE
        raise HE(status_code=404, detail="Upload nicht mehr vorhanden")
    media = {"stl": "model/stl", "obj": "model/obj", "3mf": "model/3mf", "step": "model/step"}.get(
        Path(job.filename).suffix.lower().lstrip("."), "application/octet-stream")
    return _FR(path=str(src), media_type=media, filename=job.filename)


@router.get("/jobs/{job_id}")
async def get_job(job_id: str):
    return _public(_get_job_or_404(job_id))


@router.delete("/jobs/{job_id}")
async def delete_job(job_id: str):
    job = _get_job_or_404(job_id)
    if job.stage in (JobStage.SLICING.value, JobStage.UPLOADING.value, JobStage.STARTING.value):
        from fastapi import HTTPException as HE
        raise HE(status_code=409, detail="Job läuft gerade — bitte warten")
    for p in _upload_candidates(job):
        p.unlink(missing_ok=True)
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
    job.adv_layer_height = req.layer_height or 0.0
    job.adv_walls = req.walls or 0
    job.adv_brim = -1 if req.brim is None else (1 if req.brim else 0)
    job.adv_nozzle = req.nozzle_temp or 0
    job.adv_bed = -1 if req.bed_temp is None else req.bed_temp
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
