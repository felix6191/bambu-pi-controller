"""Tests for the real Bambu MQTT protocol mapping."""
from app.mqtt.protocol import (
    IncomingMessage,
    PrinterState,
    PrintJobInfo,
    PrinterStatus,
    SpeedLevel,
    build_envelope,
    parse_incoming,
    status_from_print,
)


class TestEnvelope:
    def test_build_print_pause(self):
        payload = build_envelope("print", "3", "pause")
        assert payload == '{"print": {"sequence_id": "3", "command": "pause"}}'

    def test_build_speed(self):
        payload = build_envelope("print", "4", "print_speed", {"param": "2"})
        assert '"param": "2"' in payload

    def test_parse_push_status(self):
        raw = '{"print": {"sequence_id": "2021", "command": "push_status", "gcode_state": "RUNNING"}}'
        msg = parse_incoming(raw)
        assert msg is not None
        assert isinstance(msg, IncomingMessage)
        assert msg.msg_type == "print"
        assert msg.command == "push_status"
        assert msg.payload["gcode_state"] == "RUNNING"

    def test_parse_invalid(self):
        assert parse_incoming("invalid") is None
        assert parse_incoming('{"a": 1, "b": 2}') is None

    def test_result_ok_case_insensitive(self):
        msg = parse_incoming('{"print": {"sequence_id": "1", "command": "pause", "result": "Success"}}')
        assert msg is not None and msg.ok


class TestSpeedLevels:
    def test_names(self):
        assert SpeedLevel(1).display_name == "Silent"
        assert SpeedLevel(4).display_name == "Ludicrous"
        assert SpeedLevel(3).effective_percent == 124

    def test_from_percent(self):
        assert SpeedLevel.from_percent(50) == SpeedLevel.SILENT
        assert SpeedLevel.from_percent(100) == SpeedLevel.STANDARD
        assert SpeedLevel.from_percent(124) == SpeedLevel.SPORT
        assert SpeedLevel.from_percent(166) == SpeedLevel.LUDICROUS


class TestStatusMapping:
    def _print(self, **kw):
        base = {
            "gcode_state": "RUNNING",
            "mc_percent": 42,
            "mc_remaining_time": 90,  # minutes!
            "nozzle_temper": 215.5,
            "nozzle_target_temper": 220,
            "bed_temper": 65.0,
            "bed_target_temper": 65,
            "chamber_temper": 31.0,
            "layer_num": 10,
            "total_layer_num": 100,
            "subtask_name": "benchy.3mf",
            "spd_lvl": 3,
            "spd_mag": 124,
            "cooling_fan_speed": "80",
            "wifi_signal": "-45dBm",
        }
        base.update(kw)
        return base

    def test_full_mapping(self):
        s = status_from_print(self._print(), PrinterStatus())
        assert s.state == PrinterState.PRINTING
        assert s.print_job.progress == 42
        assert s.print_job.remaining_time == 90 * 60
        assert s.nozzle_temp == 215.5
        assert s.print_job.current_layer == 10
        assert s.speed_level == 3 and s.print_speed == 124
        assert s.fan_speed == 80
        assert s.wifi_signal == -45

    def test_states(self):
        for raw, want in [("IDLE", "idle"), ("RUNNING", "printing"), ("PAUSE", "paused"),
                          ("FINISH", "idle"), ("FAILED", "error")]:
            s = status_from_print(self._print(gcode_state=raw), PrinterStatus())
            assert s.state.value == want

    def test_delta_merge_keeps_previous(self):
        prev = status_from_print(self._print(), PrinterStatus())
        nxt = status_from_print({"nozzle_temper": 216.0}, prev)
        assert nxt.nozzle_temp == 216.0
        assert nxt.print_job.name == "benchy.3mf"
        assert nxt.print_job.progress == 42
        assert nxt.speed_level == 3

    def test_formatting(self):
        job = PrintJobInfo(elapsed_time=3660, remaining_time=5400)
        assert job.formatted_elapsed == "1h 1m"
        assert job.formatted_remaining == "1h 30m"
