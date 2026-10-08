#!/usr/bin/env bash
# Resolve native app-rule helpers and install write commands for the target user.

# Locate or build the app-rule executable using the invoker's Rust toolchain.
# Parameters: none.
# Returns: zero and exports APP_RULES_BIN, or builder failure.
ensure_app_rules_bin() {
  local root bin
  root="${WORKSPACE_SETUP_DIR:-${SCRIPT_DIR:?SCRIPT_DIR unset}}"
  if [[ -n "${APP_RULES_BIN:-}" && -x "$APP_RULES_BIN" ]]; then return 0; fi
  bin="$(bash "$root/scripts/build_wss_tools.sh" --bin app-rules-rules --print)" || return 1
  APP_RULES_BIN="$bin"
  export APP_RULES_BIN
}

# Invoke an app-rule reader without compiling under the target user's home.
# Parameters: $@ - native command arguments.
# Returns: helper output/status, or native resolver failure.
app_rules_bin() {
  ensure_app_rules_bin || return 1
  "$APP_RULES_BIN" "$@"
}

# Install the native writer into the target home using its execution boundary.
# Parameters: none.
# Returns: zero and exports APP_RULES_TARGET_BIN, or install failure.
install_app_rules_bin() {
  ensure_app_rules_bin || return 1
  APP_RULES_TARGET_BIN="$TARGET_HOME/.local/bin/app-rules-rules"
  run_as_target install -D -m 0755 "$APP_RULES_BIN" "$APP_RULES_TARGET_BIN" || return 1
  export APP_RULES_TARGET_BIN
}
