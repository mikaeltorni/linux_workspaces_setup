"""D-Bus client for the monitor-window-hotkeys GNOME Shell extension.

This module isolates the session-bus wiring used to drive right-half tiling so
the request logic can be exercised independently from the evdev event loop.
"""

from __future__ import annotations

import gi

gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib

from logging_setup import get_logger


_log = get_logger("ctrl-back-window-tiler")

DBUS_BUS_NAME = "org.gnome.shell.extensions.MonitorWindowHotkeys"
DBUS_OBJECT_PATH = "/org/gnome/shell/extensions/monitor_window_hotkeys"
DBUS_INTERFACE = "org.gnome.shell.extensions.MonitorWindowHotkeys"


class TileRightClient:
    """Invoke the GNOME Shell extension's right-half tiling API over D-Bus.

    Args:
        proxy: An existing D-Bus proxy to use. When omitted, a session-bus
            proxy for the extension is created eagerly. Injecting a proxy lets
            tests exercise the request logic without a live session bus.
    """

    def __init__(self, proxy: Gio.DBusProxy | None = None) -> None:
        self._proxy = proxy if proxy is not None else self._create_proxy()

    @staticmethod
    def _create_proxy() -> Gio.DBusProxy:
        """Create a proxy for the GNOME Shell extension's tiling API."""
        return Gio.DBusProxy.new_for_bus_sync(
            Gio.BusType.SESSION,
            Gio.DBusProxyFlags.DO_NOT_LOAD_PROPERTIES,
            None,
            DBUS_BUS_NAME,
            DBUS_OBJECT_PATH,
            DBUS_INTERFACE,
            None,
        )

    def tile_right(self) -> None:
        """Tile the focused window directly, bypassing keyboard shortcuts."""
        try:
            self._proxy.call_sync(
                "TileRightHalf",
                None,
                Gio.DBusCallFlags.NONE,
                1000,
                None,
            )
            _log.info("tiled focused window to the right half")
        except GLib.Error as exc:
            _log.error("D-Bus tiling failed: %s", exc.message)
