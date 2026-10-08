#!/usr/bin/env bash
# build_wss_tools.sh — Build the wss-tools Rust binary for installers and CI.
#
# Preference order:
#   1. Local cargo/rustc (PATH or ~/.cargo/bin) — always run incremental
#      `cargo build --release` then install into dist/wss-tools.
#   2. Existing fresh dist/wss-tools only when cargo is unavailable and sources
#      are not newer than the binary (offline / no-toolchain fallback).
#   3. Docker/Podman rust:1-bookworm image when cargo is missing.
#
# Usage:
#   bash scripts/build_wss_tools.sh           # build into dist/wss-tools
#   bash scripts/build_wss_tools.sh --print   # print path to binary (build if needed)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
BIN_NAME=wss-tools
PRINT_ONLY=0
RUST_IMAGE="${WSS_RUST_IMAGE:-rust:1-bookworm}"

log() { printf '[build_wss_tools] %s\n' "$*" >&2; }

# Print accepted builder flags to stderr.
# Parameters: none. Returns: zero.
usage() {
  cat >&2 <<'EOF'
Usage: bash scripts/build_wss_tools.sh [--bin wss-tools|app-rules-rules] [--print]

Build the requested native release binary into dist/.
With --print, also write the absolute binary path to stdout.
EOF
}

# Parse the requested native target without invoking a build.
# Parameters: $@ - raw builder flags.
# Returns: zero with BIN_NAME/PRINT_ONLY set, or usage failure.
parse_build_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --bin)
        [ $# -ge 2 ] || { usage; return 1; }
        case "$2" in wss-tools|app-rules-rules) BIN_NAME="$2" ;; *) usage; return 1 ;; esac
        shift 2 ;;
      --print) PRINT_ONLY=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) log "Unknown argument: $1"; usage; return 1 ;;
    esac
  done
}

# reclaim_build_artifacts_for_invoker — When this script runs under sudo, cargo
# writes root-owned dist/ and target/. Hand them back to SUDO_USER so a later
# non-root `bash install.sh` can rebuild without permission errors.
reclaim_build_artifacts_for_invoker() {
  local owner
  [ "$(id -u)" -eq 0 ] || return 0
  owner="${SUDO_USER:-}"
  [ -n "$owner" ] && [ "$owner" != root ] || return 0
  for path in "$DIST_DIR" "$REPO_ROOT/target" "$REPO_ROOT/.cargo-container"; do
    [ -e "$path" ] || continue
    if ! chown -R "$owner:$owner" "$path"; then
      log "ERROR: could not chown $path to $owner (sudo-built artifacts would block later non-root rebuilds)"
      return 1
    fi
  done
}

have_binary() { [ -x "$1" ]; }

sources_newer_than_dist() {
  local bin="$DIST_BIN" newest
  [ -f "$bin" ] || return 0
  newest="$(find "$REPO_ROOT/src" "$REPO_ROOT/Cargo.toml" "$REPO_ROOT/Cargo.lock" \
    -type f -newer "$bin" 2>/dev/null | head -1 || true)"
  [ -n "$newest" ]
}

dist_is_fresh() {
  have_binary "$DIST_BIN" && ! sources_newer_than_dist
}

# ensure_cargo_on_path — Prefer rustup cargo when present. When HOME is a
# sandbox (installer tests) or /root (sudo), the rustup proxy on PATH still
# needs the real user's CARGO_HOME/RUSTUP_HOME or it reports "no default
# toolchain".
ensure_cargo_on_path() {
  if [ -x "$HOME/.cargo/bin/cargo" ]; then
    # shellcheck disable=SC1091
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
    export PATH="$HOME/.cargo/bin:$PATH"
  fi
  if ! command -v cargo >/dev/null 2>&1; then
    return 1
  fi
  if [ -z "${RUSTUP_HOME:-}" ] && [ ! -d "$HOME/.rustup" ]; then
    local cargo_bin cargo_root rustup_dir
    cargo_bin="$(command -v cargo)"
    cargo_root="$(cd "$(dirname "$cargo_bin")/.." && pwd)"
    rustup_dir="$(cd "$cargo_root/../.rustup" 2>/dev/null && pwd || true)"
    if [ -d "$rustup_dir" ]; then
      export CARGO_HOME="${CARGO_HOME:-$cargo_root}"
      export RUSTUP_HOME="$rustup_dir"
      log "Using rustup toolchain at $RUSTUP_HOME (HOME has no .rustup)"
    fi
  fi
  command -v cargo >/dev/null 2>&1
}

# Build and stage the requested binary with the invoking developer toolchain.
# Parameters: none. Returns: build/install status.
build_with_cargo() {
  log "Building with local cargo…"
  (
    cd "$REPO_ROOT"
    cargo build --locked --release --bin "$BIN_NAME"
  )
  mkdir -p "$DIST_DIR"
  install -m 0755 "$TARGET_BIN" "$DIST_BIN"
}

container_engine() {
  if command -v docker >/dev/null 2>&1; then
    printf '%s\n' docker
  elif command -v podman >/dev/null 2>&1; then
    printf '%s\n' podman
  else
    return 1
  fi
}

# Build the requested binary in the established rootless container fallback.
# Parameters: none. Returns: build/install status.
build_with_container() {
  local engine
  engine="$(container_engine)" || {
    log "Neither docker nor podman is available for containerized build."
    return 1
  }
  log "Building with $engine ($RUST_IMAGE)…"
  mkdir -p "$DIST_DIR" "$REPO_ROOT/target"
  "$engine" run --rm \
    --user "$(id -u):$(id -g)" \
    -e CARGO_HOME=/src/.cargo-container \
    -e CARGO_TARGET_DIR=/src/target \
    -v "$REPO_ROOT:/src:rw" \
    -w /src \
    "$RUST_IMAGE" \
    cargo build --locked --release --bin "$BIN_NAME"
  install -m 0755 "$TARGET_BIN" "$DIST_BIN"
}

# Dispatch the existing local/container/fresh-binary build policy.
# Parameters: $@ - raw builder flags. Returns: ready binary path or exits on failure.
main() {
  parse_build_args "$@" || return 1
  DIST_BIN="$DIST_DIR/$BIN_NAME"
  TARGET_BIN="$REPO_ROOT/target/release/$BIN_NAME"
  if ensure_cargo_on_path; then
    build_with_cargo
  elif dist_is_fresh; then
    log "Using existing $DIST_BIN (cargo unavailable; sources not newer)"
  elif build_with_container; then
    :
  elif have_binary "$TARGET_BIN"; then
    if find "$REPO_ROOT/src" "$REPO_ROOT/Cargo.toml" "$REPO_ROOT/Cargo.lock" \
         -type f -newer "$TARGET_BIN" 2>/dev/null | head -1 | grep -q .; then
      log "Cannot promote stale $TARGET_BIN (sources are newer; install cargo or docker/podman)."
      exit 1
    fi
    log "WARNING: promoting existing $TARGET_BIN without rebuild (no cargo/container)"
    mkdir -p "$DIST_DIR"
    install -m 0755 "$TARGET_BIN" "$DIST_BIN"
  else
    log "Cannot build $BIN_NAME: install cargo (rustup or apt install cargo) or docker/podman."
    exit 1
  fi

  if ! have_binary "$DIST_BIN"; then
    log "Build finished but $DIST_BIN is missing or not executable."
    exit 1
  fi

  reclaim_build_artifacts_for_invoker || exit 1

  if [ "$PRINT_ONLY" -eq 1 ]; then
    printf '%s\n' "$DIST_BIN"
  else
    log "Ready: $DIST_BIN"
  fi
}

main "$@"
