#!/usr/bin/env bash
# wss_bin.sh — Resolve and invoke the wss-tools Rust helper.
#
# Sourced by install.sh after SCRIPT_DIR is set. Builds the binary on demand
# via scripts/build_wss_tools.sh.
#
# Public functions:
#   ensure_wss_bin  — build/locate dist/wss-tools; sets WSS_BIN
#   wss_bin         — ensure_wss_bin then run it with "$@"

# ensure_wss_bin — Locate or build dist/wss-tools; export WSS_BIN.
ensure_wss_bin() {
  local build_script bin
  build_script="${SCRIPT_DIR:-${WORKSPACE_SETUP_DIR:?SCRIPT_DIR unset}}/scripts/build_wss_tools.sh"
  if [ -n "${WSS_BIN:-}" ] && [ -x "$WSS_BIN" ]; then
    return 0
  fi
  if [ ! -x "$build_script" ]; then
    if declare -F msg >/dev/null 2>&1; then
      msg "Missing build helper: $build_script"
    else
      printf 'Missing build helper: %s\n' "$build_script" >&2
    fi
    return 1
  fi
  bin="$(bash "$build_script" --print)" || return 1
  WSS_BIN="$bin"
  export WSS_BIN
}

# wss_bin — Run the helper CLI.
wss_bin() {
  ensure_wss_bin || return 1
  "$WSS_BIN" "$@"
}
