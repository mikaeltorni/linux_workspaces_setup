# Linux Workspaces Setup

> Part of [installation_scripts](https://github.com/mikaeltorni/installation_scripts) — the master installer that orchestrates a productivity-focused Ubuntu 24.04 desktop setup (workspaces, hotkeys, window tiling, programming tools, and more). Tested on Ubuntu 24.04.4 LTS (GNOME 46); other GNOME/Ubuntu versions untested.

Ubuntu GNOME workspace behavior and workspace-related extensions are owned by
this repository. Screenshot shortcuts and numbered workspace switch/move
accelerators are configured individually by `linux_hotkey_setup`.

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

- From `linux_hotkey_setup`: Albert bindings, monitor/window hotkeys extension, numbered workspace popup, Ctrl+Back window tiler service, and xmousepasteblock clipboard-lock wiring.
- Kept in `linux_hotkey_setup`: screenshot and numbered workspace switch/move shortcuts.
- From `linux_configuration_setup`: app-rules GNOME Shell extension that assigns apps to workspaces or sticky windows. Sticky (all-workspaces) rules are dynamic: the master installer's `[p]` menu action writes them to `~/.config/app-rules/user-rules.json` (queried back with `install.sh --list-selected-sticky-apps`); until that file exists the extension falls back to its built-in Spotify/Discord sticky rules.
- From `ubuntu_2404_taskbar_system_status_monitor`: Window Rules/Workspace rules behavior and Auto-move-windows workspace placement configuration. The Ubuntu taskbar repository keeps the resource monitor/taskbar UI pieces only.
- Kept separate but invoked by this repo: automatic same-application window tiling in `linux_automatic_window_tiling`.

## Default hotkeys

The extension uses the same default workspace map as `linux_hotkey_setup` to
provide `<Control><Super><Shift>` variants that move the focused window without
switching workspaces. The primary switch/move bindings themselves are installed
by `linux_hotkey_setup`.

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

## Configure extension workspace mappings

By default, extension workspace mappings import the typed fields from
`$HOME/.config/linux-hotkey-setup/workspace-hotkeys.conf`, including the shared
move modifier. To override only the extension mappings, create the legacy
workspace-specific file before running the installer:

```bash
mkdir -p "$HOME/.config/linux-workspaces-setup"
cp ~/projects/linux_workspaces_setup/configs/workspace-bindings.conf.example \
  "$HOME/.config/linux-workspaces-setup/workspace-bindings.conf"
# Keep the WORKSPACE_*_BINDINGS lines aligned with linux_hotkey_setup.
sudo bash ~/projects/linux_workspaces_setup/install.sh
```

The config format is `INDEX:ACCELERATOR` entries separated by `|`. Accelerators
accept either the friendly `super+z` form you can just type, or GNOME's native
`<Super>z` form — both are equivalent. Modifier names are case-insensitive:
`super`/`win`, `ctrl`/`control`, `alt`, `shift`, `meta`, `hyper`. Bare keysyms
like `Print`, `Tab`, or `aring` (the Å key) need no modifier:

```bash
WORKSPACE_SWITCH_BINDINGS='1:super+z|2:super+x'
WORKSPACE_MOVE_BINDINGS='1:super+shift+z|2:super+shift+x'
# Albert launcher toggle (default is the Å key):
ALBERT_TOGGLE_BINDING='super+space'
```

The extension derives its no-switch `<Control>` variants and Super+U send-mode
target keys from these maps. Configure the primary switch/move accelerators
through `linux_hotkey_setup`. GNOME Shell extensions require a logout/login to
load newly copied shell-extension files. The installer enables extensions
without replacing `gnome-shell` and preserves your existing enabled-extension
list.

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
| `monitor_window_hotkeys` | Monitor/window movement hotkeys extension | on |
| `automatic_window_tiling` | Automatic same-app window tiling | on |
| `ctrl_back_tiler` | Ctrl+Back window tiler service | on |
| `workspace_popup` | Numbered workspace popup extension | on |
| `albert` | Albert launcher toggle binding | on |
| `app_rules` | App-to-workspace window rules extension | on |
| `auto_move_windows` | Auto-move-windows workspace placement | on |
| `primary_paste_block` | Block middle-click primary paste (xmousepasteblock) | on |


## Detect, reconfigure, and uninstall

This installer tracks what it has installed and can re-apply or remove it, so you
can refresh configuration after a repo update or cleanly back a feature out.

```bash
bash install.sh --detect            # show each component as installed|absent
bash install.sh --reconfigure a,b   # re-apply (idempotent) these component ids
bash install.sh --uninstall a,b     # uninstall these component ids
```

In the interactive menu (run `bash install.sh` on a terminal, or via the master
installer), already-installed components show a green `✓`. Select one with
**space** to **reconfigure** it (`~`), press **`u`** to mark it for **uninstall**
(`✗`), or press **`r`** to reconfigure every installed component at once. Detection
uses a live check where deterministic and otherwise an install receipt under
`${XDG_STATE_HOME:-~/.local/state}/isc/receipts/`; a component without a reversal
step simply clears that receipt on uninstall.

## Disclaimer

This software is provided under the MIT License on an **“as is”** basis, without warranties of any kind. To the maximum extent permitted by applicable law, the authors and copyright holders shall not be liable for any claims, damages, losses, or other liability arising from the use of this software.

You are solely responsible for determining whether this software is suitable, safe, lawful, and appropriate for your intended use. Unless explicitly stated otherwise, this project is general-purpose software and is not designed, tested, certified, or approved for safety-critical, medical, automotive, aviation, industrial-control, life-support, cybersecurity-critical, financial-critical, or other high-risk use cases.

The authors and copyright holders make no guarantees regarding security, reliability, availability, correctness, compliance, non-infringement, or fitness for any particular purpose.

This notice is intended to clarify the nature of the project and does not impose additional restrictions beyond the MIT License.
