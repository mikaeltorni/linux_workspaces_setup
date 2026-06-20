"""Tests for gsettings string-array helpers used by workspace_setup.sh."""

from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE_PATH = ROOT / "lib" / "gsettings_strv.py"


def load_module():
    spec = importlib.util.spec_from_file_location("workspace_gsettings_strv", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def test_parse_strv_accepts_gsettings_array_prefix():
    mod = load_module()

    assert mod.parse_strv("@as ['alpha', 'beta']") == ["alpha", "beta"]


def test_parse_strv_returns_empty_list_for_invalid_values():
    mod = load_module()

    assert mod.parse_strv("not an array") == []
    assert mod.parse_strv("{'not': 'a list'}") == []


def test_append_strv_deduplicates_existing_values():
    mod = load_module()

    result = mod.append_strv("['one', 'two', 'one']", "three")

    assert result == ["one", "two", "three"]
    assert mod.format_strv(result) == "['one', 'two', 'three']"


def test_remove_strv_drops_matching_values():
    mod = load_module()

    assert mod.remove_strv("['one', 'two', 'one']", "one") == ["two"]


def test_cli_formats_updated_array_from_current_environment(monkeypatch):
    monkeypatch.setenv("CURRENT", "@as ['one']")

    completed = subprocess.run(
        [sys.executable, str(MODULE_PATH), "append", "two"],
        check=True,
        text=True,
        capture_output=True,
    )

    assert completed.stdout.strip() == "['one', 'two']"
