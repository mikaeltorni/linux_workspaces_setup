#!/usr/bin/env python3
"""Tests for input device path ordering helpers."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
MODULE_PATH = (
    ROOT_DIR / "configs" / "window-hotkeys" / "input_device_paths.py"
)


def load_module():
    """Load the path helper module from the installer asset directory."""
    spec = importlib.util.spec_from_file_location("input_device_paths", MODULE_PATH)
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_event_device_paths_sort_by_numeric_suffix():
    module = load_module()

    paths = [
        "/dev/input/event10",
        "/dev/input/event2",
        "/dev/input/event1",
    ]

    assert sorted(paths, key=module.input_device_sort_key) == [
        "/dev/input/event1",
        "/dev/input/event2",
        "/dev/input/event10",
    ]


def test_non_event_paths_sort_after_event_devices_lexically():
    module = load_module()

    paths = [
        "/dev/input/mouse0",
        "/tmp/event1",
        "/dev/input/event3",
        "/dev/input/by-id/keyboard",
    ]

    assert sorted(paths, key=module.input_device_sort_key) == [
        "/dev/input/event3",
        "/dev/input/by-id/keyboard",
        "/dev/input/mouse0",
        "/tmp/event1",
    ]


def test_event_path_requires_a_numeric_suffix():
    module = load_module()

    assert module.input_device_sort_key("/dev/input/event") == (
        1,
        "/dev/input/event",
    )
    assert module.input_device_sort_key("/dev/input/eventx") == (
        1,
        "/dev/input/eventx",
    )
