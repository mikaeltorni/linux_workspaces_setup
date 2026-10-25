#!/usr/bin/env python3
"""Serialize and read the installer-owned app-rules user-rules.json file.

The app-rules@local GNOME Shell extension reads
``~/.config/app-rules/user-rules.json`` at enable time and applies one rule per
application: keep it on all workspaces (the master menu's ``[p]`` action) and/or
open it on a fixed display monitor (the master menu's ``[m]`` action).

Both dimensions live in the same file, so writing must merge rather than
overwrite: a run that only manages sticky selections must preserve the monitor
assignments already recorded, and vice versa. Doing that in Bash meant string
surgery on JSON; this helper owns the format instead.

The ``managed`` object records which dimensions have been explicitly written.
This distinguishes an old sticky-only file from a current file where the user
deliberately cleared every monitor assignment.

Sub-commands:
    write - merge the managed dimensions into the file and print a summary.
    list-sticky - print the .desktop ids currently kept on all workspaces.
    list-monitors - print ``group<TAB>monitor`` for current monitor rules,
                    overlaying requested defaults for legacy unmarked files.

Application groups are pipe-separated .desktop candidates for one application
("spotify.desktop|spotify_spotify.desktop"), matching the installer's startup
metadata; groups are separated by semicolons on the command line.
"""

import argparse
import json
import os
import sys
from pathlib import Path

# The shared logging helper lives in the installer framework, which the caller
# resolves for us (ISC_FUNCTIONS_DIR) and which is otherwise a sibling checkout.
# Logging is best effort here: the helper must keep working on a bare checkout.
for _candidate in (
    os.environ.get("ISC_FUNCTIONS_DIR", ""),
    str(Path(__file__).resolve().parents[1] / ".installer-support"),
):
    if _candidate and (Path(_candidate) / "logging_utils.py").is_file():
        sys.path.insert(0, _candidate)
        break

try:
    from logging_utils import get_logger, log_call

    LOGGER = get_logger(__name__, "app_rules_rules.log")
except Exception:  # pragma: no cover - a bare checkout has no framework yet.
    LOGGER = None

    def log_call(_logger):
        """Return a no-op decorator when the shared logger is unavailable.

        Args:
            _logger: Ignored; matches the real decorator factory's signature.

        Returns:
            Callable: A decorator that returns its function unchanged.
        """
        def decorator(function):
            """Return the decorated function unchanged.

            Args:
                function: The function to decorate.

            Returns:
                Callable: The same function.
            """
            return function
        return decorator


@log_call(LOGGER)
def parse_groups(raw):
    """Split a semicolon-separated group list into app-id lists.

    Args:
        raw: Semicolon-separated groups of pipe-separated .desktop ids.

    Returns:
        list[list[str]]: One list of .desktop ids per non-empty group.
    """
    groups = []
    for group in (raw or "").split(";"):
        ids = [candidate for candidate in group.split("|") if candidate]
        if ids:
            groups.append(ids)
    return groups


@log_call(LOGGER)
def parse_assignments(raw):
    """Split a semicolon-separated ``group=value`` list.

    Args:
        raw: Semicolon-separated ``group=monitor`` assignments, where group is
            pipe-separated .desktop ids and monitor is a 1-based number.

    Returns:
        list[tuple[list[str], int]]: (app ids, monitor number) pairs. Entries
        with a non-numeric or non-positive monitor are dropped.
    """
    assignments = []
    for entry in (raw or "").split(";"):
        if "=" not in entry:
            continue
        group, _, value = entry.rpartition("=")
        ids = [candidate for candidate in group.split("|") if candidate]
        try:
            monitor = int(value)
        except ValueError:
            continue
        if ids and monitor > 0:
            assignments.append((ids, monitor))
    return assignments


@log_call(LOGGER)
def parse_monitor_layout(raw):
    """Parse ``isc_list_monitors`` TSV rows into a number -> details map.

    Args:
        raw: TSV rows ``number connector name primary x y width height``.

    Returns:
        dict[int, dict]: Monitor number -> {"connector", "geometry"}. Rows that
        are malformed are skipped, which makes the resulting rule fall back to
        the plain monitor number.
    """
    layout = {}
    for line in (raw or "").splitlines():
        fields = line.split("\t")
        if len(fields) < 8:
            continue
        try:
            number = int(fields[0])
            geometry = {
                "x": int(fields[4]),
                "y": int(fields[5]),
                "width": int(fields[6]),
                "height": int(fields[7]),
            }
        except ValueError:
            continue
        layout[number] = {"connector": fields[1], "geometry": geometry}
    return layout


@log_call(LOGGER)
def read_rules(path):
    """Read the existing rules array from the user-rules file.

    Args:
        path: Path to user-rules.json.

    Returns:
        list[dict]: The stored rules, or an empty list when the file is
        missing, unreadable, or not of shape ``{"rules": [...]}``.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            parsed = json.load(handle)
    except (OSError, ValueError):
        return []
    rules = parsed.get("rules") if isinstance(parsed, dict) else None
    if not isinstance(rules, list):
        return []
    return [rule for rule in rules if isinstance(rule, dict) and isinstance(rule.get("appIds"), list)]


@log_call(LOGGER)
def read_managed_dimensions(path):
    """Read dimension-management markers from the rules document.

    Args:
        path: Path to user-rules.json.

    Returns:
        set[str]: Names explicitly managed by a previous write.
    """
    try:
        with open(path, "r", encoding="utf-8") as handle:
            parsed = json.load(handle)
    except (OSError, ValueError):
        return set()
    managed = parsed.get("managed") if isinstance(parsed, dict) else None
    if not isinstance(managed, dict):
        return set()
    return {name for name in ("sticky", "monitors") if managed.get(name) is True}


@log_call(LOGGER)
def group_key(app_ids):
    """Build the stable identity of an application group.

    Args:
        app_ids: The .desktop candidates for one application.

    Returns:
        str: A case-insensitive, order-independent key.
    """
    return "|".join(sorted(app_id.lower() for app_id in app_ids))


@log_call(LOGGER)
def merge_rules(existing, sticky_groups, monitor_assignments, layout,
                managed_sticky, managed_monitors):
    """Merge the managed dimensions into the existing rules.

    A dimension whose ``managed_*`` flag is false is copied from the existing
    rules untouched, so a standalone run of one feature never silently drops
    the other one's configuration.

    Args:
        existing: Rules currently stored in the file.
        sticky_groups: Groups selected to stay on all workspaces.
        monitor_assignments: (group, monitor number) pairs.
        layout: Monitor number -> connector/geometry details.
        managed_sticky: Whether this run owns the sticky selection.
        managed_monitors: Whether this run owns the monitor assignments.

    Returns:
        list[dict]: The merged rules, ordered sticky-first then monitor-only,
        each carrying only the keys it actually sets.
    """
    merged = {}
    order = []

    def slot(app_ids):
        """Return the merge slot for an app group, creating it if needed.

        Args:
            app_ids: The .desktop candidates for one application.

        Returns:
            dict: Mutable rule state for that group.
        """
        key = group_key(app_ids)
        if key not in merged:
            merged[key] = {"appIds": list(app_ids)}
            order.append(key)
        return merged[key]

    # Carry forward whatever this run does not manage.
    for rule in existing:
        entry = slot(rule["appIds"])
        if not managed_sticky and rule.get("sticky"):
            entry["sticky"] = True
        if not managed_monitors and rule.get("monitor"):
            entry["monitor"] = rule["monitor"]
            if rule.get("monitorConnector"):
                entry["monitorConnector"] = rule["monitorConnector"]
            if isinstance(rule.get("monitorGeometry"), dict):
                entry["monitorGeometry"] = rule["monitorGeometry"]

    if managed_sticky:
        for app_ids in sticky_groups:
            slot(app_ids)["sticky"] = True

    if managed_monitors:
        for app_ids, monitor in monitor_assignments:
            entry = slot(app_ids)
            entry["monitor"] = monitor
            details = layout.get(monitor)
            if details:
                entry["monitorConnector"] = details["connector"]
                entry["monitorGeometry"] = details["geometry"]

    # Drop groups that ended up with no actual rule (e.g. deselected apps).
    return [merged[key] for key in order if len(merged[key]) > 1]


@log_call(LOGGER)
def write_rules(path, rules, managed_dimensions):
    """Write the rules file atomically, creating parent directories.

    Args:
        path: Destination user-rules.json path.
        rules: Rule dictionaries to serialize.
        managed_dimensions: Dimension names explicitly controlled by the menu.

    Returns:
        None.
    """
    destination = Path(path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(".json.tmp")
    with open(temporary, "w", encoding="utf-8") as handle:
        document = {
            "managed": {
                name: True for name in ("sticky", "monitors")
                if name in managed_dimensions
            },
            "rules": rules,
        }
        json.dump(document, handle, indent=2)
        handle.write("\n")
    os.replace(temporary, destination)


@log_call(LOGGER)
def command_write(args):
    """Merge the managed dimensions into the file.

    Args:
        args: Parsed command-line arguments.

    Returns:
        int: 0 on success.
    """
    managed_dimensions = read_managed_dimensions(args.file)
    if args.managed_sticky:
        managed_dimensions.add("sticky")
    if args.managed_monitors:
        managed_dimensions.add("monitors")
    rules = merge_rules(
        read_rules(args.file),
        parse_groups(args.sticky),
        parse_assignments(args.monitors),
        parse_monitor_layout(args.monitor_layout),
        args.managed_sticky,
        args.managed_monitors,
    )
    write_rules(args.file, rules, managed_dimensions)
    sticky_count = sum(1 for rule in rules if rule.get("sticky"))
    monitor_count = sum(1 for rule in rules if rule.get("monitor"))
    print(f"{len(rules)} rule(s): {sticky_count} sticky, {monitor_count} monitor")
    return 0


@log_call(LOGGER)
def command_list_sticky(args):
    """Print the .desktop ids currently kept on all workspaces.

    Args:
        args: Parsed command-line arguments.

    Returns:
        int: 0 on success.
    """
    for rule in read_rules(args.file):
        if rule.get("sticky"):
            for app_id in rule["appIds"]:
                print(app_id)
    return 0


@log_call(LOGGER)
def command_list_monitors(args):
    """Print ``pipe-separated app ids<TAB>monitor number`` for monitor rules.

    Before the monitor dimension has a management marker, legacy defaults are
    overlaid and existing assignments win. Once marked, an empty list remains
    authoritative so an explicit user clear is preserved.

    Args:
        args: Parsed command-line arguments.

    Returns:
        int: 0 on success.
    """
    rules = read_rules(args.file)
    assignments = []
    if "monitors" not in read_managed_dimensions(args.file):
        assignments.extend(parse_assignments(args.legacy_defaults))
    assignments.extend(
        (rule["appIds"], rule["monitor"])
        for rule in rules if rule.get("monitor")
    )
    by_group = {}
    order = []
    for app_ids, monitor in assignments:
        key = group_key(app_ids)
        if key not in by_group:
            order.append(key)
        by_group[key] = (app_ids, monitor)
    for key in order:
        app_ids, monitor = by_group[key]
        print(f"{'|'.join(app_ids)}\t{monitor}")
    return 0


@log_call(LOGGER)
def main(argv=None):
    """Parse arguments and dispatch the requested sub-command.

    Args:
        argv: Argument vector, defaulting to sys.argv[1:].

    Returns:
        int: Process exit status.
    """
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--file", required=True, help="path to user-rules.json")
    subparsers = parser.add_subparsers(dest="command", required=True)

    writer = subparsers.add_parser("write", help="merge managed rules into the file")
    writer.add_argument("--sticky", default="", help="semicolon-separated sticky groups")
    writer.add_argument("--monitors", default="", help="semicolon-separated group=monitor pairs")
    writer.add_argument("--monitor-layout", default="", help="isc_list_monitors TSV rows")
    writer.add_argument("--managed-sticky", action="store_true", help="this run owns sticky rules")
    writer.add_argument("--managed-monitors", action="store_true", help="this run owns monitor rules")
    writer.set_defaults(handler=command_write)

    lister = subparsers.add_parser("list-sticky", help="print sticky .desktop ids")
    lister.set_defaults(handler=command_list_sticky)

    monitors = subparsers.add_parser("list-monitors", help="print group/monitor pairs")
    monitors.add_argument(
        "--legacy-defaults",
        default="",
        help="group=monitor defaults used until monitor choices are first managed",
    )
    monitors.set_defaults(handler=command_list_monitors)

    args = parser.parse_args(argv)
    return args.handler(args)


if __name__ == "__main__":
    raise SystemExit(main())
