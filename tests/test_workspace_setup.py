#!/usr/bin/env python3
"""Tests for the Linux Workspaces Setup installer helpers."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path


ROOT_DIR = Path(__file__).resolve().parent.parent
HELPERS = ROOT_DIR.parent / "linux_installation_scripts_functions" / "installer_helpers.sh"


def run_bash(script: str, env=None) -> subprocess.CompletedProcess[str]:
    # The shared install-time helpers (run_as_target, need_cmd, …) now live in the
    # framework and are loaded by install.sh before lib/workspace_setup.sh, so the
    # harness sources them first; workspace_setup.sh then overrides its own msg().
    full = f'source {str(HELPERS)!r}\n{script}'
    return subprocess.run(
        ["bash", "-c", full],
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
source lib/lifecycle.sh
declare -F configure_workspace_send_extension_bindings configure_automatic_window_tiling >/dev/null
declare -F configure_app_rules_extension configure_auto_move_windows migrate_legacy_ctrl_back_tiler >/dev/null
""".format(script_dir=str(ROOT_DIR), config_dir=str(ROOT_DIR / "configs"))
    )
    assert proc.returncode == 0, proc.stderr


def test_hotkey_components_are_owned_by_hotkey_repo():
    """Screenshot and numbered workspace bindings must not be installed here."""
    setup = (ROOT_DIR / "lib" / "workspace_setup.sh").read_text(encoding="utf-8")
    lifecycle = (ROOT_DIR / "lib" / "lifecycle.sh").read_text(encoding="utf-8")
    manifest = (ROOT_DIR / "installer" / "components.sh").read_text(encoding="utf-8")

    assert "configure_screenshot_binding()" not in setup
    assert "configure_workspace_keys()" not in setup
    assert "detect_screenshot()" not in lifecycle
    assert "detect_workspace_keys()" not in lifecycle
    assert '"screenshot|' not in manifest
    assert '"workspace_keys|' not in manifest


def test_custom_workspace_bindings_configure_extension_send_mode():
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
            }
        )

        proc = run_bash(
            """
set -euo pipefail
source lib/workspace_setup.sh
configure_workspace_send_extension_bindings >/dev/null 2>&1
""".format(script_dir=str(ROOT_DIR), config_dir=str(ROOT_DIR / "configs"))
        , env=env)
        assert proc.returncode == 0, proc.stderr

        log_text = log_path.read_text(encoding="utf-8")
        lines = [line.strip() for line in log_text.splitlines() if line.strip()]

        assert any("send-mode-workspace-bindings ['1:<Super>Z', '2:<Super>X']" in line for line in lines)


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


def test_workspace_extension_imports_typed_hotkey_fields(tmp_path):
    """Extension mappings follow the hotkey repo's switch fields and modifier."""
    config = tmp_path / "workspace-hotkeys.conf"
    config.write_text(
        "WORKSPACE_SWITCH_1=<Alt>q\nWORKSPACE_SWITCH_2=<Super>x\n"
        "WORKSPACE_MOVE_MODIFIER=Control\n",
        encoding="utf-8",
    )
    proc = run_bash(
        f"""
set -euo pipefail
TARGET_USER=$(id -un)
TARGET_HOME={str(tmp_path)!r}
WORKSPACE_COUNT=2
WORKSPACE_HOTKEY_CONFIG={str(config)!r}
source {str(ROOT_DIR.parent / 'linux_installation_scripts_functions' / 'hotkey_capture.sh')!r}
source lib/workspace_setup.sh
load_hotkey_workspace_binding_config
printf '%s\n' "$WORKSPACE_SWITCH_BINDINGS" "$WORKSPACE_MOVE_BINDINGS"
"""
    )
    assert proc.returncode == 0, proc.stderr
    assert proc.stdout.splitlines() == [
        "1:<Alt>q|2:<Super>x",
        "1:<Control><Alt>q|2:<Control><Super>x",
    ]


def test_friendly_accelerators_are_normalized_to_gsettings_form():
    proc = run_bash(
        """
set -euo pipefail
TARGET_USER=$(id -un)
TARGET_HOME=/tmp/linux-workspaces-test-home
source lib/workspace_setup.sh
normalize_accelerator 'super+z'
normalize_accelerator 'ctrl+alt+t'
normalize_accelerator 'super+shift+Left'
normalize_accelerator '<Super><Shift>R'
normalize_accelerator 'Print'
normalize_accelerator 'aring'
normalize_accelerator ''
"""
    )
    assert proc.returncode == 0, proc.stderr
    lines = proc.stdout.splitlines()
    assert lines[0] == "<Super>z"
    assert lines[1] == "<Control><Alt>t"
    assert lines[2] == "<Super><Shift>Left"
    assert lines[3] == "<Super><Shift>R"
    assert lines[4] == "Print"
    assert lines[5] == "aring"
    assert lines[6] == ""


def test_friendly_workspace_bindings_apply_to_extension_send_mode():
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
                "WORKSPACE_SWITCH_BINDINGS": "1:super+z|2:super+x",
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
        lines = log_path.read_text(encoding="utf-8").splitlines()
        assert any("send-mode-workspace-bindings ['1:<Super>z', '2:<Super>x']" in line for line in lines)


def test_albert_and_paste_block_components_exist():
    proc = run_bash(
        """
set -euo pipefail
TARGET_USER=$(id -un)
TARGET_HOME=/tmp/linux-workspaces-test-home
source lib/workspace_setup.sh
declare -F configure_albert_keybindings configure_primary_paste_block >/dev/null
"""
    )
    assert proc.returncode == 0, proc.stderr
    components = (ROOT_DIR / "installer" / "components.sh").read_text(encoding="utf-8")
    assert "albert|Albert launcher toggle binding|on|configure_albert_keybindings" in components
    assert "primary_paste_block|Block middle-click primary paste|on|configure_primary_paste_block" in components


def test_albert_binding_uses_configured_accelerator():
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
            "case \" $* \" in *' get '*) printf '%s\\n' '[]';; esac\n"
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
                "ALBERT_TOGGLE_BINDING": "super+space",
            }
        )

        proc = run_bash(
            """
set -euo pipefail
source lib/workspace_setup.sh
configure_albert_keybindings >/dev/null 2>&1
""",
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        log_text = log_path.read_text(encoding="utf-8")
        assert "binding '<Super>space'" in log_text
        assert "command 'albert toggle'" in log_text


def test_workspace_assets_and_delegation_are_present():
    assert not (ROOT_DIR / "src/tiler.rs").exists()
    assert (ROOT_DIR / "src/main.rs").is_file()
    assert not (ROOT_DIR / "configs/window-hotkeys/ctrl_back_tile_right.py").exists()
    assert not (ROOT_DIR / "configs/window-hotkeys/ctrl_back_event_state.py").exists()
    assert not (ROOT_DIR / "configs/window-hotkeys/input_device_paths.py").exists()
    setup = (ROOT_DIR / "lib/workspace_setup.sh").read_text(encoding="utf-8")
    assert "AUTOMATIC_WINDOW_TILING_BINDING:-<Super>t" in setup
    assert 'bash "$installer" "$AUTOMATIC_WINDOW_TILING_BINDING"' in setup


def test_duplicate_pointer_tiler_is_not_a_workspace_component():
    manifest = (ROOT_DIR / "installer/components.sh").read_text(encoding="utf-8")
    setup = (ROOT_DIR / "lib/workspace_setup.sh").read_text(encoding="utf-8")
    defaults = (ROOT_DIR / "installation_configs/default.json").read_text(encoding="utf-8")
    assert "ctrl_back_tiler|" not in manifest
    assert '"ctrl_back_tiler"' not in defaults
    assert "configure_ctrl_back_window_tiler_service" not in setup
    assert 'ISC_PREFLIGHT="migrate_legacy_ctrl_back_tiler"' in manifest


def test_monitor_window_extension_extracted_but_send_mode_config_stays():
    """The monitor-window-hotkeys@local extension moved to its own repository;
    this repo keeps only the send-mode key-map configuration."""
    assert not (
        ROOT_DIR / "configs/gnome-shell/extensions/monitor-window-hotkeys@local"
    ).exists()
    setup = (ROOT_DIR / "lib/workspace_setup.sh").read_text(encoding="utf-8")
    manifest = (ROOT_DIR / "installer/components.sh").read_text(encoding="utf-8")
    assert "configure_monitor_window_hotkeys_extension" not in setup
    assert "configure_workspace_send_extension_bindings" in setup
    assert "workspace_send_mode|" in manifest


def test_gsettings_list_mutation_uses_extracted_helper():
    setup = (ROOT_DIR / "lib/workspace_setup.sh").read_text(encoding="utf-8")
    assert "wss_bin" in setup
    assert "gsettings_strv.py" not in setup


def test_workspace_setup_logging_is_centralized_and_best_effort():
    with tempfile.TemporaryDirectory() as td:
        env = os.environ.copy()
        env.update(
            {
                "TARGET_USER": os.environ["USER"],
                "TARGET_HOME": str(Path(td) / "home"),
                "WORKSPACE_SETUP_LOG_DIR": str(Path(td) / ".log"),
            }
        )

        proc = run_bash(
            """
set -euo pipefail
source lib/workspace_setup.sh
msg "installer started"
log_debug "debug detail"
log_warn "recoverable warning"
""",
            env=env,
        )
        assert proc.returncode == 0, proc.stderr
        log_text = (Path(td) / ".log" / "install.log").read_text(encoding="utf-8")
        assert "INFO installer started" in log_text
        assert "DEBUG debug detail" in log_text
        assert "WARN recoverable warning" in log_text


def _sticky_env(td: str) -> dict[str, str]:
    env = os.environ.copy()
    env["WORKSPACE_SETUP_LOG_DIR"] = str(Path(td) / ".log")
    return env


def test_sticky_rules_written_from_master_selection():
    """MANAGED_STICKY_APPS set -> the [p] selection is serialized as JSON rules."""
    with tempfile.TemporaryDirectory() as td:
        rules_file = Path(td) / "user-rules.json"
        proc = run_bash(
            f"""
set -euo pipefail
SCRIPT_DIR={str(ROOT_DIR)!r}
CONFIG_DIR={str(ROOT_DIR / "configs")!r}
TARGET_USER=$(id -un)
TARGET_HOME={td!r}
export APP_RULES_USER_RULES_FILE={str(rules_file)!r}
export MANAGED_STICKY_APPS='spotify.desktop|spotify_spotify.desktop;vlc.desktop'
export SELECTED_STICKY_APPS='spotify.desktop|spotify_spotify.desktop'
source lib/workspace_setup.sh
write_app_rules_sticky_rules >/dev/null
""",
            env=_sticky_env(td),
        )
        assert proc.returncode == 0, proc.stderr
        import json

        payload = json.loads(rules_file.read_text(encoding="utf-8"))
        assert payload["rules"] == [
            {"appIds": ["spotify.desktop", "spotify_spotify.desktop"], "sticky": True}
        ]


def test_sticky_rules_empty_selection_writes_empty_authority_file():
    """Unmarking every [p] app writes an empty rules list (suppresses fallback)."""
    with tempfile.TemporaryDirectory() as td:
        rules_file = Path(td) / "user-rules.json"
        proc = run_bash(
            f"""
set -euo pipefail
SCRIPT_DIR={str(ROOT_DIR)!r}
CONFIG_DIR={str(ROOT_DIR / "configs")!r}
TARGET_USER=$(id -un)
TARGET_HOME={td!r}
export APP_RULES_USER_RULES_FILE={str(rules_file)!r}
export MANAGED_STICKY_APPS='spotify.desktop|spotify_spotify.desktop'
export SELECTED_STICKY_APPS=''
source lib/workspace_setup.sh
write_app_rules_sticky_rules >/dev/null
""",
            env=_sticky_env(td),
        )
        assert proc.returncode == 0, proc.stderr
        import json

        assert json.loads(rules_file.read_text(encoding="utf-8"))["rules"] == []


def test_sticky_rules_untouched_without_master_env():
    """A standalone run (MANAGED_STICKY_APPS unset) must keep the existing file."""
    with tempfile.TemporaryDirectory() as td:
        rules_file = Path(td) / "user-rules.json"
        rules_file.write_text('{"rules": [{"appIds": ["x.desktop"], "sticky": true}]}')
        proc = run_bash(
            f"""
set -euo pipefail
SCRIPT_DIR={str(ROOT_DIR)!r}
CONFIG_DIR={str(ROOT_DIR / "configs")!r}
TARGET_USER=$(id -un)
TARGET_HOME={td!r}
export APP_RULES_USER_RULES_FILE={str(rules_file)!r}
unset MANAGED_STICKY_APPS SELECTED_STICKY_APPS
source lib/workspace_setup.sh
write_app_rules_sticky_rules >/dev/null
""",
            env=_sticky_env(td),
        )
        assert proc.returncode == 0, proc.stderr
        assert '"x.desktop"' in rules_file.read_text(encoding="utf-8")


def test_list_selected_sticky_apps_reads_rules_file():
    """--list-selected-sticky-apps reports the appIds in the user-rules file."""
    with tempfile.TemporaryDirectory() as td:
        root = str(ROOT_DIR)
        home = Path(td)
        rules_dir = home / ".config" / "app-rules"
        rules_dir.mkdir(parents=True)
        (rules_dir / "user-rules.json").write_text(
            '{"rules": [{"appIds": ["spotify.desktop", "spotify_spotify.desktop"], "sticky": true}]}'
        )
        proc = run_bash(
            f"""
set -euo pipefail
SCRIPT_DIR={root!r}
TARGET_HOME={td!r}
eval "$(sed -n '/^list_selected_sticky_apps()/,/^}}/p' install.sh)"
list_selected_sticky_apps
""",
        )
        assert proc.returncode == 0, proc.stderr
        lines = proc.stdout.split()
        assert "spotify.desktop" in lines
        assert "spotify_spotify.desktop" in lines


def test_list_selected_sticky_apps_falls_back_to_legacy_when_unwritten():
    """Without a rules file, a deployed extension reports the built-in fallback."""
    with tempfile.TemporaryDirectory() as td:
        root = str(ROOT_DIR)
        ext_dir = Path(td) / ".local/share/gnome-shell/extensions/app-rules@local"
        ext_dir.mkdir(parents=True)
        proc = run_bash(
            f"""
set -euo pipefail
SCRIPT_DIR={root!r}
TARGET_HOME={td!r}
eval "$(sed -n '/^list_selected_sticky_apps()/,/^}}/p' install.sh)"
list_selected_sticky_apps
""",
        )
        assert proc.returncode == 0, proc.stderr
        assert "spotify_spotify.desktop" in proc.stdout.split()
        assert "discord_discord.desktop" in proc.stdout.split()


def test_app_rules_extension_loads_user_rules_dynamically():
    """The extension must read user-rules.json and keep a legacy sticky fallback."""
    source = (ROOT_DIR / "configs/gnome-extensions/app-rules@local/extension.js").read_text(
        encoding="utf-8"
    )
    assert "user-rules.json" in source
    assert "STICKY_FALLBACK_RULES" in source
    assert "...userRules, ...RULES, ...STICKY_FALLBACK_RULES" in source
    # The always-on builtin list must no longer hardcode sticky apps.
    rules_block = source.split("const RULES = [", 1)[1].split("];", 1)[0]
    assert "sticky" not in rules_block


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
