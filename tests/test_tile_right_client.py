#!/usr/bin/env python3
"""Characterization tests for the D-Bus right-half tiling client."""

from __future__ import annotations

import importlib.util
import logging
import sys
from pathlib import Path

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib


ROOT_DIR = Path(__file__).resolve().parent.parent
WINDOW_HOTKEYS_DIR = ROOT_DIR / "configs" / "window-hotkeys"
MODULE_PATH = (
    WINDOW_HOTKEYS_DIR / "tile_right_client.py"
)


def load_module():
    """Load the tiling-client module from the installer asset directory."""
    if str(WINDOW_HOTKEYS_DIR) not in sys.path:
        sys.path.insert(0, str(WINDOW_HOTKEYS_DIR))
    logger = logging.getLogger("ctrl-back-window-tiler")
    for handler in logger.handlers[:]:
        handler.close()
        logger.removeHandler(handler)
    spec = importlib.util.spec_from_file_location(
        "tile_right_client",
        MODULE_PATH,
    )
    assert spec is not None
    assert spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeProxy:
    """Stand-in for a Gio.DBusProxy that records calls instead of dispatching."""

    def __init__(self, error: GLib.Error | None = None) -> None:
        self.calls: list[tuple] = []
        self._error = error

    def call_sync(self, method, params, flags, timeout, cancellable):
        self.calls.append((method, params, flags, timeout, cancellable))
        if self._error is not None:
            raise self._error
        return None


def test_constructor_uses_injected_proxy_without_touching_the_bus():
    module = load_module()
    proxy = FakeProxy()
    client = module.TileRightClient(proxy=proxy)
    assert isinstance(client, module.TileRightClient)
    assert proxy.calls == []


def test_tile_right_invokes_the_extension_dbus_method(capsys):
    proxy = FakeProxy()
    client = load_module().TileRightClient(proxy=proxy)

    client.tile_right()

    assert len(proxy.calls) == 1
    method, params, flags, timeout, cancellable = proxy.calls[0]
    assert method == "TileRightHalf"
    assert params is None
    assert flags == Gio.DBusCallFlags.NONE
    assert timeout == 1000
    assert cancellable is None
    captured = capsys.readouterr()
    assert "tiled focused window to the right half" in captured.err
    assert captured.out == ""


def test_tile_right_reports_dbus_failure_without_raising(capsys):
    error = GLib.Error.new_literal(GLib.quark_from_string("test"), "boom", 1)
    client = load_module().TileRightClient(proxy=FakeProxy(error=error))

    client.tile_right()

    captured = capsys.readouterr()
    assert "boom" in captured.err
    assert captured.out == ""


if __name__ == "__main__":
    import pytest

    raise SystemExit(pytest.main([__file__, "-v"]))
