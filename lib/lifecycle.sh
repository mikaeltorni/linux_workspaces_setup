#!/usr/bin/env bash
# lifecycle.sh - Detection and uninstall functions for linux_workspaces_setup.
#
# detect_* report live state for --detect; uninstall_* reset keybindings,
# disable+remove bundled GNOME extensions, reset the auto-move list, or
# disable+remove user services. Delegated components reverse via the sibling
# repository's own --uninstall.

ws_ext_dir() { printf '%s\n' "$TARGET_HOME/.local/share/gnome-shell/extensions/$1"; }
ws_remove_extension() {
  run_as_target gnome-extensions disable "$1" 2>/dev/null || true
  run_as_target rm -rf "$(ws_ext_dir "$1")"
}
ws_mediakeys_has() {
  run_as_target gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null | grep -q "$1"
}
ws_mediakeys_drop() {
  local frag="$1" current
  current="$(run_as_target gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings 2>/dev/null || printf '[]')"
  RMF="$frag" python3 - "$current" <<'PY' >/tmp/.ws_filtered 2>/dev/null || true
import ast,os,sys
raw=sys.argv[1].strip() or "[]"
try:
  items=ast.literal_eval(raw); items=items if isinstance(items,list) else []
except Exception: items=[]
print("["+", ".join("'"+p+"'" for p in items if os.environ["RMF"] not in p)+"]")
PY
  run_as_target gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$(cat /tmp/.ws_filtered)" 2>/dev/null || true
  rm -f /tmp/.ws_filtered
}
ws_delegate() {
  local dir="$TARGET_HOME/projects/$1"
  [ -f "$dir/install.sh" ] && run_as_target bash "$dir/install.sh" "${@:2}" || true
}

# --- Detection ---------------------------------------------------------------
detect_albert()                  { ws_mediakeys_has 'albert-aring'; }
# Send-mode config only has effect when the monitor-window-hotkeys@local
# extension (owned by linux_monitor_window_hotkeys) is installed, so detection
# keys off the extension's presence.
detect_workspace_send_mode()     { [ -d "$(ws_ext_dir monitor-window-hotkeys@local)" ]; }
detect_automatic_window_tiling() { [ -d "$(ws_ext_dir automatic-window-tiling@local)" ]; }
detect_ctrl_back_tiler()         { [ -f "$TARGET_HOME/.config/systemd/user/ctrl-back-window-tiler.service" ]; }
detect_workspace_popup()         { [ -d "$(ws_ext_dir workspace-number-indicator@local)" ]; }
detect_app_rules()               { [ -d "$(ws_ext_dir app-rules@local)" ]; }
detect_auto_move_windows() {
  local v
  v="$(run_as_target gsettings get org.gnome.shell.extensions.auto-move-windows application-list 2>/dev/null)" &&
    [ -n "$v" ] && [ "$v" != "@as []" ] && [ "$v" != "[]" ] && return 0
  [ -d "$(ws_ext_dir app-rules@local)" ]
}
detect_primary_paste_block()     { [ -f "$TARGET_HOME/.config/systemd/user/xmousepasteblock.service" ]; }

# --- Uninstall ---------------------------------------------------------------
uninstall_albert()                 { msg "Removing Albert toggle shortcut"; ws_mediakeys_drop 'albert-aring'; }
# Reset only the send-mode key map to schema defaults; the extension itself is
# owned and removed by linux_monitor_window_hotkeys, not here.
uninstall_workspace_send_mode() {
  msg "Resetting workspace send-mode key map to defaults"
  local key
  for key in send-mode-workspace-bindings send-active-window-to-workspace-1 \
             send-active-window-to-workspace-2 send-active-window-to-workspace-3 \
             send-active-window-to-workspace-4 send-active-window-to-workspace-5 \
             send-active-window-to-workspace-6 send-active-window-to-workspace-7 \
             send-active-window-to-workspace-8; do
    extension_gsettings reset org.gnome.shell.extensions.monitor-window-hotkeys "$key" 2>/dev/null || true
  done
}
uninstall_automatic_window_tiling(){ msg "Uninstalling automatic window tiling (delegated)"; ws_delegate linux_automatic_window_tiling --uninstall keybinding,per_app_widths,portrait_stacking; }
uninstall_ctrl_back_tiler() {
  msg "Removing Ctrl+Back window tiler service"
  run_as_target systemctl --user disable --now ctrl-back-window-tiler.service 2>/dev/null || true
  run_as_target rm -f "$TARGET_HOME/.config/systemd/user/ctrl-back-window-tiler.service"
  run_as_target rm -f \
    "$TARGET_HOME/.local/bin/wss-tools" \
    "$TARGET_HOME/.local/bin/ctrl_back_tile_right.py" \
    "$TARGET_HOME/.local/bin/ctrl_back_event_state.py" \
    "$TARGET_HOME/.local/bin/input_device_paths.py" \
    "$TARGET_HOME/.local/bin/tile_right_client.py" \
    "$TARGET_HOME/.local/bin/logging_setup.py"
  run_as_target systemctl --user daemon-reload 2>/dev/null || true
}
uninstall_workspace_popup() { msg "Removing numbered workspace popup extension"; ws_remove_extension workspace-number-indicator@local; }
uninstall_app_rules()       { msg "Removing app-rules extension"; ws_remove_extension app-rules@local; }
uninstall_auto_move_windows() { msg "Resetting auto-move-windows placement"; run_as_target gsettings reset org.gnome.shell.extensions.auto-move-windows application-list 2>/dev/null || true; }
uninstall_primary_paste_block() {
  msg "Removing middle-click paste block service"
  run_as_target systemctl --user disable --now xmousepasteblock.service 2>/dev/null || true
  run_as_target rm -f "$TARGET_HOME/.config/systemd/user/xmousepasteblock.service"
  run_as_target systemctl --user daemon-reload 2>/dev/null || true
}
