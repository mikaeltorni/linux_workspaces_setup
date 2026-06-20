"""gsettings-strv.py - helpers for GNOME gsettings string-array values.

This helper is installed beside apply-system-bindings.sh so the deployed
extension can mutate gsettings string arrays without embedding Python parsers in
shell heredocs.
"""

from __future__ import annotations

import ast
import os
import sys


def parse_strv(raw: str | None) -> list[str]:
    """Parse gsettings string-array output into normalized string values."""
    value = (raw or "").strip()
    if value.startswith("@as "):
        value = value[4:].strip()

    try:
        parsed = ast.literal_eval(value) if value else []
    except (SyntaxError, ValueError):
        return []

    if not isinstance(parsed, list):
        return []

    return [str(item) for item in parsed]


def unique_values(values: list[str]) -> list[str]:
    """Return values with duplicates removed while preserving first appearance."""
    return list(dict.fromkeys(values))


def append_strv(raw: str | None, value: str) -> list[str]:
    """Return normalized values with ``value`` appended if it is not present."""
    current = unique_values(parse_strv(raw))
    if value and value not in current:
        current.append(value)
    return current


def remove_strv(raw: str | None, value: str) -> list[str]:
    """Return normalized values with every occurrence of ``value`` removed."""
    return [item for item in parse_strv(raw) if item != value]


def format_strv(values: list[str]) -> str:
    """Serialize values for ``gsettings set``."""
    return "[" + ", ".join(repr(str(item)) for item in values) + "]"


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint used by apply-system-bindings.sh."""
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) != 2 or args[0] not in {"append", "remove"}:
        print("Usage: gsettings-strv.py append|remove <value>", file=sys.stderr)
        return 2

    action, value = args
    current = os.environ.get("CURRENT", "")
    result = append_strv(current, value) if action == "append" else remove_strv(current, value)
    print(format_strv(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
