"""Helpers for deterministic Linux input device path ordering and aliasing.

Components:
  - input_device_sort_key: Order ``/dev/input/eventN`` nodes deterministically.
  - stable_device_path: Resolve an event node to a reboot-stable by-id alias.
"""

from __future__ import annotations

import os


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


def stable_device_path(path: str, by_id_dir: str = "/dev/input/by-id") -> str:
    """Resolve an event node to a reboot-stable ``/dev/input/by-id`` alias.

    The kernel assigns ``/dev/input/eventN`` numbers in probe order, so they can
    change between reboots. The ``by-id`` directory holds persistent symlinks
    keyed by hardware identity; preferring one keeps a configured device filter
    valid across reboots. The chosen alias is resolved back to its event node by
    the tiler service via ``os.path.realpath``, so returning a symlink is safe.

    Args:
        path: Event device path such as ``/dev/input/event5``.
        by_id_dir: Directory scanned for persistent symlinks. Overridable so
            tests can supply a temporary directory instead of the real one.

    Returns:
        The first ``by-id`` symlink (sorted by name for determinism) that
        resolves to ``path``, or ``path`` unchanged when the directory is
        missing or no persistent alias points at the device.
    """
    target = os.path.realpath(path)
    try:
        entries = sorted(os.listdir(by_id_dir))
    except OSError:
        return path

    for name in entries:
        candidate = os.path.join(by_id_dir, name)
        if os.path.realpath(candidate) == target:
            return candidate
    return path
