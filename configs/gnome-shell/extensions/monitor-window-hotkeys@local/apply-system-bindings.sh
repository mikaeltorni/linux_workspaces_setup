#!/usr/bin/env bash
set -euo pipefail

EXT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_DIR="$EXT_DIR/schemas"
EXTENSION_UUID="monitor-window-hotkeys@local"
EXTENSION_SCHEMA="org.gnome.shell.extensions.monitor-window-hotkeys"
WM_SCHEMA="org.gnome.desktop.wm.keybindings"
TILING_SCHEMA="org.gnome.shell.extensions.tiling-assistant"
WM_MOUSE_BUTTON_MODIFIER="<Super>"

WM_BINDINGS=(
  "toggle-maximized:<Alt><Super>E"
)

WM_UNBINDINGS=(
  "minimize:<Alt><Super>R"
  "maximize:<Super>Up"
  "unmaximize:<Super>Down"
  "minimize:<Super>Down"
)

TILING_UNBINDINGS=(
  "tile-maximize:<Super>Up"
  "tile-top-half:<Control><Super>X"
  "tile-top-half:<Super>Up"
  "tile-bottom-half:<Control><Super>W"
  "tile-bottom-half:<Super>Down"
  "tile-left-half:<Control><Super>C"
  "tile-left-half:<Super>Left"
  "tile-right-half:<Super>Right"
)

schema_exists() {
  gsettings list-schemas | grep -qx "$1"
}

extension_schema_exists() {
  gsettings --schemadir "$SCHEMA_DIR" list-schemas 2>/dev/null | grep -qx "$EXTENSION_SCHEMA"
}

compile_extension_schema() {
  if ! command -v glib-compile-schemas >/dev/null 2>&1; then
    printf 'ERROR: glib-compile-schemas not found; install libglib2.0-bin\n' >&2
    return 1
  fi
  glib-compile-schemas "$SCHEMA_DIR"
}

extension_gsettings() {
  gsettings --schemadir "$SCHEMA_DIR" "$@"
}

append_strv_value() {
  local schema="$1"
  local key="$2"
  local value="$3"
  local current new_value

  current="$(gsettings get "$schema" "$key" 2>/dev/null || printf '[]')"
  new_value="$(CURRENT="$current" VALUE="$value" python3 - <<'PY'
import ast
import os

raw = os.environ.get("CURRENT", "").strip()
if raw.startswith("@as "):
    raw = raw[4:].strip()

try:
    current = ast.literal_eval(raw) if raw else []
except Exception:
    current = []

if not isinstance(current, list):
    current = []

current = list(dict.fromkeys(str(item) for item in current))
value = os.environ.get("VALUE", "")
if value and value not in current:
    current.append(value)

print("[" + ", ".join(repr(str(item)) for item in current) + "]")
PY
)"
  gsettings set "$schema" "$key" "$new_value"
}

remove_strv_value() {
  local schema="$1"
  local key="$2"
  local value="$3"
  local current new_value

  current="$(gsettings get "$schema" "$key" 2>/dev/null || printf '[]')"
  new_value="$(CURRENT="$current" VALUE="$value" python3 - <<'PY'
import ast
import os

raw = os.environ.get("CURRENT", "").strip()
if raw.startswith("@as "):
    raw = raw[4:].strip()

try:
    current = ast.literal_eval(raw) if raw else []
except Exception:
    current = []

if not isinstance(current, list):
    current = []

value = os.environ.get("VALUE", "")
current = [str(item) for item in current if str(item) != value]

print("[" + ", ".join(repr(str(item)) for item in current) + "]")
PY
)"
  gsettings set "$schema" "$key" "$new_value"
}

ensure_enabled_extension() {
  append_strv_value org.gnome.shell enabled-extensions "$EXTENSION_UUID"
}

reset_extension_bindings_to_schema_defaults() {
  extension_gsettings reset-recursively "$EXTENSION_SCHEMA"
}

apply_binding_entries() {
  local schema="$1"
  shift

  local entry key value
  for entry in "$@"; do
    key="${entry%%:*}"
    value="${entry#*:}"
    append_strv_value "$schema" "$key" "$value"
  done
}

remove_binding_entries() {
  local schema="$1"
  shift

  local entry key value
  for entry in "$@"; do
    key="${entry%%:*}"
    value="${entry#*:}"
    remove_strv_value "$schema" "$key" "$value"
  done
}

compile_extension_schema

if ! extension_schema_exists; then
  printf 'ERROR: extension schema %s not found under %s\n' "$EXTENSION_SCHEMA" "$SCHEMA_DIR" >&2
  exit 1
fi

reset_extension_bindings_to_schema_defaults

remove_binding_entries "$WM_SCHEMA" "${WM_UNBINDINGS[@]}"
apply_binding_entries "$WM_SCHEMA" "${WM_BINDINGS[@]}"
gsettings set org.gnome.desktop.wm.preferences mouse-button-modifier "'$WM_MOUSE_BUTTON_MODIFIER'"
gsettings set org.gnome.desktop.wm.preferences resize-with-right-button true

if schema_exists "$TILING_SCHEMA"; then
  gsettings set "$TILING_SCHEMA" enable-tiling-popup false
  remove_binding_entries "$TILING_SCHEMA" "${TILING_UNBINDINGS[@]}"
else
  printf 'Tiling Assistant settings schema not found; skipping conflicting binding cleanup.\n'
fi

ensure_enabled_extension
  append_strv_value org.gnome.shell enabled-extensions "tiling-assistant@ubuntu.com"

printf 'Applied monitor/window hotkeys. Log out and back in if GNOME Shell has not loaded the extension yet.\n'
