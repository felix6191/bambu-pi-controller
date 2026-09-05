"""Tests for the file pipeline (no slicer/printer needed)."""
import json
from pathlib import Path

from app.api.files import SliceJob, JobStage, ALLOWED_EXTS


class TestJobModel:
    def test_defaults(self):
        job = SliceJob(id="abc", filename="benchy.stl", size_bytes=123)
        assert job.stage == JobStage.UPLOADED.value
        assert job.progress == 0.0
        assert job.filament == "pla" and job.quality == "standard"

    def test_allowed_exts(self):
        assert ".stl" in ALLOWED_EXTS and ".3mf" in ALLOWED_EXTS


class TestProfiles:
    def test_filaments_json(self):
        root = Path(__file__).resolve().parents[1] / "profiles" / "filaments.json"
        data = json.loads(root.read_text(encoding="utf-8"))
        for key in ("pla", "petg", "tpu"):
            assert key in data
            assert 0 < data[key]["nozzle"] <= 300
            assert 0 < data[key]["bed"] <= 100

    def test_ini_files_exist(self):
        root = Path(__file__).resolve().parents[1] / "profiles"
        for name in ("machine_a1.ini", "filament_pla.ini", "filament_petg.ini",
                     "filament_tpu.ini", "process_draft.ini", "process_standard.ini",
                     "process_fine.ini"):
            assert (root / name).exists(), f"missing {name}"
        machine = (root / "machine_a1.ini").read_text(encoding="utf-8")
        assert "{{NOZZLE}}" in machine and "{{BED}}" in machine
        assert "256" in machine
