#!/usr/bin/env python3
"""Tests for the Linux Workspaces Setup installer helpers."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent


def run_bash(script: str, env=None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-c", script],
        cwd=ROOT_DIR,
        text=True,
        capture_output=True,
        check=False,
        env=env or os.environ.copy(),
    )


def test_exports_expected_workspace_functions():
    proc = run_bash(
        """
set -euo pipefail
SCRIPT_DIR={script_dir!r}
CONFIG_DIR={config_dir!r}
TARGET_USER=$(id -un)
TARGET_HOME=/tmp/linux-workspaces-test-home
source lib/workspace_setup.sh
declare -F configure_workspace_keys configure_monitor_window_hotkeys_extension configure_automatic_window_tiling >/dev/null
declare -F configure_ctrl_back_window_tiler_service configure_app_rules_extension configure_auto_move_windows >/dev/null
""".format(script_dir=str(ROOT_DIR), config_dir=str(ROOT_DIR / "configs"))
    )
    assert proc.returncode == 0, proc.stderr


def test_custom_workspace_bindings_clear_unused_entries():
    with tempfile.TemporaryDirectory() as td:
        home = Path(td) / "home"
        bin_dir = Path(td) / "bin"
        log_path = Path(td) / "gsettings.log"
        home.mkdir()
        bin_dir.mkdir()

        fake_script = r'''#!/usr/bin/env bash
printf '%s\n' "$*" >> {log_path!r}
case " $* " in
    *" get org.gnome.desktop.wm.keybindings maximize "*) printf "%s\n" "['<Super>Up', '<Alt>F10']";;
    *" get org.gnome.desktop.wm.keybindings minimize "*) printf "%s\n" "['<Alt><Super>R', '<Super>Down']";;
    *" get org.gnome.shell.extensions.tiling-assistant tile-maximize "*) printf "%s\n" "['<Super>Up', '<Control><Super>X']";;
esac
exit 0
'''
        fake_gsettings = bin_dir / "gsettings"
        fake_gsettings.write_text(fake_script.format(log_path=str(log_path)))
        fake_gsettings.chmod(0o755)

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                "TARGET_USER": os.environ["USER"],
                "TARGET_HOME": str(home),
                "CONFIG_DIR": str(ROOT_DIR / "configs"),
                "SESSION_TYPE": "x11",
                "WORKSPACE_SWITCH_BINDINGS": "1:<Super>Z|2:<Super>X",
                "WORKSPACE_MOVE_BINDINGS": "1:<Super><Shift>z|2:<Super><Shift>x",
                "SUPER_ARROW_MOVE_BINDINGS": "move-to-workspace-left:<Super><Shift>Left",
                "OVERVIEW_BINDINGS": "<Super>F9",
                "SCREENSHOT_UI_BINDINGS": "<Shift><Super>s",
                "TILING_ASSISTANT_SCHEMA": "org.gnome.shell.extensions.tiling-assistant",
            }
        )

        proc = run_bash(
            """
set -euo pipefail
source lib/workspace_setup.sh
configure_screenshot_binding >/dev/null 2>&1
configure_workspace_keys >/dev/null 2>&1
""".format(script_dir=str(ROOT_DIR), config_dir=str(ROOT_DIR / "configs"))
        , env=env)
        assert proc.returncode == 0, proc.stderr

        log_text = log_path.read_text(encoding="utf-8")
        lines = [line.strip() for line in log_text.splitlines() if line.strip()]

        assert any("switch-to-workspace-1 ['<Super>Z']" in line for line in lines)
        assert any("switch-to-workspace-2 ['<Super>X']" in line for line in lines)
        assert any("move-to-workspace-1 ['<Super><Shift>z']" in line for line in lines)
        assert any("move-to-workspace-2 ['<Super><Shift>x']" in line for line in lines)
        assert any("switch-to-workspace-8 []" in line for line in lines)
        assert any("toggle-overview ['<Super>F9']" in line for line in lines)
        assert any("show-screen-recording-ui []" in line for line in lines)
        assert any("minimize []" in line and "org.gnome.desktop.wm.keybindings" in line for line in lines)
        assert any("maximize []" in line and "org.gnome.desktop.wm.keybindings" in line for line in lines)

        tile_max_lines = [line for line in lines if line.startswith("set org.gnome.shell.extensions.tiling-assistant tile-maximize")]
        assert tile_max_lines
        assert "<Super>Up" not in tile_max_lines[0]


def test_workspace_send_extension_bindings_are_derived_from_workspace_config():
    with tempfile.TemporaryDirectory() as td:
        home = Path(td) / "home"
        bin_dir = Path(td) / "bin"
        log_path = Path(td) / "gsettings.log"
        home.mkdir()
        bin_dir.mkdir()

        fake_gsettings = bin_dir / "gsettings"
        fake_gsettings.write_text(
            "#!/usr/bin/env bash\n"
            f"printf '%s\\n' \"$*\" >> {str(log_path)!r}\n"
            "exit 0\n",
            encoding="utf-8",
        )
        fake_gsettings.chmod(0o755)

        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{bin_dir}:{env.get('PATH', '')}",
                "TARGET_USER": os.environ["USER"],
                "TARGET_HOME": str(home),
                "CONFIG_DIR": str(ROOT_DIR / "configs"),
                "WORKSPACE_SWITCH_BINDINGS": "1:<Super>Z|2:<Super>X",
                "WORKSPACE_MOVE_BINDINGS": "1:<Super><Shift>Z|2:<Super><Shift>X",
            }
        )

        proc = run_bash(
            """
set -euo pipefail
source lib/workspace_setup.sh
configure_workspace_send_extension_bindings >/dev/null 2>&1
""",
            env=env,
        )
        assert proc.returncode == 0, proc.stderr

        log_text = log_path.read_text(encoding="utf-8")
        assert "send-mode-workspace-bindings ['1:<Super>Z', '2:<Super>X']" in log_text
        assert "send-active-window-to-workspace-1 ['<Control><Super><Shift>Z']" in log_text
        assert "send-active-window-to-workspace-2 ['<Control><Super><Shift>X']" in log_text


def test_workspace_assets_and_delegation_are_present():
    assert (ROOT_DIR / "configs/gnome-shell/extensions/monitor-window-hotkeys@local/extension.js").is_file()
    assert (ROOT_DIR / "configs/gnome-shell/extensions/monitor-window-hotkeys@local/gsettings-strv.py").is_file()
    assert (ROOT_DIR / "configs/window-hotkeys/ctrl_back_tile_right.py").is_file()
    assert (ROOT_DIR / "configs/window-hotkeys/ctrl_back_event_state.py").is_file()
    assert (ROOT_DIR / "configs/window-hotkeys/input_device_paths.py").is_file()
    setup = (ROOT_DIR / "lib/workspace_setup.sh").read_text(encoding="utf-8")
    assert "AUTOMATIC_WINDOW_TILING_BINDING:-<Super>t" in setup
    assert 'bash "$installer" "$AUTOMATIC_WINDOW_TILING_BINDING"' in setup
    extension = (
        ROOT_DIR / "configs/gnome-shell/extensions/monitor-window-hotkeys@local/extension.js"
    ).read_text(encoding="utf-8")
    assert "send-window-to-workspace-mode" in extension
    assert "send-active-window-to-workspace-8" in extension


def test_gsettings_list_mutation_uses_extracted_helper():
    setup = (ROOT_DIR / "lib/workspace_setup.sh").read_text(encoding="utf-8")
    apply_bindings = (
        ROOT_DIR
        / "configs"
        / "gnome-shell"
        / "extensions"
        / "monitor-window-hotkeys@local"
        / "apply-system-bindings.sh"
    ).read_text(encoding="utf-8")

    assert "gsettings_strv.py" in setup
    assert "python3 - <<'PY'" not in setup
    assert "gsettings-strv.py" in apply_bindings
    assert "python3 - <<'PY'" not in apply_bindings


if __name__ == "__main__":
    tests = [t for name, t in sorted(globals().items()) if name.startswith("test_") and callable(t)]
    failed = 0
    for test_fn in tests:
        try:
            test_fn()
            print(f"PASS: {test_fn.__name__}")
        except Exception as exc:
            failed += 1
            print(f"FAIL: {test_fn.__name__} — {exc}")
    raise SystemExit(failed)
