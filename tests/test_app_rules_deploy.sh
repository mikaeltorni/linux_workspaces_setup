#!/usr/bin/env bash
# Verify the real deployment helper in a temporary home; no desktop calls.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_HOME="$(mktemp -d)"
trap 'rm -rf "$TARGET_HOME"' EXIT
SCRIPT_DIR="$ROOT_DIR"
CONFIG_DIR="$ROOT_DIR/configs"
for candidate in "${ISC_FUNCTIONS_DIR:-}" "$ROOT_DIR/../linux_installation_scripts_functions" "$HOME/projects/linux_installation_scripts_functions"; do
  if [ -n "$candidate" ] && [ -f "$candidate/installer_helpers.sh" ]; then
    source "$candidate/installer_helpers.sh"
    break
  fi
done
declare -F run_as_target >/dev/null || { echo 'Set ISC_FUNCTIONS_DIR to the shared framework checkout' >&2; exit 1; }
source "$ROOT_DIR/lib/workspace_setup.sh"
# Inject desktop/process boundaries only; exercise the real file copy path.
run_as_target() { "$@"; }
is_root() { return 1; }
enable_shell_extension() { [[ "$1" == app-rules@local ]]; }
mkdir -p "$TARGET_HOME/.config/app-rules"
printf '{"rules":[{"appIds":["cursor.desktop"],"monitor":2}]}\n' > "$APP_RULES_USER_RULES_FILE"
cp "$APP_RULES_USER_RULES_FILE" "$TARGET_HOME/expected.json"
configure_app_rules_extension
configure_app_rules_extension
cmp "$APP_RULES_USER_RULES_FILE" "$TARGET_HOME/expected.json"
for file in extension.js metadata.json workspacePolicy.js monitorMovePolicy.js; do
  cmp "$CONFIG_DIR/gnome-extensions/app-rules@local/$file" "$TARGET_HOME/.local/share/gnome-shell/extensions/app-rules@local/$file"
done
printf 'PASS: clean-home deployment is complete, idempotent, and preserves rules\n'
