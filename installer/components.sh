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
  "albert|Albert launcher toggle binding|on|configure_albert_keybindings|detect_albert|uninstall_albert"
  "workspace_send_mode|Send active window to workspace (Super+U key map)|on|configure_workspace_send_extension_bindings|detect_workspace_send_mode|uninstall_workspace_send_mode"
  "automatic_window_tiling|Automatic same-app window tiling|on|configure_automatic_window_tiling|detect_automatic_window_tiling|uninstall_automatic_window_tiling"
  "ctrl_back_tiler|Ctrl+Back window tiler service|on|configure_ctrl_back_window_tiler_service|detect_ctrl_back_tiler|uninstall_ctrl_back_tiler"
  "workspace_popup|Numbered workspace popup extension|on|configure_workspace_number_popup_extension|detect_workspace_popup|uninstall_workspace_popup"
  "app_rules|App-to-workspace window rules extension|on|configure_app_rules_extension|detect_app_rules|uninstall_app_rules"
  "auto_move_windows|Auto-move-windows workspace placement|on|configure_auto_move_windows|detect_auto_move_windows|uninstall_auto_move_windows"
  "primary_paste_block|Block middle-click primary paste|on|configure_primary_paste_block|detect_primary_paste_block|uninstall_primary_paste_block"
)
