#!/usr/bin/env bash
# install.sh — Ubuntu GNOME workspaces and hotkeys setup.
#
# This installer owns workspace behavior that was previously split across the
# broader desktop setup chain: monitor/window management configuration, Albert
# bindings, app
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

# Load the shared installer framework + shared install-time helpers (single
# source of truth in linux_installation_scripts_functions) BEFORE workspace_setup
# so the repo's own msg()/apt_install() (sourced next) override the shared ones.
# The shared framework owner generates this licensed support package for
# standalone use without sibling downloads.
source "$SCRIPT_DIR/.installer-support/bootstrap.sh"
isc_load_helpers

source "$SCRIPT_DIR/lib/workspace_setup.sh"
source "$SCRIPT_DIR/lib/lifecycle.sh"

# list_selected_sticky_apps - Print the .desktop ids currently configured to
# stay on all workspaces, one per line (the master menu's [p] restore source).
#
# The user-rules file is installer-owned but now also carries monitor-only
# rules, so it is parsed as JSON and only genuinely sticky rules are reported.
# While the file has never been written, the app-rules extension applies its
# built-in legacy fallback (Spotify + Discord), so report those when the
# extension is deployed.
# Parameters: none. Returns: zero with stored or legacy sticky desktop IDs.
list_selected_sticky_apps() {
  local file="${APP_RULES_USER_RULES_FILE:-$TARGET_HOME/.config/app-rules/user-rules.json}"
  if [ -f "$file" ]; then
    if ! declare -F app_rules_bin >/dev/null 2>&1; then
      source "$SCRIPT_DIR/lib/app_rules_bin.sh" || return 1
    fi
    app_rules_bin --file "$file" list-sticky 2>/dev/null || true
    return 0
  fi
  if [ -d "$TARGET_HOME/.local/share/gnome-shell/extensions/app-rules@local" ]; then
    printf 'spotify.desktop\nspotify_spotify.desktop\ndiscord.desktop\ndiscord_discord.desktop\n'
  fi
}

# list_selected_app_monitors - Print the current per-application monitor
# assignments as "pipe-separated .desktop ids<TAB>monitor number", one per line
# (the master menu's [m] restore source).
#
# Only applications the installer actually pinned are reported; every other
# application keeps the session's own placement (active-monitor-placement).
#
# Exits non-zero while no master-driven run has written the rules file. Legacy
# sticky-only files predate monitor management, so the helper overlays the
# Spotify/Discord monitor-1 defaults until a current writer records that monitor
# choices were explicitly managed. The marker then makes even an empty monitor
# list authoritative, so clearing every pin does not bring defaults back.
# Parameters: none. Returns: stored/legacy monitor choices, one when never written.
list_selected_app_monitors() {
  local file="${APP_RULES_USER_RULES_FILE:-$TARGET_HOME/.config/app-rules/user-rules.json}"
  [ -f "$file" ] || return 1
  if ! declare -F app_rules_bin >/dev/null 2>&1; then
    source "$SCRIPT_DIR/lib/app_rules_bin.sh" || return 1
  fi
  app_rules_bin --file "$file" list-monitors \
    --legacy-defaults 'spotify.desktop|spotify_spotify.desktop=1;discord.desktop|discord_discord.desktop=1' \
    2>/dev/null || true
}

list_selected_app_workspaces() {
  local schema_dir="$TARGET_HOME/.local/share/gnome-shell/extensions/auto-move-windows@gnome-shell-extensions.gcampax.github.com/schemas"
  [[ -f "$schema_dir/gschemas.compiled" ]] && export GSETTINGS_SCHEMA_DIR="$schema_dir"
  run_as_target gsettings get org.gnome.shell.extensions.auto-move-windows application-list 2>/dev/null |
    grep -oE "'[^']+:[1-9]'" | tr -d "'" || true
}

if [ -f "${WORKSPACE_BINDING_CONFIG:-$CONFIG_DIR/workspace-bindings.conf}" ] && \
   [ "${SKIP_WORKSPACE_BINDING_CONFIG:-0}" != "1" ]; then
  msg "Sourcing workspace binding config: ${WORKSPACE_BINDING_CONFIG:-$CONFIG_DIR/workspace-bindings.conf}"
  # shellcheck source=/dev/null
  . "${WORKSPACE_BINDING_CONFIG:-$CONFIG_DIR/workspace-bindings.conf}"
fi

load_hotkey_workspace_binding_config

parse_pipe_binding_entries \
  "${WORKSPACE_SWITCH_BINDINGS:-}" "|" WORKSPACE_SWITCH_BINDINGS_ARRAY DEFAULT_WORKSPACE_SWITCH_BINDINGS
parse_pipe_binding_entries \
  "${WORKSPACE_MOVE_BINDINGS:-}" "|" WORKSPACE_MOVE_BINDINGS_ARRAY DEFAULT_WORKSPACE_MOVE_BINDINGS

# Component selection runtime and this repository's component manifest. The
# manifest maps each component id to a configure_* function from
# lib/workspace_setup.sh. The framework was already resolved above (for
# isc_load_helpers); activate the component runtime from the same checkout.
isc_activate_components
source "$SCRIPT_DIR/installer/components.sh"

main() {
  msg "=== Linux Workspaces Setup ==="
  msg "Installing all configured components"
  component_main "$@"
  msg "Ubuntu workspace setup complete. Log out and back in before testing GNOME Shell extension changes."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Listing/help must print only their own output (the master installer parses
  # --list-components); bypass the surrounding messages for those.
  case "${1:-}" in
    --list-selected-app-workspaces) list_selected_app_workspaces; exit $? ;;
    --list-selected-sticky-apps) list_selected_sticky_apps; exit $? ;;
    --list-selected-app-monitors) list_selected_app_monitors; exit $? ;;
    --list-components|--export-selection|--detect|--help|-h|--uninstall|--uninstall=*) component_main "$@"; exit $? ;;
  esac
  main "$@"
fi
