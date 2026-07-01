#!/usr/bin/env bash
# install.sh — Ubuntu GNOME workspaces and hotkeys setup.
#
# This installer owns workspace behavior that was previously split across the
# broader desktop setup chain: monitor/window management hotkeys, Ctrl+Back
# tiling, Albert bindings, app
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
# No vendored copy: resolve a sibling checkout or download on demand.
for __isc_d in "${ISC_FUNCTIONS_DIR:-}" \
               "$SCRIPT_DIR/../linux_installation_scripts_functions" \
               "$HOME/projects/linux_installation_scripts_functions"; do
  [ -n "$__isc_d" ] && [ -f "$__isc_d/component_loader.sh" ] && { source "$__isc_d/component_loader.sh"; break; }
done
declare -F isc_load_helpers >/dev/null 2>&1 || \
  source <(curl -fsSL "https://raw.githubusercontent.com/mikaeltorni/linux_installation_scripts_functions/${ISC_FUNCTIONS_REF:-master}/component_loader.sh")
isc_load_helpers

source "$SCRIPT_DIR/lib/workspace_setup.sh"
source "$SCRIPT_DIR/lib/lifecycle.sh"

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
  
  # Feature-specific installation support (--features=feature1,feature2,...)
  SELECTED_FEATURES="${FEATURES:-}"
  
  if [ -n "$SELECTED_FEATURES" ]; then
    IFS="," read -ra FEATURE_ARRAY <<< "$SELECTED_FEATURES"
    msg "Feature filter active: ${FEATURE_ARRAY[*]}"
    
    local select_arg=""
    for arg in "$@"; do
      if [[ "${arg}" == --select=* ]]; then  
        local selected_components="${arg#--select=}"
        local filtered="" first=true
        
        for comp_id in ${selected_components}; do
          for feature in "${FEATURE_ARRAY[@]}"; do  
            if [ "$comp_id" = "$feature" ]; then
              if $first; then filtered="$comp_id"; first=false; else filtered="$filtered,$comp_id"; fi
              break
            fi  
          done  
        done
        
        select_arg="--select=$filtered"
        break
      fi
    done
    
    # If no specific --select, use feature list directly as component IDs  
    if [ -z "$select_arg" ]; then
      local features_as_components="" first=true
      for feature in "${FEATURE_ARRAY[@]}"; do
        if $first; then features_as_components="$feature"; first=false; else features_as_components="$features_as_components,$feature"; fi
      done  
      select_arg="--select=$features_as_components"
    fi
    
    component_main "$select_arg"
  else
    msg "Installing all configured components"
    component_main "$@"  
  fi
  
  msg "Ubuntu workspace setup complete. Log out and back in before testing GNOME Shell extension changes."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Listing/help must print only their own output (the master installer parses
  # --list-components); bypass the surrounding messages for those.
  case "${1:-}" in
    --list-selected-app-workspaces) list_selected_app_workspaces; exit $? ;;
    --list-components|--detect|--help|-h|--uninstall|--uninstall=*) component_main "$@"; exit $? ;;
  esac
  main "$@"
fi
