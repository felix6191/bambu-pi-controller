"""Tests for Bambu MQTT protocol."""
import pytest
from app.mqtt.protocol import (
    build_request,
    parse_push_message,
    parse_report_message,
    PrinterState,
    PrintCommand,
    PrintJobInfo,
    PrinterStatus,
)


class TestProtocol:
    def test_build_request(self):
        payload = build_request("0001", "start_print", {"file": "test.gcode"})
        assert "0001" in payload
        assert "start_print" in payload
        assert "test.gcode" in payload

    def test_parse_push_message(self):
        json_str = '{"sequence": "0001", "command": "push", "data": {"print": {"status": "printing"}}}'
        msg = parse_push_message(json_str)
        assert msg is not None
        assert msg.sequence == "0001"
        assert msg.command == "push"

    def test_parse_report_message(self):
        json_str = '{"sequence": "0001", "command": "start_print", "result": 0, "data": {}}'
        msg = parse_report_message(json_str)
        assert msg is not None
        assert msg.sequence == "0001"
        assert msg.result == 0

    def test_parse_invalid_json(self):
        assert parse_push_message("invalid") is None
        assert parse_report_message("invalid") is None

    def test_printer_state_enum(self):
        assert PrinterState.IDLE.value == "idle"
        assert PrinterState.PRINTING.value == "printing"
        assert PrinterState.ERROR.value == "error"

    def test_print_job_info(self):
        job = PrintJobInfo(
            name="test.gcode",
            progress=50.0,
            current_layer=10,
            total_layers=20,
            elapsed_time=3600,
            remaining_time=3600,
        )
        assert job.formatted_elapsed == "1h 0m"
        assert job.formatted_remaining == "1h 0m"

    def test_printer_status_model(self):
        status = PrinterStatus(
            state=PrinterState.PRINTING,
            nozzle_temp=210.0,
            nozzle_target_temp=210.0,
            bed_temp=60.0,
            bed_target_temp=60.0,
            chamber_temp=35.0,
            print_job=PrintJobInfo(name="test.gcode", progress=25.0),
            wifi_signal=-50,
        )
        assert status.state == PrinterState.PRINTING
        assert status.nozzle_temp == 210.0
        data = status.model_dump(mode="json")
        assert data["state"] == "printing"