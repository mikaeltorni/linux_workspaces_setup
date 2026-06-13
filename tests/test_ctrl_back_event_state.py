#!/usr/bin/env python3
"""Characterization tests for Ctrl+Back input event state."""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
MODULE_PATH = (
    ROOT_DIR / "configs" / "window-hotkeys" / "ctrl_back_event_state.py"
)


def load_module():
    """Load the event-state module from the installer asset directory."""
    spec = importlib.util.spec_from_file_location(
        "ctrl_back_event_state",
        MODULE_PATH,
    )
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_ctrl_state_tracks_press_repeat_and_release():
    state = load_module().CtrlBackEventState()
    key = ("/dev/input/event4", 29)

    state.update_ctrl(*key, value=1)
    state.update_ctrl(*key, value=2)
    assert state.ctrl_pressed == {key}

    state.update_ctrl(*key, value=0)
    assert state.ctrl_pressed == set()


def test_ctrl_back_on_grabbed_pointer_tiles_and_suppresses_click():
    state = load_module().CtrlBackEventState()
    ctrl_key = ("/dev/input/event3", 29)
    back_key = ("/dev/input/event4", 275)
    state.update_ctrl(*ctrl_key, value=1)

    pressed = state.handle_back(*back_key, value=1, grabbed=True)
    repeated = state.handle_back(*back_key, value=2, grabbed=True)
    released = state.handle_back(*back_key, value=0, grabbed=True)

    assert pressed.tile is True
    assert pressed.forward is False
    assert repeated.tile is False
    assert repeated.forward is False
    assert released.tile is False
    assert released.forward is False
    assert state.suppressed == set()


def test_ctrl_back_on_ungrabbed_device_tiles_without_suppression():
    state = load_module().CtrlBackEventState()
    state.update_ctrl("/dev/input/event3", 29, value=1)

    decision = state.handle_back(
        "/dev/input/event4",
        275,
        value=1,
        grabbed=False,
    )

    assert decision.tile is True
    assert decision.forward is False
    assert state.suppressed == set()


def test_plain_back_is_forwarded_only_for_grabbed_pointer():
    state = load_module().CtrlBackEventState()

    grabbed = state.handle_back(
        "/dev/input/event4",
        275,
        value=1,
        grabbed=True,
    )
    monitored = state.handle_back(
        "/dev/input/event5",
        275,
        value=1,
        grabbed=False,
    )

    assert grabbed.tile is False
    assert grabbed.forward is True
    assert monitored.tile is False
    assert monitored.forward is False


def test_clear_device_drops_only_that_devices_pending_state():
    state = load_module().CtrlBackEventState()
    removed_path = "/dev/input/event3"
    retained_path = "/dev/input/event4"

    state.update_ctrl(removed_path, 29, value=1)
    state.update_ctrl(retained_path, 97, value=1)
    state.suppressed.update(
        {
            (removed_path, 275),
            (retained_path, 276),
        }
    )

    state.clear_device(removed_path)

    assert state.ctrl_pressed == {(retained_path, 97)}
    assert state.suppressed == {(retained_path, 276)}
