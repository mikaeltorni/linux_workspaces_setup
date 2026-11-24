#!/usr/bin/env bash
# Verify the real deployment helper in a temporary home; no desktop calls.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_HOME="$(mktemp -d)"
trap 'rm -rf "$TARGET_HOME"' EXIT
SCRIPT_DIR="$ROOT_DIR"
CONFIG_DIR="$ROOT_DIR/configs"
source "${ISC_FUNCTIONS_DIR:-$ROOT_DIR/.installer-support}/installer_helpers.sh"
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
