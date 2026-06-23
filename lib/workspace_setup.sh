#!/usr/bin/env bash
# workspace_setup.sh - Ubuntu GNOME workspace and window-hotkey setup helpers.
#
# The caller may set TARGET_USER, TARGET_HOME, SCRIPT_DIR, CONFIG_DIR,
# RUNTIME_DIR, DISPLAY_VAL, USER_BUS, and SESSION_TYPE before sourcing.

: "${TARGET_USER:=${SUDO_USER:-$USER}}"
: "${TARGET_HOME:=$(getent passwd "$TARGET_USER" | cut -d: -f6)}"
WORKSPACE_SETUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_SETUP_DIR="$(cd "$WORKSPACE_SETUP_LIB_DIR/.." && pwd)"
WORKSPACE_SETUP_CONFIG_DIR="$WORKSPACE_SETUP_DIR/configs"
: "${SCRIPT_DIR:=$WORKSPACE_SETUP_DIR}"
: "${CONFIG_DIR:=$WORKSPACE_SETUP_CONFIG_DIR}"
: "${RUNTIME_DIR:=/run/user/$(id -u "$TARGET_USER")}"
: "${DISPLAY_VAL:=${DISPLAY:-:0}}"
: "${USER_BUS:=unix:path=${RUNTIME_DIR}/bus}"
: "${SESSION_TYPE:=${XDG_SESSION_TYPE:-unknown}}"
: "${APT_UPDATED:=0}"
: "${WORKSPACE_COUNT:=8}"
: "${WORKSPACE_CLEAR_UNUSED_BINDINGS:=1}"
: "${MONITOR_WINDOW_HOTKEYS_EXTENSION_ID:=monitor-window-hotkeys@local}"
: "${MONITOR_WINDOW_HOTKEYS_SOURCE_DIR:=$CONFIG_DIR/gnome-shell/extensions/$MONITOR_WINDOW_HOTKEYS_EXTENSION_ID}"
: "${AUTOMATIC_WINDOW_TILING_DIR:=$SCRIPT_DIR/../linux_automatic_window_tiling}"
AUTOMATIC_WINDOW_TILING_BINDING="${AUTOMATIC_WINDOW_TILING_BINDING:-<Super>t}"

DEFAULT_SCREENSHOT_UI_BINDINGS=("<Shift><Super>s")
DEFAULT_SCREENSHOT_QUICK_BINDINGS=("Print")
DEFAULT_OVERVIEW_BINDINGS=("<Super>Tab")
DEFAULT_WORKSPACE_SWITCH_BINDINGS=(
  "1:<Super>Z"
  "2:<Super>X"
  "3:<Super>C"
  "4:<Super>A"
  "5:<Super>Q"
  "6:<Super>W"
  "7:<Super>E"
  "8:<Super>R"
)
DEFAULT_WORKSPACE_MOVE_BINDINGS=(
  "1:<Super><Shift>Z"
  "2:<Super><Shift>X"
  "3:<Super><Shift>C"
  "4:<Super><Shift>A"
  "5:<Super><Shift>Q"
  "6:<Super><Shift>W"
  "7:<Super><Shift>E"
  "8:<Super><Shift>R"
)
DEFAULT_SUPER_ARROW_MOVE_BINDINGS=(
  "move-to-workspace-left:<Super><Shift>Left"
  "move-to-workspace-right:<Super><Shift>Right"
  "move-to-workspace-down:<Super><Shift>Down"
  "move-to-workspace-up:<Super><Shift>Up"
)

WM_CONFLICT_UNBINDINGS=(
  "minimize:<Alt><Super>R"
  "maximize:<Super>Up"
  "unmaximize:<Super>Down"
  "minimize:<Super>Down"
)
TILING_CONFLICT_UNBINDINGS=(
  "tile-maximize:<Super>Up"
  "tile-top-half:<Control><Super>X"
  "tile-top-half:<Super>Up"
  "tile-bottom-half:<Control><Super>W"
  "tile-bottom-half:<Super>Down"
  "tile-left-half:<Control><Super>C"
  "tile-left-half:<Super>Left"
  "tile-right-half:<Super>Right"
)

# Centralized installer log. Every repository-generated log lands under the
# repo-root .log/ directory (created on demand); messages are still echoed to
# the console so interactive runs and the master installer see live progress.
: "${WORKSPACE_SETUP_LOG_DIR:=$WORKSPACE_SETUP_DIR/.log}"
: "${WORKSPACE_SETUP_LOG_FILE:=$WORKSPACE_SETUP_LOG_DIR/install.log}"

# log_line LEVEL MESSAGE - append a timestamped record to the install log.
#   LEVEL:   severity tag (INFO, WARN, ERROR).
#   MESSAGE: text to record; never fails the install if the log is unwritable.
log_line() {
  local level="$1"
  shift
  mkdir -p "$WORKSPACE_SETUP_LOG_DIR" 2>/dev/null || return 0
  printf '%s %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$*" \
    >>"$WORKSPACE_SETUP_LOG_FILE" 2>/dev/null || true
}

log_debug() {
  log_line DEBUG "$*"
}

log_warn() {
  log_line WARN "$*"
}

# msg MESSAGE - print a banner to the console and mirror it to the install log.
#   MESSAGE: human-readable progress text.
msg() {
  printf '\n==> %s\n' "$*"
  log_line INFO "$*"
}

# need_cmd, is_root, run_as_target, and the sudo-skip reporting are provided by
# the framework's installer_helpers.sh (loaded by install.sh via isc_load_helpers
# before this file). The custom msg() above is kept because it also mirrors to
# the install log, and apt_install below is kept because it batches via
# apt_update_once.

user_gsettings() {
  run_as_target gsettings "$@"
}

extension_gsettings() {
  local schema_dir="$TARGET_HOME/.local/share/gnome-shell/extensions/$MONITOR_WINDOW_HOTKEYS_EXTENSION_ID/schemas"
  if [ -d "$schema_dir" ]; then
    run_as_target gsettings --schemadir "$schema_dir" "$@"
  else
    run_as_target gsettings "$@"
  fi
}

join_as_gsettings_array() {
  local out="[" sep="" value escaped
  for value in "$@"; do
    [ -n "$value" ] || continue
    escaped="${value//\\/\\\\}"
    escaped="${escaped//\'/\\\'}"
    out+="${sep}'${escaped}'"
    sep=", "
  done
  out+="]"
  printf '%s\n' "$out"
}

set_gsettings_strv() {
  local schema="$1" key="$2"
  shift 2
  user_gsettings set "$schema" "$key" "$(join_as_gsettings_array "$@")"
}

set_extension_strv() {
  local key="$1"
  shift
  extension_gsettings set org.gnome.shell.extensions.monitor-window-hotkeys "$key" "$(join_as_gsettings_array "$@")"
}

gsettings_key_exists() {
  local schema="$1" key="$2"
  run_as_target gsettings list-keys "$schema" 2>/dev/null | grep -qx "$key"
}

set_gsettings_strv_if_key_exists() {
  local schema="$1" key="$2"
  shift 2
  if gsettings_key_exists "$schema" "$key"; then
    set_gsettings_strv "$schema" "$key" "$@"
  fi
}

append_gsettings_list() {
  local schema="$1" key="$2" value="$3" current new_value
  if ! current="$(user_gsettings get "$schema" "$key" 2>/dev/null)"; then
    log_warn "Could not read $schema $key; using an empty list before appending $value"
    current="[]"
  fi
  new_value="$(CURRENT="$current" python3 "$WORKSPACE_SETUP_LIB_DIR/gsettings_strv.py" append "$value")"
  log_debug "Setting $schema $key to $new_value"
  user_gsettings set "$schema" "$key" "$new_value"
}

remove_gsettings_list() {
  local schema="$1" key="$2" value="$3" current new_value
  if ! current="$(user_gsettings get "$schema" "$key" 2>/dev/null)"; then
    log_warn "Could not read $schema $key; using an empty list before removing $value"
    current="[]"
  fi
  new_value="$(CURRENT="$current" python3 "$WORKSPACE_SETUP_LIB_DIR/gsettings_strv.py" remove "$value")"
  log_debug "Setting $schema $key to $new_value"
  user_gsettings set "$schema" "$key" "$new_value"
}

parse_pipe_binding_entries() {
  local raw="$1" delimiter="$2" output_name="$3" default_name="$4"
  local -n output_ref="$output_name"
  local -n default_ref="$default_name"
  output_ref=()

  if [ -n "$raw" ]; then
    local old_ifs="$IFS"
    IFS="$delimiter"
    read -r -a output_ref <<< "$raw"
    IFS="$old_ifs"
  fi

  if [ "${#output_ref[@]}" -eq 0 ]; then
    output_ref=("${default_ref[@]}")
  fi
}

ensure_workspace_binding_arrays() {
  if ! declare -p WORKSPACE_SWITCH_BINDINGS_ARRAY >/dev/null 2>&1; then
    parse_pipe_binding_entries "${WORKSPACE_SWITCH_BINDINGS:-}" "|" WORKSPACE_SWITCH_BINDINGS_ARRAY DEFAULT_WORKSPACE_SWITCH_BINDINGS
  fi
  if ! declare -p WORKSPACE_MOVE_BINDINGS_ARRAY >/dev/null 2>&1; then
    parse_pipe_binding_entries "${WORKSPACE_MOVE_BINDINGS:-}" "|" WORKSPACE_MOVE_BINDINGS_ARRAY DEFAULT_WORKSPACE_MOVE_BINDINGS
  fi
  if ! declare -p SUPER_ARROW_MOVE_BINDINGS_ARRAY >/dev/null 2>&1; then
    parse_pipe_binding_entries "${SUPER_ARROW_MOVE_BINDINGS:-}" "|" SUPER_ARROW_MOVE_BINDINGS_ARRAY DEFAULT_SUPER_ARROW_MOVE_BINDINGS
  fi
  if ! declare -p OVERVIEW_BINDINGS_ARRAY >/dev/null 2>&1; then
    parse_pipe_binding_entries "${OVERVIEW_BINDINGS:-}" "|" OVERVIEW_BINDINGS_ARRAY DEFAULT_OVERVIEW_BINDINGS
  fi
  if ! declare -p SCREENSHOT_UI_BINDINGS_ARRAY >/dev/null 2>&1; then
    parse_pipe_binding_entries "${SCREENSHOT_UI_BINDINGS:-}" "|" SCREENSHOT_UI_BINDINGS_ARRAY DEFAULT_SCREENSHOT_UI_BINDINGS
  fi
  if ! declare -p SCREENSHOT_QUICK_BINDINGS_ARRAY >/dev/null 2>&1; then
    parse_pipe_binding_entries "${SCREENSHOT_QUICK_BINDINGS:-}" "|" SCREENSHOT_QUICK_BINDINGS_ARRAY DEFAULT_SCREENSHOT_QUICK_BINDINGS
  fi
}

set_indexed_keybinding_map() {
  local schema="$1" key_prefix="$2"
  shift 2
  local entry idx binding i seen

  if [ "$WORKSPACE_CLEAR_UNUSED_BINDINGS" != "0" ]; then
    for ((i = 1; i <= WORKSPACE_COUNT; i++)); do
      seen=0
      for entry in "$@"; do
        idx="${entry%%:*}"
        if [ "$idx" = "$i" ]; then
          seen=1
          break
        fi
      done
      if [ "$seen" -eq 0 ]; then
        set_gsettings_strv "$schema" "${key_prefix}${i}"
      fi
    done
  fi

  for entry in "$@"; do
    idx="${entry%%:*}"
    binding="${entry#*:}"
    set_gsettings_strv "$schema" "${key_prefix}${idx}" "$binding"
  done
}

accelerator_with_control() {
  local accelerator="$1"
  if [[ "$accelerator" == *"<Control>"* ]] || [[ "$accelerator" == *"<Ctrl>"* ]]; then
    printf '%s\n' "$accelerator"
    return 0
  fi
  printf '<Control>%s\n' "$accelerator"
}

configure_workspace_send_extension_bindings() {
  ensure_workspace_binding_arrays

  local send_mode_entries=() no_switch_entries=() entry idx binding
  for entry in "${WORKSPACE_SWITCH_BINDINGS_ARRAY[@]}"; do
    idx="${entry%%:*}"
    binding="${entry#*:}"
    send_mode_entries+=("$idx:$binding")
  done
  for entry in "${WORKSPACE_MOVE_BINDINGS_ARRAY[@]}"; do
    idx="${entry%%:*}"
    binding="${entry#*:}"
    no_switch_entries+=("$idx:$(accelerator_with_control "$binding")")
  done

  set_extension_strv send-mode-workspace-bindings "${send_mode_entries[@]}" || true
  for entry in "${no_switch_entries[@]}"; do
    idx="${entry%%:*}"
    binding="${entry#*:}"
    set_extension_strv "send-active-window-to-workspace-${idx}" "$binding" || true
  done
}

remove_conflicting_binding_entries() {
  local schema="$1"
  shift
  local entry key binding
  for entry in "$@"; do
    key="${entry%%:*}"
    binding="${entry#*:}"
    remove_gsettings_list "$schema" "$key" "$binding" || true
  done
}

clear_binding_entries() {
  local schema="$1"
  shift
  local entry key
  for entry in "$@"; do
    key="${entry%%:*}"
    set_gsettings_strv "$schema" "$key"
  done
}

enable_shell_extension() {
  local ext_id="$1"
  append_gsettings_list org.gnome.shell enabled-extensions "$ext_id" || true
}

apt_update_once() {
  if [ "$APT_UPDATED" -eq 0 ]; then
    msg "Updating apt cache"
    apt update -y
    APT_UPDATED=1
  fi
}

apt_install() {
  local missing=() pkg
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  [ "${#missing[@]}" -eq 0 ] && return 0
  if ! is_root; then
    note_sudo_required "apt install ${missing[*]}"
    return 0
  fi
  apt_update_once
  DEBIAN_FRONTEND=noninteractive apt install -y "${missing[@]}"
}

reload_systemd_daemon() {
  run_as_target systemctl --user daemon-reload || true
}

enable_systemd_service() {
  local service_name="$1"
  run_as_target systemctl --user daemon-reload || true
  run_as_target systemctl --user enable "$service_name" || true
  run_as_target systemctl --user restart "$service_name" || true
}

configure_screenshot_binding() {
  ensure_workspace_binding_arrays
  msg "Binding screenshot keys"
  local old_custom_screenshot_path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/custom-screenshot/"

  set_gsettings_strv org.gnome.shell.keybindings show-screenshot-ui "${SCREENSHOT_UI_BINDINGS_ARRAY[@]}"
  set_gsettings_strv org.gnome.shell.keybindings screenshot "${SCREENSHOT_QUICK_BINDINGS_ARRAY[@]}"
  set_gsettings_strv org.gnome.shell.keybindings show-screen-recording-ui
  set_gsettings_strv_if_key_exists org.gnome.settings-daemon.plugins.media-keys screenshot "${SCREENSHOT_QUICK_BINDINGS_ARRAY[@]}"
  set_gsettings_strv_if_key_exists org.gnome.settings-daemon.plugins.media-keys screenshot-clip "${SCREENSHOT_QUICK_BINDINGS_ARRAY[@]}"
  remove_gsettings_list org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$old_custom_screenshot_path" || true
  user_gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$old_custom_screenshot_path" binding "''" || true
}

configure_workspace_keys() {
  ensure_workspace_binding_arrays
  msg "Applying workspace and UI keybindings"

  user_gsettings set org.gnome.mutter dynamic-workspaces false
  user_gsettings set org.gnome.desktop.wm.preferences num-workspaces "$WORKSPACE_COUNT"
  set_indexed_keybinding_map org.gnome.desktop.wm.keybindings switch-to-workspace- "${WORKSPACE_SWITCH_BINDINGS_ARRAY[@]}"
  set_indexed_keybinding_map org.gnome.desktop.wm.keybindings move-to-workspace- "${WORKSPACE_MOVE_BINDINGS_ARRAY[@]}"

  local entry key binding
  for entry in "${SUPER_ARROW_MOVE_BINDINGS_ARRAY[@]}"; do
    key="${entry%%:*}"
    binding="${entry#*:}"
    set_gsettings_strv org.gnome.desktop.wm.keybindings "$key" "$binding"
  done

  set_gsettings_strv org.gnome.shell.keybindings toggle-overview "${OVERVIEW_BINDINGS_ARRAY[@]}"
  set_gsettings_strv org.gnome.shell.keybindings toggle-application-view
  set_gsettings_strv org.gnome.shell.keybindings toggle-quick-settings
  user_gsettings set org.gnome.mutter overlay-key "''"
  user_gsettings set org.gnome.desktop.interface enable-animations false
  user_gsettings set org.gnome.mutter workspaces-only-on-primary false
  user_gsettings set org.gnome.shell.app-switcher current-workspace-only true
  user_gsettings set org.gnome.shell.window-switcher current-workspace-only true

  clear_binding_entries org.gnome.desktop.wm.keybindings "${WM_CONFLICT_UNBINDINGS[@]}"
  if [ -n "${TILING_ASSISTANT_SCHEMA:-}" ] || run_as_target gsettings list-schemas | grep -qx "org.gnome.shell.extensions.tiling-assistant"; then
    user_gsettings set "${TILING_ASSISTANT_SCHEMA:-org.gnome.shell.extensions.tiling-assistant}" enable-tiling-popup false || true
    remove_conflicting_binding_entries "${TILING_ASSISTANT_SCHEMA:-org.gnome.shell.extensions.tiling-assistant}" "${TILING_CONFLICT_UNBINDINGS[@]}"
  fi
}

configure_monitor_window_hotkeys_extension() {
  msg "Installing local GNOME Shell monitor/window hotkeys"

  local ext_id="$MONITOR_WINDOW_HOTKEYS_EXTENSION_ID"
  local source_dir="$MONITOR_WINDOW_HOTKEYS_SOURCE_DIR"
  local ext_dir="$TARGET_HOME/.local/share/gnome-shell/extensions/$ext_id"

  if [ ! -d "$source_dir" ]; then
    msg "Monitor/window hotkeys source not found at $source_dir; skipping."
    return 0
  fi

  if is_root; then
    install -d -o "$TARGET_USER" -g "$TARGET_USER" "$ext_dir"
  else
    install -d "$ext_dir"
  fi
  cp -a "$source_dir/." "$ext_dir/"
  if is_root; then
    chown -R "$TARGET_USER:$TARGET_USER" "$ext_dir"
  fi
  run_as_target chmod +x "$ext_dir/apply-system-bindings.sh"

  if ! need_cmd glib-compile-schemas; then
    apt_install libglib2.0-bin
  fi
  if need_cmd glib-compile-schemas; then
    glib-compile-schemas "$ext_dir/schemas"
  fi

  if ! run_as_target "$ext_dir/apply-system-bindings.sh"; then
    msg "WARNING: monitor-window-hotkeys apply-system-bindings.sh failed; log out/in, then re-run installer."
    return 0
  fi

  configure_workspace_send_extension_bindings
  enable_shell_extension "$ext_id"
  msg "Monitor/window hotkeys extension installed. Log out and back in before testing Shell extension changes."
}

configure_automatic_window_tiling() {
  msg "Configuring automatic window tiling"
  local installer="$AUTOMATIC_WINDOW_TILING_DIR/install.sh"

  if [[ ! -f "$installer" ]]; then
    msg "Automatic window tiling repository not found at $AUTOMATIC_WINDOW_TILING_DIR; skipping."
    return 0
  fi

  TARGET_USER="$TARGET_USER" bash "$installer" "$AUTOMATIC_WINDOW_TILING_BINDING"
}

select_input_device() {
  msg "Detecting pointing devices with back buttons"
  local device_list
  device_list="$(PYTHONPATH="$CONFIG_DIR/window-hotkeys${PYTHONPATH:+:$PYTHONPATH}" python3 -c '
from evdev import InputDevice, ecodes, list_devices
from input_device_paths import input_device_sort_key, stable_device_path

BACK_CODES = {ecodes.KEY_BACK, ecodes.BTN_SIDE, ecodes.BTN_EXTRA}
POINTER_RELS = {ecodes.REL_X, ecodes.REL_Y}
devices = []
for path in sorted(list_devices(), key=input_device_sort_key):
    try:
        dev = InputDevice(path)
    except OSError:
        continue
    caps = dev.capabilities(absinfo=False)
    keys = set(caps.get(ecodes.EV_KEY, []))
    rels = set(caps.get(ecodes.EV_REL, []))
    if (rels & POINTER_RELS) and (keys & BACK_CODES) and "ctrl-back-window-tiler" not in dev.name:
        devices.append((stable_device_path(dev.path), dev.name))
    dev.close()
for path, name in devices:
    print(f"{path}|{name}")
' 2>/dev/null)" || true
  if [ -z "$device_list" ]; then
    msg "No pointing devices with back buttons detected; tiler service will be skipped."
    return 1
  fi
  local selected
  selected="$(printf '%s\n' "$device_list" | head -1)"
  SELECTED_INPUT_DEVICE="${selected%%|*}"
  SELECTED_INPUT_DEVICE_NAME="${selected##*|}"
  msg "Selected pointing device: $SELECTED_INPUT_DEVICE_NAME ($SELECTED_INPUT_DEVICE)"
}

configure_ctrl_back_window_tiler_service() {
  msg "Installing Ctrl + browser-back window tiler service"
  local script_source="$CONFIG_DIR/window-hotkeys/ctrl_back_tile_right.py"
  local state_source="$CONFIG_DIR/window-hotkeys/ctrl_back_event_state.py"
  local paths_source="$CONFIG_DIR/window-hotkeys/input_device_paths.py"
  local client_source="$CONFIG_DIR/window-hotkeys/tile_right_client.py"
  local logging_source="$CONFIG_DIR/window-hotkeys/logging_setup.py"
  local service_source="$CONFIG_DIR/window-hotkeys/ctrl-back-window-tiler.service"
  local bin_dir="$TARGET_HOME/.local/bin"
  local service_target="$TARGET_HOME/.config/systemd/user/ctrl-back-window-tiler.service"
  local device_filter="${SELECTED_INPUT_DEVICE:-}"

  if [ ! -f "$script_source" ] || [ ! -f "$service_source" ]; then
    msg "Ctrl-back tiler service source files missing; skipping."
    return 0
  fi

  run_as_target mkdir -p "$bin_dir" "$(dirname "$service_target")"
  if is_root; then
    install -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$script_source" "$bin_dir/ctrl_back_tile_right.py"
    install -m 0644 -o "$TARGET_USER" -g "$TARGET_USER" "$state_source" "$bin_dir/ctrl_back_event_state.py"
    install -m 0644 -o "$TARGET_USER" -g "$TARGET_USER" "$paths_source" "$bin_dir/input_device_paths.py"
    install -m 0644 -o "$TARGET_USER" -g "$TARGET_USER" "$client_source" "$bin_dir/tile_right_client.py"
    install -m 0644 -o "$TARGET_USER" -g "$TARGET_USER" "$logging_source" "$bin_dir/logging_setup.py"
  else
    install -m 0755 "$script_source" "$bin_dir/ctrl_back_tile_right.py"
    install -m 0644 "$state_source" "$bin_dir/ctrl_back_event_state.py"
    install -m 0644 "$paths_source" "$bin_dir/input_device_paths.py"
    install -m 0644 "$client_source" "$bin_dir/tile_right_client.py"
    install -m 0644 "$logging_source" "$bin_dir/logging_setup.py"
  fi
  run_as_target tee "$service_target" >/dev/null <<EOF
[Unit]
Description=Ctrl + browser-back window right-half tiler
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=$bin_dir/ctrl_back_tile_right.py
Restart=on-failure
RestartSec=2
Environment=CTRL_BACK_TILE_DEVICE=${device_filter:-}

[Install]
WantedBy=default.target
EOF
  reload_systemd_daemon
  enable_systemd_service ctrl-back-window-tiler.service
}

configure_workspace_number_popup_extension() {
  msg "Installing local GNOME Shell numbered workspace popup"
  local ext_id="workspace-number-indicator@local"
  local ext_dir="$TARGET_HOME/.local/share/gnome-shell/extensions/$ext_id"

  run_as_target mkdir -p "$ext_dir"
  run_as_target tee "$ext_dir/metadata.json" >/dev/null <<'EOF'
{
  "uuid": "workspace-number-indicator@local",
  "name": "Numbered Workspace Popup",
  "description": "Show workspace numbers in the workspace switcher popup",
  "shell-version": ["45", "46", "47", "48", "49", "50"],
  "version": 5
}
EOF
  run_as_target tee "$ext_dir/extension.js" >/dev/null <<'EOF'
import Clutter from 'gi://Clutter';
import St from 'gi://St';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as WorkspaceSwitcherPopup from 'resource:///org/gnome/shell/ui/workspaceSwitcherPopup.js';

export default class NumberedWorkspacePopupExtension extends Extension {
  enable() {
    const popupProto = WorkspaceSwitcherPopup.MonitorWorkspaceSwitcherPopup?.prototype
      ?? WorkspaceSwitcherPopup.WorkspaceSwitcherPopup?.prototype;
    const redisplayMethodName = popupProto?.redisplay ? 'redisplay' : popupProto?._redisplay ? '_redisplay' : null;
    if (!popupProto || !redisplayMethodName) {
      console.warn('Numbered Workspace Popup: unsupported GNOME Shell workspace switcher API');
      return;
    }
    this._popupProto = popupProto;
    this._redisplayMethodName = redisplayMethodName;
    this._originalRedisplay = popupProto[redisplayMethodName];
    popupProto[redisplayMethodName] = function(activeWorkspaceIndex = null) {
      const activeIndex = Number.isInteger(activeWorkspaceIndex) ? activeWorkspaceIndex : this._activeWorkspaceIndex;
      this._list.destroy_all_children();
      for (let i = 0; i < global.workspace_manager.n_workspaces; i++) {
        const label = new St.Label({ style_class: 'workspace-number-popup-label', text: `${i + 1}` });
        const indicator = new St.Bin({
          style_class: 'ws-switcher-indicator workspace-number-popup-indicator',
          child: label,
          x_align: Clutter.ActorAlign.CENTER,
          y_align: Clutter.ActorAlign.CENTER,
        });
        if (i === activeIndex)
          indicator.add_style_pseudo_class('active');
        this._list.add_child(indicator);
      }
    };
  }

  disable() {
    if (this._originalRedisplay && this._popupProto && this._redisplayMethodName)
      this._popupProto[this._redisplayMethodName] = this._originalRedisplay;
    this._originalRedisplay = null;
    this._redisplayMethodName = null;
    this._popupProto = null;
  }
}
EOF
  run_as_target tee "$ext_dir/stylesheet.css" >/dev/null <<'EOF'
.workspace-number-popup-indicator {
  min-width: 44px;
  min-height: 32px;
  margin: 2px 0;
  padding: 0;
  border-radius: 5px;
  border: 1px solid rgba(238, 238, 236, 0.22);
  background-color: rgba(238, 238, 236, 0.16);
}
.workspace-number-popup-indicator:active {
  border-color: rgba(238, 238, 236, 0.95);
  background-color: #eeeeec;
}
.workspace-number-popup-label {
  font-size: 14px;
  font-weight: 700;
  color: rgba(255, 255, 255, 0.82);
}
.workspace-number-popup-indicator:active .workspace-number-popup-label {
  color: #2e3436;
}
EOF
  enable_shell_extension "$ext_id"
}

configure_app_rules_extension() {
  msg "Deploying app-rules@local GNOME Shell extension"
  local ext_src="$CONFIG_DIR/gnome-extensions/app-rules@local"
  local ext_dst="$TARGET_HOME/.local/share/gnome-shell/extensions/app-rules@local"

  if [ ! -d "$ext_src" ]; then
    msg "app-rules source not found at $ext_src; skipping."
    return 0
  fi

  run_as_target mkdir -p "$ext_dst"
  cp -a "$ext_src/." "$ext_dst/"
  if is_root; then
    chown -R "$TARGET_USER:$TARGET_USER" "$ext_dst"
  fi
  enable_shell_extension app-rules@local
}

find_desktop_entry() {
  local candidate path
  for candidate in "$@"; do
    for path in \
      "$TARGET_HOME/.local/share/applications/$candidate" \
      "/usr/local/share/applications/$candidate" \
      "/usr/share/applications/$candidate" \
      "/var/lib/snapd/desktop/applications/$candidate"; do
      [ -f "$path" ] && printf '%s\n' "$candidate" && return 0
    done
  done
  return 1
}

first_existing_desktop() {
  find_desktop_entry "$@" || true
}

install_auto_move_windows_extension() {
  local ext_id="auto-move-windows@gnome-shell-extensions.gcampax.github.com"
  local ext_dir="$TARGET_HOME/.local/share/gnome-shell/extensions/$ext_id"
  local system_ext_dir="/usr/share/gnome-shell/extensions/$ext_id"
  [ -d "$ext_dir" ] || [ -d "$system_ext_dir" ] && return 0
  if is_root && apt-cache show gnome-shell-extension-auto-move-windows >/dev/null 2>&1; then
    apt_install gnome-shell-extension-auto-move-windows || true
  fi
  [ -d "$ext_dir" ] || [ -d "$system_ext_dir" ]
}

configure_auto_move_windows() {
  msg "Configuring auto-move-windows where available"
  local ext_id="auto-move-windows@gnome-shell-extensions.gcampax.github.com"
  if ! install_auto_move_windows_extension; then
    msg "auto-move-windows is unavailable; app-rules@local handles workspace placement."
    return 0
  fi
  enable_shell_extension "$ext_id"
  local gitkraken_desktop
  gitkraken_desktop="$(first_existing_desktop gitkraken.desktop gitkraken_gitkraken.desktop)"
  if [ -n "$gitkraken_desktop" ] && gsettings_key_exists org.gnome.shell.extensions.auto-move-windows application-list; then
    append_gsettings_list org.gnome.shell.extensions.auto-move-windows application-list "${gitkraken_desktop}:2"
  fi
}

configure_ubuntu_workspaces_and_hotkeys() {
  msg "Applying Ubuntu workspace setup"
  select_input_device || true
  configure_screenshot_binding
  configure_workspace_keys
  configure_monitor_window_hotkeys_extension
  configure_automatic_window_tiling
  configure_ctrl_back_window_tiler_service
  configure_workspace_number_popup_extension
  configure_app_rules_extension
  configure_auto_move_windows
  report_sudo_required
  msg "Ubuntu workspace setup complete. Log out and back in before testing GNOME Shell extension changes."
}
