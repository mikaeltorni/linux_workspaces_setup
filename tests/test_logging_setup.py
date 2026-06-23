#!/usr/bin/env python3
"""Tests for the centralized window-hotkeys logging utility."""

from __future__ import annotations

import importlib.util
import logging
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
MODULE_PATH = ROOT_DIR / "configs" / "window-hotkeys" / "logging_setup.py"


def load_module():
    """Load the logging_setup module from the installer asset directory."""
    spec = importlib.util.spec_from_file_location("logging_setup", MODULE_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_resolve_log_dir_creates_dot_log(tmp_path):
    module = load_module()

    log_dir = module.resolve_log_dir(tmp_path)

    assert log_dir == tmp_path / ".log"
    assert log_dir.is_dir()


def test_get_logger_writes_to_file_and_is_reused(tmp_path):
    module = load_module()
    name = "test-logger-unique"
    # Ensure a clean logger for this name regardless of prior runs.
    logging.Logger.manager.loggerDict.pop(name, None)

    log = module.get_logger(name, level=module.VERBOSE, base_dir=tmp_path)
    log.info("hello world")
    log.verbose("fine grained trace")
    for handler in log.handlers:
        handler.flush()

    log_file = tmp_path / ".log" / f"{name}.log"
    assert log_file.is_file()
    contents = log_file.read_text(encoding="utf-8")
    assert "hello world" in contents
    assert "VERBOSE" in contents

    # Re-fetching must not duplicate handlers.
    handler_count = len(log.handlers)
    again = module.get_logger(name, base_dir=tmp_path)
    assert again is log
    assert len(again.handlers) == handler_count


def test_log_call_records_arguments_and_return_value(tmp_path):
    module = load_module()
    name = "test-log-call-unique"
    logging.Logger.manager.loggerDict.pop(name, None)
    log = module.get_logger(name, level=logging.DEBUG, base_dir=tmp_path)

    @module.log_call(log)
    def combine(left: str, right: str = "b") -> str:
        return f"{left}-{right}"

    assert combine("a", right="z") == "a-z"
    for handler in log.handlers:
        handler.flush()

    contents = (tmp_path / ".log" / f"{name}.log").read_text(encoding="utf-8")
    assert (
        "ENTER test_logging_setup.py:"
        "test_log_call_records_arguments_and_return_value.<locals>.combine"
        "(left='a', right='z')"
    ) in contents
    assert (
        "EXIT test_logging_setup.py:"
        "test_log_call_records_arguments_and_return_value.<locals>.combine -> 'a-z'"
    ) in contents


def test_systemd_environment_uses_stream_without_private_log_file(
    tmp_path,
    monkeypatch,
):
    module = load_module()
    name = "test-systemd-sink-unique"
    logging.Logger.manager.loggerDict.pop(name, None)
    monkeypatch.setenv("INVOCATION_ID", "unit-test")
    monkeypatch.setenv("WINDOW_HOTKEYS_LOG_DIR", str(tmp_path))

    log = module.get_logger(name)
    log.info("journal only")
    for handler in log.handlers:
        handler.flush()

    assert not (tmp_path / ".log" / f"{name}.log").exists()
    assert any(isinstance(handler, logging.StreamHandler) for handler in log.handlers)
