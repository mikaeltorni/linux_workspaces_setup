# Linux Workspaces Setup

> Part of [installation_scripts](https://github.com/mikaeltorni/installation_scripts) — the master installer that orchestrates a productivity-focused Ubuntu 24.04 desktop setup (workspaces, hotkeys, window tiling, programming tools, and more). Tested on Ubuntu 24.04.4 LTS (GNOME 46); other GNOME/Ubuntu versions untested.

Ubuntu GNOME workspace behavior and workspace-related extensions are owned by
this repository. Screenshot shortcuts and numbered workspace switch/move
accelerators are configured individually by `linux_hotkey_setup`.

## Repository dependencies

This repository installs and runs **standalone**; sibling repositories only
enhance it and never block installation when absent.

- **Installer support:** the maintained MIT library is included in
  `.installer-support/`, with its license and verifiable source manifest.
  Framework discovery works offline without a private checkout or credentials.
- **Delegated install (optional):** when it sits beside it, this installer also
  installs
  [`linux_automatic_window_tiling`](https://github.com/mikaeltorni/linux_automatic_window_tiling)
  (with the chosen accelerator). If that checkout is missing, the tiling action
  is skipped — the rest of the workspace setup still installs.

See the full cross-repository map in
[installation_scripts/DEPENDENCIES.md](https://github.com/mikaeltorni/installation_scripts/blob/master/DEPENDENCIES.md).

## Ownership map

- Owned solely by `linux_hotkey_setup`: screenshot and numbered workspace switch/move shortcuts plus the pointer-driven window-placement tiler. This repository never installs a second input grabber.
- Sole owner of the app-rules GNOME Shell extension that assigns apps to workspaces, sticky windows, or a fixed display monitor. The master installer's `[p]` menu action writes additional rules to `~/.config/app-rules/user-rules.json` (queried back with `install.sh --list-selected-sticky-apps`); Spotify and Discord remain installation-default sticky rules even when that file exists.
- The master installer's `[m]` menu action writes per-application monitor rules into the same file (queried back with `install.sh --list-selected-app-monitors`), so an application opens on the chosen display on every reboot. Both dimensions are merged by the native `app-rules-rules` helper (`src/app_rules.rs`): a run that manages only one of them preserves the other's rules instead of overwriting the file. The Python script `scripts/app_rules_rules.py` remains separately tested.
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
bash ~/projects/linux_workspaces_setup/install.sh
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

This repository configures the Super+U send-mode target keys and the no-switch
`<Control>` variants on the `monitor-window-hotkeys@local` extension (which is
installed by the standalone `linux_monitor_window_hotkeys` repository, not
bundled here) so they stay in sync with these maps. Configure the primary
switch/move accelerators through `linux_hotkey_setup`. GSettings changes apply
immediately. After changing extension code, activate it with `Alt+F2`, then `r`
on X11; on Wayland, log out and back in. The installer enables extensions
without replacing `gnome-shell` and preserves your existing enabled-extension
list.

## Run tests

```bash
bash -n install.sh lib/workspace_setup.sh lib/lifecycle.sh
cargo test
python3 -m pytest tests
```

The Ctrl+Back/window-placement service is installed only by
`linux_hotkey_setup`. On upgrade this installer removes its obsolete
`ctrl-back-window-tiler.service`, preventing two repositories from competing
for the same physical pointer.

## Deployment notes

Run `bash install.sh` as the desktop user for standalone setup. The master chain
invokes this repository after cloning its siblings. Keep
`../linux_automatic_window_tiling` nearby because this repo delegates automatic
tiling activation to that installer with `<Super>t`. User-level settings apply
in the running session; package steps are skipped in user mode.

## Component selection

This repository's `install.sh` participates in the shared installer
component menu (see the [`installation_scripts`](https://github.com/mikaeltorni/installation_scripts)
master installer). Run standalone, it offers an interactive submenu on a
terminal; the master installer drives it non-interactively.

```bash
bash install.sh                 # interactive component selection (TTY), else defaults
bash install.sh --config NAME   # load installation_configs/NAME (default.json when omitted)
bash install.sh --default       # install all default-on components, no prompts
bash install.sh --all           # install every component, no prompts
bash install.sh --select a,b    # install exactly these component ids
bash install.sh --reconfigure a,b # re-apply these component ids
bash install.sh --uninstall a,b  # uninstall these component ids
bash install.sh --list-components  # print: id<TAB>label<TAB>default
bash install.sh --list-configurable-components
bash install.sh --list-select-configure-components
bash install.sh --list-component-config-values
bash install.sh --configure-component ID
bash install.sh --detect
bash install.sh --export-selection # print the resolved selection as JSON
bash install.sh --auth          # allow authenticated Git clone/pull in components
bash install.sh --help          # show all installer commands
bash install.sh -h              # same as --help
```

`--config`, `--select`, `--reconfigure`, `--uninstall`, and
`--configure-component` also accept the `--option=value` form. The installer
also exposes read-only app-rule queries for
the selected workspace, sticky, and monitor mappings:

```bash
bash install.sh --list-selected-app-workspaces
bash install.sh --list-selected-sticky-apps
bash install.sh --list-selected-app-monitors
```

In the interactive menu, **space** toggles a component, `a`/`n` select all
or none, and **Enter** installs the selection. Components:

| Component id | Description | Default |
|---|---|---|
| `workspace_send_mode` | Send active window to workspace (Super+U key map) | on |
| `automatic_window_tiling` | Automatic same-app window tiling | on |
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

App rules are owned solely by this repository. Monitor numbers are 1-based;
saved screen geometry takes precedence over numeric indexes after renumbering.
Window creation waits for mapping and app identity for up to fifteen seconds,
and cancels pending work when a window closes or the extension is disabled.
Run the desktop-free regression suite with `node --test tests/test_app_rules.mjs`.
After deployment, GSettings changes apply live. Extension code takes effect
after the session-specific activation described above; the installer does not
restart GNOME Shell.

Monkeytype opens on workspace 7 on monitor 2 (the primary display), including
its Chrome PWA instance. Auto Move Windows pins both `monkeytype.desktop` and
the Chrome PWA app ID `chrome-picebhhlijnlefeleilfbanaghjlkkna-Default.desktop`
to workspace 7 as the app window is created. The app-rules fallback also
handles Chrome windows that report skip-taskbar (role=pop-up)
and waits for the `crx_*` window-class instance instead of treating
`google-chrome.desktop` as a finished non-match. Chrome windows whose title
contains Monkeytype are matched the same way. It retries the monitor move until
the window is safe to move, and still pins the window to workspace 7 while that
move is pending. Spotify and Discord stay on
all workspaces by desktop id or wm class (`spotify` / `discord`), including
snap ids and skip-taskbar Electron windows. Initialized windows hidden on other
workspaces may be placed; unmapped windows on the current workspace still wait
for mapping. Monitor moves precede workspace moves, and closed windows cancel
pending placement.

Cursor defaults to the primary monitor. Its window class identifies startup
windows before the desktop ID arrives, while saved user monitor rules retain
precedence and do not gain an unwanted workspace assignment.

SmartGit uses its startup window class when its desktop ID is delayed, and
opens on monitor 3 at workspace 3. The monitor move happens before the workspace
change can hide its actor.

Programmatic app-rule placement preserves an existing all-workspaces preference,
even for monitor-only rules and when a workspace move fails. Explicit sticky
rules are reapplied after placement; failures are reported in the Shell journal.

## Installer lifecycle

Run these commands from this checkout. The component IDs printed by discovery
are the same IDs used by the terminal menu and programmatic actions.

| Command | Behavior |
| --- | --- |
| `bash install.sh` | Open component selection on a terminal; use the default/config selection otherwise. |
| `bash install.sh --help` | Show accepted options (`-h` is equivalent). |
| `bash install.sh --list-components` | Print component IDs, labels and defaults. |
| `bash install.sh --default` | Apply default-on components. |
| `bash install.sh --all` | Apply every component. |
| `bash install.sh --select ID,...` | Apply exactly the named components. |
| `bash install.sh --reconfigure ID,...` | Reapply those components through the same install operations. |
| `bash install.sh --uninstall ID,...` | Run the selected removal operations. |
| `bash install.sh --detect` | Print `ID<TAB>installed` or `ID<TAB>absent`. |
| `bash install.sh --export-selection` | Print selection JSON without applying it. |

The shared interface also accepts `--config NAME` (an installation JSON name
or path) and `--auth` (explicit permission for authenticated component actions).
`--config=NAME`, `--select=ID,...`, `--reconfigure=ID,...`,
`--uninstall=ID,...` and `--configure-component=ID` are equivalent forms.
Advanced discovery is available through `--list-configurable-components`,
`--list-select-configure-components` and `--list-component-config-values`;
`--configure-component ID` opens an available nested screen. Atomic owners
return empty advanced listings and reject unavailable nested configuration.

Explicit `--select ""` selects no optional components; a defined mandatory core
or installation preflight still runs. `--uninstall ""` is a no-op. Unknown or
duplicate IDs, missing operands and conflicting modes reject before component
installation/removal. Help, discovery, detection and export perform no installation.
Cancelling the component menu performs no install/removal. Configuration screens
may save their own settings when explicitly accepted.

The shared terminal screen uses arrows to move, Space to toggle, Enter to
apply and `q`/Escape to cancel; installed components support `u` for removal.
A right-arrow detail action appears where the owner provides configuration.
Removal-only selections skip core installation.

The licensed `.installer-support/` package is generated by
`linux_installation_scripts_functions`; `manifest.json` records provenance and
SHA-256 hashes, and `LICENSE.md` retains the MIT grant. It is a shared library
subset, not an application checkout. The default bootstrap requires no private
download or sibling repository. Explicit `ISC_COMPONENT_LIB_DIR` /
`ISC_FUNCTIONS_DIR` overrides remain available for development and the old setup
chain. Regenerate support from its owner rather than editing copies. Bash and
Python 3 are needed for this library; project build/runtime requirements above
still apply.

For example, inspect IDs first, then use the same ID with either interface:

```bash
bash install.sh --list-components
bash install.sh --select albert
bash install.sh --detect
bash install.sh --uninstall albert
```
