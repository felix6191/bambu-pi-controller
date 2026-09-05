"""Tests for Bambu MQTT protocol."""
import pytest
from app.mqtt.protocol import (
    build_request, parse_push_message, parse_report_message,
    PrinterState, PrintJobInfo, PrinterStatus
)


class TestProtocol:
    def test_build_request(self):
        payload = build_request("0001", "start_print", {"file": "test.gcode"})
        assert "0001" in payload and "start_print" in payload

    def test_parse_push_message(self):
        msg = parse_push_message('{"sequence": "0001", "command": "push", "data": {}}')
        assert msg is not None and msg.sequence == "0001"

    def test_parse_report_message(self):
        msg = parse_report_message('{"sequence": "0001", "command": "start_print", "result": 0, "data": {}}')
        assert msg is not None and msg.result == 0

    def test_parse_invalid_json(self):
        assert parse_push_message("invalid") is None
        assert parse_report_message("invalid") is None

    def test_printer_state_enum(self):
        assert PrinterState.IDLE.value == "idle"
        assert PrinterState.PRINTING.value == "printing"

    def test_print_job_info(self):
        job = PrintJobInfo(progress=50.0, elapsed_time=3600, remaining_time=3600)
        assert job.formatted_elapsed == "1h 0m"

    def test_printer_status_model(self):
        status = PrinterStatus(state=PrinterState.PRINTING, nozzle_temp=210.0)
        data = status.model_dump(mode="json")
        assert data["state"] == "printing"