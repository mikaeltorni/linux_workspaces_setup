#!/usr/bin/env python3
"""Tests for scripts/app_rules_rules.py, the user-rules.json serializer.

The file carries two independent installer dimensions - "keep on all
workspaces" ([p]) and "open on monitor N" ([m]) - so the merge behaviour, not
just the JSON shape, is what these tests pin down.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent.parent
SCRIPT = ROOT_DIR / "scripts" / "app_rules_rules.py"
SPOTIFY = "spotify.desktop|spotify_spotify.desktop"
DISCORD = "discord.desktop|discord_discord.desktop"
# isc_list_monitors rows: number connector name primary x y width height.
LAYOUT = (
    "1\tDP-4\tSamsung Electric Company 32\t1\t0\t0\t3840\t2160\n"
    "2\tHDMI-0\tLG Electronics 27\t0\t3840\t0\t2560\t1440\n"
)


def run_script(path, *args):
    """Run the serializer against a rules file.

    Args:
        path: Path to the user-rules.json file.
        *args: Sub-command and its arguments.

    Returns:
        subprocess.CompletedProcess: The finished process, output captured.
    """
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--file", str(path), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def read_rules(path):
    """Read the rules array from a user-rules file.

    Args:
        path: Path to the user-rules.json file.

    Returns:
        list[dict]: The stored rules.
    """
    return json.loads(Path(path).read_text(encoding="utf-8"))["rules"]


def read_document(path):
    """Read the complete persisted app-rules document.

    Args:
        path: Path to the user-rules.json file.

    Returns:
        dict: The parsed document, including management metadata.
    """
    return json.loads(Path(path).read_text(encoding="utf-8"))


def rule_for(rules, app_id):
    """Find the rule covering an application id.

    Args:
        rules: Rules read from the file.
        app_id: A .desktop id to look for.

    Returns:
        dict | None: The matching rule, or None when absent.
    """
    for rule in rules:
        if app_id in rule.get("appIds", []):
            return rule
    return None


def test_write_records_monitor_with_connector_and_geometry():
    """A monitor assignment stores the number plus the resolved display."""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "user-rules.json"
        proc = run_script(
            path, "write", "--managed-monitors",
            "--monitors", f"{SPOTIFY}=1;{DISCORD}=1",
            "--monitor-layout", LAYOUT,
        )
        assert proc.returncode == 0, proc.stderr
        spotify = rule_for(read_rules(path), "spotify.desktop")
        assert spotify["monitor"] == 1
        assert spotify["monitorConnector"] == "DP-4"
        assert spotify["monitorGeometry"]["width"] == 3840
        assert "sticky" not in spotify
        assert read_document(path)["managed"]["monitors"] is True


def test_monitor_run_preserves_unmanaged_sticky_rules():
    """A monitor-only run must not drop the [p] sticky selection."""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "user-rules.json"
        path.write_text(json.dumps({"rules": [
            {"appIds": ["code.desktop"], "sticky": True},
        ]}), encoding="utf-8")
        proc = run_script(
            path, "write", "--managed-monitors",
            "--monitors", f"{SPOTIFY}=2",
            "--monitor-layout", LAYOUT,
        )
        assert proc.returncode == 0, proc.stderr
        rules = read_rules(path)
        assert rule_for(rules, "code.desktop")["sticky"] is True
        assert rule_for(rules, "spotify.desktop")["monitor"] == 2


def test_sticky_run_preserves_unmanaged_monitor_rules():
    """A sticky-only run must not drop the [m] monitor assignments."""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "user-rules.json"
        path.write_text(json.dumps({"rules": [
            {"appIds": ["spotify.desktop"], "monitor": 1, "monitorConnector": "DP-4"},
        ]}), encoding="utf-8")
        proc = run_script(path, "write", "--managed-sticky", "--sticky", DISCORD)
        assert proc.returncode == 0, proc.stderr
        rules = read_rules(path)
        spotify = rule_for(rules, "spotify.desktop")
        assert spotify["monitor"] == 1
        assert spotify["monitorConnector"] == "DP-4"
        assert rule_for(rules, "discord.desktop")["sticky"] is True


def test_managed_run_clears_deselected_assignments():
    """Clearing a selection in the menu must remove the stale rule."""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "user-rules.json"
        path.write_text(json.dumps({"rules": [
            {"appIds": ["spotify.desktop"], "monitor": 1},
        ]}), encoding="utf-8")
        proc = run_script(path, "write", "--managed-monitors", "--monitors", "")
        assert proc.returncode == 0, proc.stderr
        assert read_rules(path) == []
        listed = run_script(path, "list-monitors")
        assert listed.returncode == 0, listed.stderr
        assert listed.stdout == ""


def test_one_rule_per_application_carries_both_dimensions():
    """Sticky and monitor for the same app merge into a single rule."""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "user-rules.json"
        proc = run_script(
            path, "write",
            "--managed-sticky", "--sticky", SPOTIFY,
            "--managed-monitors", "--monitors", f"{SPOTIFY}=2",
            "--monitor-layout", LAYOUT,
        )
        assert proc.returncode == 0, proc.stderr
        rules = read_rules(path)
        assert len(rules) == 1
        assert rules[0]["sticky"] is True
        assert rules[0]["monitor"] == 2
        assert rules[0]["monitorConnector"] == "HDMI-0"


def test_list_monitors_round_trips_the_written_assignments():
    """--list-monitors reports what write stored, for the menu's restore."""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "user-rules.json"
        run_script(
            path, "write", "--managed-monitors",
            "--monitors", f"{SPOTIFY}=1;{DISCORD}=2",
            "--monitor-layout", LAYOUT,
        )
        proc = run_script(path, "list-monitors")
        assert proc.returncode == 0, proc.stderr
        pairs = dict(
            line.split("\t") for line in proc.stdout.splitlines() if line.strip()
        )
        assert pairs[SPOTIFY] == "1"
        assert pairs[DISCORD] == "2"


def test_legacy_file_does_not_override_monitor_defaults():
    """Pre-monitor files must let the master retain monitor-1 defaults."""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "user-rules.json"
        path.write_text(json.dumps({"rules": [
            {"appIds": SPOTIFY.split("|"), "sticky": True},
            {"appIds": DISCORD.split("|"), "sticky": True},
        ]}), encoding="utf-8")

        proc = run_script(
            path,
            "list-monitors",
            "--legacy-defaults",
            f"{SPOTIFY}=1;{DISCORD}=1",
        )

        assert proc.returncode == 0, proc.stderr
        pairs = dict(line.split("\t") for line in proc.stdout.splitlines())
        assert pairs[SPOTIFY] == "1"
        assert pairs[DISCORD] == "1"


def test_sticky_only_write_preserves_managed_monitor_marker():
    """A later sticky edit must not make explicit monitor clearing look legacy."""
    with tempfile.TemporaryDirectory() as td:
        path = Path(td) / "user-rules.json"
        cleared = run_script(path, "write", "--managed-monitors", "--monitors", "")
        assert cleared.returncode == 0, cleared.stderr

        sticky = run_script(path, "write", "--managed-sticky", "--sticky", SPOTIFY)

        assert sticky.returncode == 0, sticky.stderr
        document = read_document(path)
        assert document["managed"] == {"monitors": True, "sticky": True}
        listed = run_script(path, "list-monitors")
        assert listed.returncode == 0, listed.stderr


def test_missing_file_lists_nothing_without_failing():
    """Listing before any run must stay quiet rather than error out."""
    with tempfile.TemporaryDirectory() as td:
        proc = run_script(Path(td) / "user-rules.json", "list-sticky")
        assert proc.returncode == 0, proc.stderr
        assert proc.stdout.strip() == ""
