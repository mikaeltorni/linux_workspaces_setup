#!/usr/bin/env bash
# components.sh - Component manifest for linux_workspaces_setup.
#
# Maps each selectable workspace component to the function (defined in
# lib/workspace_setup.sh) that applies it. install.sh sources that library and
# parses the binding arrays first, then this manifest, then routes execution
# through component_main from component_runtime.sh.
#
# Entry format: "id|label|default(on/off)|function".

ISC_REPO_NAME="linux_workspaces_setup"
ISC_REPO_LABEL="GNOME workspaces and hotkeys"

# select_input_device picks the keyboard device for the Ctrl+Back tiler; the
# sudo-required summary is reported afterwards.
ISC_PREFLIGHT="select_input_device"
ISC_POSTFLIGHT="report_sudo_required"

ISC_COMPONENTS=(
  "screenshot|Screenshot shortcuts|on|configure_screenshot_binding"
  "workspace_keys|Numbered workspace switch/move keys|on|configure_workspace_keys"
  "albert|Albert launcher toggle binding|on|configure_albert_keybindings"
  "monitor_window_hotkeys|Monitor/window movement hotkeys extension|on|configure_monitor_window_hotkeys_extension"
  "automatic_window_tiling|Automatic same-app window tiling|on|configure_automatic_window_tiling"
  "ctrl_back_tiler|Ctrl+Back window tiler service|on|configure_ctrl_back_window_tiler_service"
  "workspace_popup|Numbered workspace popup extension|on|configure_workspace_number_popup_extension"
  "app_rules|App-to-workspace window rules extension|on|configure_app_rules_extension"
  "auto_move_windows|Auto-move-windows workspace placement|on|configure_auto_move_windows"
  "primary_paste_block|Block middle-click primary paste|on|configure_primary_paste_block"
)
