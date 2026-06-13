"""State transitions for Ctrl+Back input event handling.

This module contains no evdev or GNOME dependencies so the suppression and
forwarding decisions can be tested independently from the running service.
"""

from __future__ import annotations

from typing import NamedTuple


class BackEventDecision(NamedTuple):
    """Actions the service should take for a Back button event."""

    tile: bool
    forward: bool


class CtrlBackEventState:
    """Track pressed Ctrl keys and suppressed Back button events."""

    def __init__(self) -> None:
        """Initialize empty key-state collections."""
        self.ctrl_pressed: set[tuple[str, int]] = set()
        self.suppressed: set[tuple[str, int]] = set()

    def update_ctrl(self, path: str, code: int, value: int) -> None:
        """Apply a Ctrl key press, repeat, or release event.

        Args:
            path: Event device path that emitted the key event.
            code: Evdev key code for the left or right Ctrl key.
            value: Evdev key value; zero releases and nonzero values press.
        """
        key = (path, code)
        if value == 0:
            self.ctrl_pressed.discard(key)
        else:
            self.ctrl_pressed.add(key)

    def handle_back(
        self,
        path: str,
        code: int,
        value: int,
        grabbed: bool,
    ) -> BackEventDecision:
        """Decide whether to tile, forward, or suppress a Back event.

        Args:
            path: Event device path that emitted the button event.
            code: Evdev code for the Back button.
            value: Evdev button value; one presses and zero releases.
            grabbed: Whether the service exclusively owns the source device.

        Returns:
            A decision indicating whether the service should tile the focused
            window and whether it should forward the input event.
        """
        key = (path, code)

        if value == 1 and self.ctrl_pressed:
            if grabbed:
                self.suppressed.add(key)
            return BackEventDecision(tile=True, forward=False)

        if key in self.suppressed:
            if value == 0:
                self.suppressed.discard(key)
            return BackEventDecision(tile=False, forward=False)

        return BackEventDecision(tile=False, forward=grabbed)

    def clear_device(self, path: str) -> None:
        """Drop pending key state associated with a closed input device.

        Args:
            path: Event device path whose state should be forgotten.
        """
        pressed_for_device = {
            key for key in self.ctrl_pressed if key[0] == path
        }
        suppressed_for_device = {
            key for key in self.suppressed if key[0] == path
        }
        self.ctrl_pressed.difference_update(pressed_for_device)
        self.suppressed.difference_update(suppressed_for_device)
