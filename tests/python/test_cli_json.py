"""Tests for photosorter_bridge.cli_json JSON-lines CLI entrypoint."""

from __future__ import annotations

import argparse
import io
import json
import logging
from pathlib import Path

import pytest

from photosorter_bridge import cli_json
from photosorter_bridge.pipeline_runner import StepInfo
from photosorter.config import DEFAULTS


def _run_args(tmp_path: Path, **overrides) -> argparse.Namespace:
    values = {
        "command": "run",
        "input_dir": tmp_path,
        "device": "cpu",
        "batch_size": 8,
        "pooling": "cls",
        "distance_threshold": 0.4,
        "linkage": "average",
        "temporal_weight": 0.0,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def test_build_parser_run_defaults(tmp_path):
    parser = cli_json.build_parser()
    args = parser.parse_args(["run", "--input-dir", str(tmp_path)])

    assert args.command == "run"
    assert args.input_dir == tmp_path
    assert args.device == DEFAULTS.device
    assert args.batch_size == DEFAULTS.batch_size
    assert args.pooling == DEFAULTS.pooling
    assert args.distance_threshold == DEFAULTS.distance_threshold
    assert args.linkage == DEFAULTS.linkage
    assert args.temporal_weight == DEFAULTS.temporal_weight


def test_build_parser_rejects_removed_check_manifest(tmp_path):
    parser = cli_json.build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["check-manifest", "--input-dir", str(tmp_path)])


def test_emit_writes_json_line_and_flushes(monkeypatch):
    buffer = io.StringIO()
    flush_calls = {"count": 0}

    class _StdoutProxy:
        def write(self, text: str) -> int:
            return buffer.write(text)

        def flush(self) -> None:
            flush_calls["count"] += 1

    monkeypatch.setattr(cli_json.sys, "stdout", _StdoutProxy())

    cli_json._emit({"type": "x", "value": 1})

    assert json.loads(buffer.getvalue().strip()) == {"type": "x", "value": 1}
    assert flush_calls["count"] == 1


def test_on_progress_emits_expected_payload(monkeypatch):
    emitted: list[dict] = []
    monkeypatch.setattr(cli_json, "_emit", lambda obj: emitted.append(obj))

    cli_json._on_progress(StepInfo("embed", "Extracting", 2, 7))

    assert emitted == [{
        "type": "progress",
        "step": "embed",
        "detail": "Extracting",
        "processed": 2,
        "total": 7,
    }]


def test_setup_stderr_logging_forces_single_stderr_handler(monkeypatch):
    root = logging.getLogger()
    old_handlers = list(root.handlers)
    old_level = root.level
    try:
        root.handlers = [logging.StreamHandler(io.StringIO())]
        fake_stderr = io.StringIO()
        monkeypatch.setattr(cli_json.sys, "stderr", fake_stderr)

        cli_json._setup_stderr_logging()

        assert len(root.handlers) == 1
        assert isinstance(root.handlers[0], logging.StreamHandler)
        assert root.handlers[0].stream is fake_stderr
        assert root.level == logging.INFO
    finally:
        root.handlers = old_handlers
        root.setLevel(old_level)


def test_handle_run_success_emits_complete(monkeypatch, tmp_path):
    seen = {}
    emitted: list[dict] = []

    def fake_run_pipeline(args: argparse.Namespace, on_progress):
        seen["args"] = args
        on_progress(StepInfo("discover", "Found", 10, 10))

    monkeypatch.setattr(cli_json, "run_pipeline_with_progress", fake_run_pipeline)
    monkeypatch.setattr(cli_json, "_emit", lambda obj: emitted.append(obj))

    args = _run_args(tmp_path, device="mps", batch_size=16, pooling="cls+avg", distance_threshold=0.33)
    cli_json._handle_run(args)

    assert seen["args"].input_dir == tmp_path
    assert seen["args"].device == "mps"
    assert seen["args"].batch_size == 16
    assert seen["args"].pooling == "cls+avg"
    assert seen["args"].distance_threshold == 0.33

    assert emitted[0]["type"] == "progress"
    assert emitted[-1] == {
        "type": "complete",
        "manifest_path": str(tmp_path.resolve() / DEFAULTS.manifest_filename),
    }


def test_handle_run_error_emits_error_and_exits(monkeypatch, tmp_path):
    monkeypatch.setattr(cli_json, "run_pipeline_with_progress", lambda _args, on_progress: (_ for _ in ()).throw(RuntimeError("boom")))

    emitted: list[dict] = []
    monkeypatch.setattr(cli_json, "_emit", lambda obj: emitted.append(obj))

    with pytest.raises(SystemExit) as exc:
        cli_json._handle_run(_run_args(tmp_path))

    assert exc.value.code == 1
    assert emitted == [{"type": "error", "message": "boom"}]


def test_main_dispatches_run(monkeypatch, tmp_path):
    called = {"setup": 0, "run": None}

    class _FakeParser:
        def parse_args(self):
            return _run_args(tmp_path, command="run")

    monkeypatch.setattr(cli_json, "_setup_stderr_logging", lambda: called.__setitem__("setup", called["setup"] + 1))
    monkeypatch.setattr(cli_json, "build_parser", lambda: _FakeParser())
    monkeypatch.setattr(cli_json, "_handle_run", lambda args: called.__setitem__("run", args))

    cli_json.main()

    assert called["setup"] == 1
    assert called["run"].command == "run"
