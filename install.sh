#!/usr/bin/env bash
# install.sh — Ubuntu GNOME workspaces and hotkeys setup.
#
# This installer owns workspace behavior that was previously split across the
# broader desktop setup chain: numbered workspace accelerators, monitor/window
# window-management hotkeys, Ctrl+Back tiling, screenshot/Albert bindings, app
# workspace rules, and auto-move-window workspace placement.
#
# Usage:
#   bash install.sh        # user-level setup; root-only apt steps are skipped
#   sudo bash install.sh   # full setup including optional package installation

set -euo pipefail

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/configs"
RUNTIME_DIR="/run/user/${TARGET_UID}"
DISPLAY_VAL="${DISPLAY:-:0}"
USER_BUS="unix:path=${RUNTIME_DIR}/bus"
SESSION_TYPE="${XDG_SESSION_TYPE:-unknown}"

source "$SCRIPT_DIR/lib/workspace_setup.sh"

if [ -f "${WORKSPACE_BINDING_CONFIG:-$CONFIG_DIR/workspace-bindings.conf}" ] && \
   [ "${SKIP_WORKSPACE_BINDING_CONFIG:-0}" != "1" ]; then
  msg "Sourcing workspace binding config: ${WORKSPACE_BINDING_CONFIG:-$CONFIG_DIR/workspace-bindings.conf}"
  # shellcheck source=/dev/null
  . "${WORKSPACE_BINDING_CONFIG:-$CONFIG_DIR/workspace-bindings.conf}"
fi

parse_pipe_binding_entries \
  "${WORKSPACE_SWITCH_BINDINGS:-}" "|" WORKSPACE_SWITCH_BINDINGS_ARRAY DEFAULT_WORKSPACE_SWITCH_BINDINGS
parse_pipe_binding_entries \
  "${WORKSPACE_MOVE_BINDINGS:-}" "|" WORKSPACE_MOVE_BINDINGS_ARRAY DEFAULT_WORKSPACE_MOVE_BINDINGS
parse_pipe_binding_entries \
  "${SUPER_ARROW_MOVE_BINDINGS:-}" "|" SUPER_ARROW_MOVE_BINDINGS_ARRAY DEFAULT_SUPER_ARROW_MOVE_BINDINGS

main() {
  configure_ubuntu_workspaces_and_hotkeys "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
