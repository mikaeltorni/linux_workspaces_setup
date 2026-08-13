#!/usr/bin/env bash
# workspace_setup.sh - Ubuntu GNOME workspace and window-hotkey setup helpers.
#
# The caller may set TARGET_USER, TARGET_HOME, SCRIPT_DIR, CONFIG_DIR,
# RUNTIME_DIR, DISPLAY_VAL, USER_BUS, and SESSION_TYPE before sourcing.

: "${TARGET_USER:=${SUDO_USER:-$USER}}"
: "${TARGET_HOME:=$(getent passwd "$TARGET_USER" | cut -d: -f6)}"
WORKSPACE_SETUP_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_SETUP_DIR="$(cd "$WORKSPACE_SETUP_LIB_DIR/.." && pwd)"
# shellcheck source=wss_bin.sh
source "$WORKSPACE_SETUP_LIB_DIR/wss_bin.sh"
WORKSPACE_SETUP_CONFIG_DIR="$WORKSPACE_SETUP_DIR/configs"
: "${SCRIPT_DIR:=$WORKSPACE_SETUP_DIR}"
: "${CONFIG_DIR:=$WORKSPACE_SETUP_CONFIG_DIR}"
: "${RUNTIME_DIR:=/run/user/$(id -u "$TARGET_USER")}"
: "${DISPLAY_VAL:=${DISPLAY:-:0}}"
: "${USER_BUS:=unix:path=${RUNTIME_DIR}/bus}"
: "${SESSION_TYPE:=${XDG_SESSION_TYPE:-unknown}}"
: "${APT_UPDATED:=0}"
: "${WORKSPACE_COUNT:=8}"
# The monitor-window-hotkeys@local extension is installed by the standalone
# linux_monitor_window_hotkeys repository; this repo only configures its send-mode
# key map, so it references the extension id (for the schema dir) but no longer
# ships or installs the extension source.
: "${MONITOR_WINDOW_HOTKEYS_EXTENSION_ID:=monitor-window-hotkeys@local}"
: "${AUTOMATIC_WINDOW_TILING_DIR:=$SCRIPT_DIR/../linux_automatic_window_tiling}"
AUTOMATIC_WINDOW_TILING_BINDING="${AUTOMATIC_WINDOW_TILING_BINDING:-<Super>t}"

# Albert launcher toggle. The binding accepts both the friendly "super+z" form
# and GNOME's native "<Super>z" form; bare keysyms such as the default 'aring'
# (the Å key) pass through unchanged.
: "${ALBERT_TOGGLE_BINDING:=aring}"
: "${ALBERT_TOGGLE_COMMAND:=albert toggle}"
: "${ALBERT_TOGGLE_NAME:=Albert Toggle}"

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

# load_hotkey_workspace_binding_config — Import the hotkey repository's typed
# switch fields and shared move modifier so extension-only send actions stay in
# sync. Explicit WORKSPACE_SWITCH/MOVE_BINDINGS values remain authoritative.
load_hotkey_workspace_binding_config() {
  declare -F isc_hotkey_field_value >/dev/null 2>&1 || return 0
  local config="${WORKSPACE_HOTKEY_CONFIG:-$TARGET_HOME/.config/linux-hotkey-setup/workspace-hotkeys.conf}"
  local modifier index entry default_value switch_value move_value
  modifier="$(isc_hotkey_field_value "$config" WORKSPACE_MOVE_MODIFIER Shift)"
  local switches="" moves=""
  for ((index = 1; index <= WORKSPACE_COUNT; index++)); do
    default_value=""
    for entry in "${DEFAULT_WORKSPACE_SWITCH_BINDINGS[@]}"; do
      [[ "${entry%%:*}" == "$index" ]] && { default_value="${entry#*:}"; break; }
    done
    switch_value="$(isc_hotkey_field_value "$config" "WORKSPACE_SWITCH_${index}" "$default_value")"
    [[ -n "$switch_value" ]] || continue
    switches+="${switches:+|}${index}:${switch_value}"
    move_value="$(isc_hotkey_add_modifier "$switch_value" "$modifier" 2>/dev/null || true)"
    [[ -n "$move_value" ]] && moves+="${moves:+|}${index}:${move_value}"
  done
  [[ -z "${WORKSPACE_SWITCH_BINDINGS:-}" ]] && WORKSPACE_SWITCH_BINDINGS="$switches"
  [[ -z "${WORKSPACE_MOVE_BINDINGS:-}" ]] && WORKSPACE_MOVE_BINDINGS="$moves"
}
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

append_gsettings_list() {
  local schema="$1" key="$2" value="$3" current new_value
  if ! current="$(user_gsettings get "$schema" "$key" 2>/dev/null)"; then
    log_warn "Could not read $schema $key; using an empty list before appending $value"
    current="[]"
  fi
  new_value="$(CURRENT="$current" wss_bin append "$value")"
  log_debug "Setting $schema $key to $new_value"
  user_gsettings set "$schema" "$key" "$new_value"
}

remove_gsettings_list() {
  local schema="$1" key="$2" value="$3" current new_value
  if ! current="$(user_gsettings get "$schema" "$key" 2>/dev/null)"; then
    log_warn "Could not read $schema $key; using an empty list before removing $value"
    current="[]"
  fi
  new_value="$(CURRENT="$current" wss_bin remove "$value")"
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

  # Accept the friendly "super+z" form for every configured binding by
  # normalizing each array to GNOME's "<Super>z" form. Idempotent: values
  # already in angle-bracket form pass through unchanged.
  normalize_indexed_binding_list WORKSPACE_SWITCH_BINDINGS_ARRAY
  normalize_indexed_binding_list WORKSPACE_MOVE_BINDINGS_ARRAY
}

accelerator_with_control() {
  local accelerator="$1"
  if [[ "$accelerator" == *"<Control>"* ]] || [[ "$accelerator" == *"<Ctrl>"* ]]; then
    printf '%s\n' "$accelerator"
    return 0
  fi
  printf '<Control>%s\n' "$accelerator"
}

# normalize_accelerator ACCEL - convert a friendly "super+shift+z" style
# accelerator into GNOME's gsettings "<Super><Shift>z" form. Values already in
# the angle-bracket form (containing "<"), empty values, and bare keysyms with
# no "+" separator are returned unchanged, so this is safe to apply to any
# configured binding regardless of which form the user typed.
normalize_accelerator() {
  local accel="$1"
  if [ -z "$accel" ] || [[ "$accel" == *"<"* ]] || [[ "$accel" != *"+"* ]]; then
    printf '%s\n' "$accel"
    return 0
  fi
  local -a parts
  local old_ifs="$IFS"
  IFS='+' read -r -a parts <<< "$accel"
  IFS="$old_ifs"
  local out="" token i n="${#parts[@]}"
  for ((i = 0; i < n - 1; i++)); do
    token="${parts[i]}"
    case "${token,,}" in
      super|win|cmd) out+="<Super>" ;;
      meta) out+="<Meta>" ;;
      ctrl|control) out+="<Control>" ;;
      alt) out+="<Alt>" ;;
      shift) out+="<Shift>" ;;
      hyper) out+="<Hyper>" ;;
      *) out+="<${token^}>" ;;
    esac
  done
  printf '%s%s\n' "$out" "${parts[n-1]}"
}

# normalize_indexed_binding_list ARRAY_NAME - normalize the accelerator part of
# each "prefix:accelerator" entry in place (workspace switch/move/super-arrow
# maps), leaving the prefix untouched.
normalize_indexed_binding_list() {
  local -n _arr="$1"
  local i prefix rest
  for i in "${!_arr[@]}"; do
    [[ "${_arr[i]}" == *:* ]] || continue
    prefix="${_arr[i]%%:*}"
    rest="${_arr[i]#*:}"
    _arr[i]="${prefix}:$(normalize_accelerator "$rest")"
  done
}

configure_workspace_send_extension_bindings() {
  msg "Configuring workspace send-mode key map on monitor-window-hotkeys@local"
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

# The monitor-window-hotkeys@local GNOME Shell extension (move-to-monitor,
# half-tiling, D-Bus tiling, and the Super+U send-mode itself) now lives in the
# standalone linux_monitor_window_hotkeys repository, which installs and enables
# it. This repository only *configures* the send-mode workspace key map on that
# already-installed extension (configure_workspace_send_extension_bindings),
# keeping the send-to-workspace hotkeys in sync with the user's workspace
# switch/move bindings without duplicating the extension.

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

# Installer-owned dynamic rule file read by app-rules@local at enable time.
# The master menu's [p] (persistent on all workspaces) selection is serialized
# here; while it does not exist the extension keeps its built-in legacy sticky
# fallback (Spotify + Discord), so clean installs behave as before.
APP_RULES_USER_RULES_FILE="${APP_RULES_USER_RULES_FILE:-$TARGET_HOME/.config/app-rules/user-rules.json}"

# write_app_rules_sticky_rules - Serialize the master [p] selection to the
# app-rules user-rules file.
#
# Reads SELECTED_STICKY_APPS (semicolon-separated groups of pipe-separated
# .desktop candidates for the same app) and rewrites the whole file, which is
# exclusively installer-owned. Runs only when MANAGED_STICKY_APPS is set (the
# master drove this run); a standalone run leaves any existing selection
# untouched. Writing an empty rules list is meaningful: it suppresses the
# extension's built-in sticky fallback once the menu becomes the authority.
#
# Returns: 0 always (skipped or written).
write_app_rules_sticky_rules() {
  if [[ ! ${MANAGED_STICKY_APPS+x} ]]; then
    log_debug "write_app_rules_sticky_rules: MANAGED_STICKY_APPS unset; keeping existing sticky rules"
    return 0
  fi
  msg "Writing all-workspaces (sticky) application rules"
  local group candidate ids entries=""
  local -a groups=()
  IFS=';' read -r -a groups <<<"${SELECTED_STICKY_APPS:-}"
  for group in "${groups[@]}"; do
    [ -n "$group" ] || continue
    ids=""
    for candidate in ${group//|/ }; do
      ids+="${ids:+, }\"$candidate\""
    done
    entries+="${entries:+,
    }{ \"appIds\": [$ids], \"sticky\": true }"
    log_line INFO "sticky rule selected: $group"
  done
  run_as_target mkdir -p "$(dirname "$APP_RULES_USER_RULES_FILE")"
  run_as_target tee "$APP_RULES_USER_RULES_FILE" >/dev/null <<EOF
{
  "rules": [
    ${entries}
  ]
}
EOF
  log_line INFO "wrote $APP_RULES_USER_RULES_FILE ($(( ${#groups[@]} )) selected group(s))"
}

configure_app_rules_extension() {
  msg "Deploying app-rules@local GNOME Shell extension"
  local ext_src="$CONFIG_DIR/gnome-extensions/app-rules@local"
  local ext_dst="$TARGET_HOME/.local/share/gnome-shell/extensions/app-rules@local"

  write_app_rules_sticky_rules

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
  if { [ -d "$ext_dir" ] && [ -f "$ext_dir/metadata.json" ]; } \
     || { [ -d "$system_ext_dir" ] && [ -f "$system_ext_dir/metadata.json" ]; }; then
    return 0
  fi
  # Prefer the packaged extension when it exists.
  if is_root && apt-cache show gnome-shell-extension-auto-move-windows >/dev/null 2>&1; then
    apt_install gnome-shell-extension-auto-move-windows || true
    { [ -d "$system_ext_dir" ] || [ -d "$ext_dir" ]; } && return 0
  fi
  # Ubuntu 24.04 has no separate apt package, so fall back to building it from the
  # matching gnome-shell-extensions branch (moved here from the taskbar repo so
  # workspaces_setup, the owner, can fully provision the extension on its own).
  local shell_major branch tmpdir src repo
  shell_major="$(run_as_target gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -n1 || true)"
  shell_major="${shell_major:-46}"
  branch="gnome-${shell_major}"
  apt_install git
  tmpdir="$(mktemp -d)"
  for repo in \
    "${AUTO_MOVE_WINDOWS_GIT_URL:-https://gitlab.gnome.org/GNOME/gnome-shell-extensions.git}" \
    "https://github.com/GNOME/gnome-shell-extensions.git"; do
    if git clone --depth 1 --branch "$branch" "$repo" "$tmpdir/gse" 2>/dev/null; then
      src="$tmpdir/gse/extensions/auto-move-windows"
      if [ -d "$src" ]; then
        run_as_target mkdir -p "$(dirname "$ext_dir")"
        run_as_target rm -rf "$ext_dir"
        run_as_target cp -a "$src" "$ext_dir"
        if [ ! -f "$ext_dir/metadata.json" ] && [ -f "$ext_dir/metadata.json.in" ]; then
          local metadata
          metadata="$(sed \
            -e "s|@extension_id@|auto-move-windows|g" \
            -e "s|@uuid@|$ext_id|g" \
            -e 's|@gschemaname@|org.gnome.shell.extensions.auto-move-windows|g' \
            -e 's|@gettext_domain@|gnome-shell-extensions|g' \
            -e "s|@shell_current@|$shell_major|g" \
            -e 's|@url@|https://gitlab.gnome.org/GNOME/gnome-shell-extensions|g' \
            "$ext_dir/metadata.json.in")"
          printf '%s\n' "$metadata" | run_as_target tee "$ext_dir/metadata.json" >/dev/null
        fi
        if [ -f "$ext_dir/org.gnome.shell.extensions.auto-move-windows.gschema.xml" ]; then
          run_as_target mkdir -p "$ext_dir/schemas"
          run_as_target cp "$ext_dir/org.gnome.shell.extensions.auto-move-windows.gschema.xml" "$ext_dir/schemas/"
          run_as_target glib-compile-schemas "$ext_dir/schemas"
        fi
        run_as_target chown -R "$TARGET_USER:$TARGET_USER" "$ext_dir" 2>/dev/null || true
        rm -rf "$tmpdir"
        return 0
      fi
    fi
  done
  rm -rf "$tmpdir"
  { [ -d "$ext_dir" ] || [ -d "$system_ext_dir" ]; }
}

configure_auto_move_windows() {
  msg "Configuring auto-move-windows where available"
  local ext_id="auto-move-windows@gnome-shell-extensions.gcampax.github.com"
  if ! install_auto_move_windows_extension; then
    msg "auto-move-windows is unavailable; app-rules@local handles workspace placement."
    return 0
  fi
  enable_shell_extension "$ext_id"
  if [ -f "$TARGET_HOME/.local/share/gnome-shell/extensions/$ext_id/schemas/gschemas.compiled" ]; then
    export GSETTINGS_SCHEMA_DIR="$TARGET_HOME/.local/share/gnome-shell/extensions/$ext_id/schemas"
  fi
  gsettings_key_exists org.gnome.shell.extensions.auto-move-windows application-list || return 0
  if [[ ${MANAGED_APP_WORKSPACES+x} ]]; then
    local group candidate workspace resolved number
    local -a managed_groups=() selected_groups=() candidates=()
    IFS=';' read -r -a managed_groups <<< "${MANAGED_APP_WORKSPACES:-}"
    for group in "${managed_groups[@]}"; do
      for candidate in ${group//|/ }; do
        for number in {1..9}; do
          remove_gsettings_list org.gnome.shell.extensions.auto-move-windows application-list "${candidate}:${number}"
        done
      done
    done
    IFS=';' read -r -a selected_groups <<< "${SELECTED_APP_WORKSPACES:-}"
    for group in "${selected_groups[@]}"; do
      workspace="${group##*=}"
      group="${group%=*}"
      [[ "$workspace" =~ ^[1-9]$ ]] || continue
      IFS='|' read -r -a candidates <<< "$group"
      resolved="$(first_existing_desktop "${candidates[@]}")"
      [[ -n "$resolved" ]] && append_gsettings_list org.gnome.shell.extensions.auto-move-windows application-list "${resolved}:${workspace}"
    done
  else
    local gitkraken_desktop
    gitkraken_desktop="$(first_existing_desktop gitkraken.desktop gitkraken_gitkraken.desktop)"
    [[ -n "$gitkraken_desktop" ]] && append_gsettings_list org.gnome.shell.extensions.auto-move-windows application-list "${gitkraken_desktop}:2"
  fi
}

configure_albert_keybindings() {
  msg "Configuring Albert launcher keybindings"
  local path="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/albert-aring/"
  local binding
  binding="$(normalize_accelerator "$ALBERT_TOGGLE_BINDING")"
  append_gsettings_list org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$path"
  user_gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path" name "'$ALBERT_TOGGLE_NAME'"
  user_gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path" command "'$ALBERT_TOGGLE_COMMAND'"
  user_gsettings set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:"$path" binding "'$binding'"
}

# configure_primary_paste_block - install the xmousepasteblock user service that
# locks the X11 PRIMARY selection so a middle-click does not paste. The binary is
# provided by linux_installations_setup; if it is absent the service is skipped
# rather than failing the install.
configure_primary_paste_block() {
  msg "Configuring primary clipboard lock (xmousepasteblock)"
  local bin_path="$TARGET_HOME/.local/bin/xmousepasteblock"
  local service_file="$TARGET_HOME/.config/systemd/user/xmousepasteblock.service"

  if [ ! -x "$bin_path" ]; then
    msg "xmousepasteblock binary not found at $bin_path; primary clipboard lock service skipped."
    return 0
  fi

  run_as_target mkdir -p "$(dirname "$service_file")"
  run_as_target tee "$service_file" >/dev/null <<EOF
[Unit]
Description=xmousepasteblock - lock primary clipboard selection
After=graphical-session.target

[Service]
Type=simple
ExecStart=$bin_path
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
  reload_systemd_daemon
  enable_systemd_service xmousepasteblock.service
  run_as_target systemctl --user start xmousepasteblock.service || true
}

