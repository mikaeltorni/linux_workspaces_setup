#!/usr/bin/env bash
# Exercise native workspace helper owners in isolated state with desktop mocks.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/home"
printf '#!/bin/bash\nprintf attempted > "$WSS_PYTHON_SENTINEL"\nexit 95\n' > "$fixture/bin/python3"
chmod +x "$fixture/bin/python3"
export WSS_PYTHON_SENTINEL="$fixture/python-called"
export PATH="$fixture/bin:$PATH"
TARGET_HOME="$fixture/home"
SCRIPT_DIR="$ROOT"
WORKSPACE_SETUP_LOG_DIR="$fixture/log"
# Pass only target-user execution through to the actual native/file helpers.
# Parameters: $@ - target-user command. Returns: underlying status/output.
run_as_target() { "$@"; }
source "$ROOT/lib/workspace_setup.sh"
source "$ROOT/lib/lifecycle.sh"
MANAGED_STICKY_APPS=1
SELECTED_STICKY_APPS=code.desktop
MANAGED_APP_MONITORS=1
SELECTED_APP_MONITORS=code.desktop=2
write_app_rules_user_rules
[[ ! -e "$WSS_PYTHON_SENTINEL" ]]
[[ -x "$TARGET_HOME/.local/bin/app-rules-rules" ]]
eval "$(sed -n '/^list_selected_sticky_apps()/,/^}/p' "$ROOT/install.sh")"
eval "$(sed -n '/^list_selected_app_monitors()/,/^}/p' "$ROOT/install.sh")"
for round in 1 2; do
  [[ "$(list_selected_sticky_apps)" == code.desktop ]]
  [[ "$(list_selected_app_monitors)" == $'code.desktop\t2' ]]
done
# Mock only gsettings; the native filtering owner and target runner remain real.
# Parameters: $@ - requested gsettings operation. Returns: fixture values/status.
gsettings() {
  if [[ "$1" == get ]]; then printf "['keep', 'albert-aring', 'prefix-albert-aring']\n";
  else printf '%s' "$4" > "$fixture/filtered"; fi
}
ws_mediakeys_drop albert-aring
[[ "$(cat "$fixture/filtered")" == "['keep']" ]]
[[ ! -e "$WSS_PYTHON_SENTINEL" ]]
printf 'Native workspace writer/readers/filter pass in isolated state\n'
