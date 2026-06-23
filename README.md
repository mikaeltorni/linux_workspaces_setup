# Linux Workspaces Setup

> Part of [installation_scripts](https://github.com/mikaeltorni/installation_scripts) — the master installer that orchestrates a productivity-focused Ubuntu 24.04 desktop setup (workspaces, hotkeys, window tiling, programming tools, and more). Tested on Ubuntu 24.04.4 LTS (GNOME 46); other GNOME/Ubuntu versions untested.

Ubuntu GNOME workspace behavior, numbered-workspace hotkeys, and monitor/window tiling shortcuts are owned by this repository. The old `linux_hotkey_setup` repository no longer owns these items; run this installer from the master setup chain or directly after cloning its sibling repos.

## Repository dependencies

This repository installs and runs **standalone**; sibling repositories only
enhance it and never block installation when absent.

- **Build-time (soft):** the shared installer component framework
  [`linux_installation_scripts_functions`](https://github.com/mikaeltorni/linux_installation_scripts_functions) —
  loaded from a sibling checkout when present, otherwise downloaded on demand.
- **Delegated install (optional):** when it sits beside it, this installer also
  installs
  [`linux_automatic_window_tiling`](https://github.com/mikaeltorni/linux_automatic_window_tiling)
  (with the chosen accelerator). If that checkout is missing, the tiling action
  is skipped — the rest of the workspace setup still installs.

See the full cross-repository map in
[installation_scripts/DEPENDENCIES.md](https://github.com/mikaeltorni/installation_scripts/blob/master/DEPENDENCIES.md).

## Ownership map

- From `linux_hotkey_setup`: workspace switch/move keybindings, screenshot/Albert bindings, monitor/window hotkeys extension, numbered workspace popup, Ctrl+Back window tiler service, and xmousepasteblock clipboard-lock wiring.
- From `linux_configuration_setup`: app-rules GNOME Shell extension that assigns apps to workspaces or sticky windows.
- From `ubuntu_2404_taskbar_system_status_monitor`: Window Rules/Workspace rules behavior and Auto-move-windows workspace placement configuration. The Ubuntu taskbar repository keeps the resource monitor/taskbar UI pieces only.
- Kept separate but invoked by this repo: automatic same-application window tiling in `linux_automatic_window_tiling`.

## Default hotkeys

The installer configures 8 workspaces by default. Workspace switch keys are cleared first, then filled from the configured map; unset workspace entries become empty bindings unless `WORKSPACE_CLEAR_UNUSED_BINDINGS=0` is set. GNOME's built-in `<Super><Shift>` move binding may follow the moved window; the extension also installs `<Control><Super><Shift>` variants that move the focused window without switching workspaces.

| Work | Switch | Move to | Send without switching |
|---|---|---|---|
| 1 | `<Super>Z` | `<Super><Shift>Z` | `<Control><Super><Shift>Z` |
| 2 | `<Super>X` | `<Super><Shift>X` | `<Control><Super><Shift>X` |
| 3 | `<Super>C` | `<Super><Shift>C` | `<Control><Super><Shift>C` |
| 4 | `<Super>A` | `<Super><Shift>A` | `<Control><Super><Shift>A` |
| 5 | `<Super>Q` | `<Super><Shift>Q` | `<Control><Super><Shift>Q` |
| 6 | `<Super>W` | `<Super><Shift>W` | `<Control><Super><Shift>W` |
| 7 | `<Super>E` | `<Super><Shift>E` | `<Control><Super><Shift>E` |
| 8 | `<Super>R` | `<Super><Shift>R` | `<Control><Super><Shift>R` |

The monitor/window hotkeys extension also provides a right-click send mode: hold `<Super>U`, press and hold one of the configured workspace switch keys, then right-click a window. For example, holding `<Super>U` then `Z` and right-clicking a window sends that window to workspace 1 without switching there. Releasing `U` or Super exits the mode.

These defaults intentionally avoid Ubuntu/GNOME Tiling Assistant half-screen tiling shortcuts such as Super+Up/Down and Ctrl+Super+W/X/C. Known GNOME/Tiling Assistant conflicts are cleared during setup, including duplicate half-tile bindings that can steal Super+Up/Down or left/right tiling.

## Configure your own hotkeys

Edit `$HOME/.config/linux-workspaces-setup/workspace-bindings.conf` before running the installer:

```bash
mkdir -p "$HOME/.config/linux-workspaces-setup"
cp ~/projects/linux_workspaces_setup/configs/workspace-bindings.conf.example \
  "$HOME/.config/linux-workspaces-setup/workspace-bindings.conf"
# Edit only the WORKSPACE_*_BINDINGS lines.
sudo bash ~/projects/linux_workspaces_setup/install.sh
```

The config format is `INDEX:ACCELERATOR` entries separated by `|`:

```bash
WORKSPACE_SWITCH_BINDINGS='1:<Super>Z|2:<Super>X'
WORKSPACE_MOVE_BINDINGS='1:<Super><Shift>z|2:<Super><Shift>x'
SUPER_ARROW_MOVE_BINDINGS='move-to-workspace-left:<Super><Shift>Left'
OVERVIEW_BINDINGS='<Super>F9'
```

If you omit an index up to `WORKSPACE_COUNT`, that workspace's switch/move keys remain empty. The extension derives its no-switch `<Control>` variants and Super+U send-mode target keys from the same configured switch/move maps. If a selected accelerator is still used by Ubuntu/GNOME/Tiling Assistant, run the explicit cleanup command as the target user:

```bash
env DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" DISPLAY="${DISPLAY:-:0}" \
  gsettings set org.gnome.desktop.wm.keybindings switch-to-workspace-1 ''
gsettings --schemadir "$HOME/.local/share/gnome-shell/extensions/monitor-window-hotkeys@local/schemas" \
  reset-recursively org.gnome.shell.extensions.monitor-window-hotkeys
```

For third-party extension bindings, remove duplicates from that extension's own schema after the installer reports or logs a conflict. GNOME Shell extensions require a logout/login to load newly copied shell-extension files. The installer enables extensions without replacing `gnome-shell` and preserves your existing enabled-extension list.

## Run tests

```bash
python3 -m py_compile configs/window-hotkeys/ctrl_back_tile_right.py \
  configs/window-hotkeys/ctrl_back_event_state.py \
  configs/window-hotkeys/input_device_paths.py \
  configs/window-hotkeys/tile_right_client.py
bash -n install.sh lib/workspace_setup.sh configs/gnome-shell/extensions/monitor-window-hotkeys@local/apply-system-bindings.sh
python3 -m pytest tests
```

The Ctrl+Back service implementation is split across:

- `ctrl_back_tile_right.py`, which owns evdev resources and GNOME integration;
- `ctrl_back_event_state.py`, which owns Ctrl/Back state transitions and
  forwarding/suppression decisions;
- `tile_right_client.py`, which owns the D-Bus call into the GNOME Shell
  extension's right-half tiling API; and
- `input_device_paths.py`, which owns deterministic input-device ordering.

## Deployment notes

Run `sudo bash install.sh` once from the master chain after all sibling repos have been cloned. For standalone runs, keep `../linux_automatic_window_tiling` nearby because this repo delegates automatic tiling activation to that installer with `<Super>t`. If you only need GNOME GSettings changes on an existing desktop session, run as the target user; root is needed for optional apt/package steps and Wayland shell-extension installation.

## Component selection

This repository's `install.sh` participates in the shared installer
component menu (see the [`installation_scripts`](https://github.com/mikaeltorni/installation_scripts)
master installer). Run standalone, it offers an interactive submenu on a
terminal; the master installer drives it non-interactively.

```bash
bash install.sh                 # interactive component selection (TTY), else defaults
bash install.sh --default       # install all default-on components, no prompts
bash install.sh --all           # install every component, no prompts
bash install.sh --select a,b    # install exactly these component ids
bash install.sh --list-components  # print: id<TAB>label<TAB>default
```

In the interactive menu, **space** toggles a component, `a`/`n` select all
or none, and **Enter** installs the selection. Components:

| Component id | Description | Default |
|---|---|---|
| `screenshot` | Screenshot shortcuts | on |
| `workspace_keys` | Numbered workspace switch/move keys | on |
| `monitor_window_hotkeys` | Monitor/window movement hotkeys extension | on |
| `automatic_window_tiling` | Automatic same-app window tiling | on |
| `ctrl_back_tiler` | Ctrl+Back window tiler service | on |
| `workspace_popup` | Numbered workspace popup extension | on |
| `app_rules` | App-to-workspace window rules extension | on |
| `auto_move_windows` | Auto-move-windows workspace placement | on |


## Disclaimer

This software is provided under the MIT License on an **“as is”** basis, without warranties of any kind. To the maximum extent permitted by applicable law, the authors and copyright holders shall not be liable for any claims, damages, losses, or other liability arising from the use of this software.

You are solely responsible for determining whether this software is suitable, safe, lawful, and appropriate for your intended use. Unless explicitly stated otherwise, this project is general-purpose software and is not designed, tested, certified, or approved for safety-critical, medical, automotive, aviation, industrial-control, life-support, cybersecurity-critical, financial-critical, or other high-risk use cases.

The authors and copyright holders make no guarantees regarding security, reliability, availability, correctness, compliance, non-infringement, or fitness for any particular purpose.

This notice is intended to clarify the nature of the project and does not impose additional restrictions beyond the MIT License.
