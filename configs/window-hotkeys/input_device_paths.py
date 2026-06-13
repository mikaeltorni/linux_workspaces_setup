"""Helpers for deterministic Linux input device path ordering."""

from __future__ import annotations


def input_device_sort_key(path: str) -> tuple[int, int | str]:
    """Sort event device paths by their numeric suffix when available.

    Args:
        path: Linux input device path or another path-like identifier.

    Returns:
        A key that orders numbered ``/dev/input/eventN`` devices numerically
        before all other paths, which are ordered lexically.
    """
    prefix, separator, suffix = path.rpartition("event")
    if separator and prefix.endswith("/dev/input/") and suffix.isdigit():
        return (0, int(suffix))
    return (1, path)
