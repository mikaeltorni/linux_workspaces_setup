// extension.js - app-rules@local GNOME Shell extension.
//
// Pins specific applications to fixed workspaces or makes them sticky (shown
// on all workspaces) as their windows are created. Rules are matched by
// desktop-file app id.
//
// Sticky rules are dynamic: the installer's [p] menu action writes them to
// ~/.config/app-rules/user-rules.json, which is read once per enable. When
// that file has never been written, the legacy built-in sticky fallback
// (Spotify and Discord) applies so a clean install keeps its old behavior.
//
// Components:
//   - loadUserRules: Read installer-managed rules from user-rules.json.
//   - getAppId: Resolve a window's desktop-file app id.
//   - applyRule: Move a window to a workspace and/or make it sticky.
//   - matchAndApply: Find and apply the first rule matching a window.
//   - AppRulesExtension: Extension entry point wiring up window tracking.

import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';

// Built-in workspace pins. Always active.
const RULES = [
  { appIds: ['cursor.desktop'], workspace: 0 },
  { appIds: ['gitkraken.desktop', 'gitkraken_gitkraken.desktop'], workspace: 2 },
  { appIds: ['monkeytype.desktop', 'chrome-picebhhlijnlefeleilfbanaghjlkkna-Default.desktop'], workspace: 7 },
  { appIds: ['chatgpt.desktop'], workspace: 0 },
  { appIds: ['com.obsproject.Studio.desktop', 'obs.desktop'], workspace: 7 },
];

// Legacy sticky rules, used ONLY while no user-rules.json exists. Once the
// installer writes that file (even with zero rules), it is the sole sticky
// authority, so unmarking [p] in the menu really unsticks an app.
const STICKY_FALLBACK_RULES = [
  { appIds: ['discord.desktop', 'discord_discord.desktop'], sticky: true },
  { appIds: ['spotify.desktop', 'spotify_spotify.desktop'], sticky: true },
];

/**
 * Read installer-managed rules from ~/.config/app-rules/user-rules.json.
 *
 * @returns {Array<object>|null} The parsed rules (possibly empty) when the
 *   file exists and is valid JSON of shape {rules: [...]}; null when the file
 *   is absent or unreadable, which activates STICKY_FALLBACK_RULES.
 */
function loadUserRules() {
  const path = GLib.build_filenamev([
    GLib.get_user_config_dir(), 'app-rules', 'user-rules.json',
  ]);
  try {
    const [ok, bytes] = GLib.file_get_contents(path);
    if (!ok) {
      return null;
    }
    const parsed = JSON.parse(new TextDecoder().decode(bytes));
    if (!Array.isArray(parsed.rules)) {
      console.log(`[app-rules] ${path} has no rules array; ignoring file`);
      return null;
    }
    const rules = parsed.rules.filter((rule) => Array.isArray(rule.appIds));
    console.log(`[app-rules] loaded ${rules.length} user rule(s) from ${path}`);
    return rules;
  } catch (e) {
    // Missing file is the normal pre-installer state; malformed JSON is worth
    // surfacing in the journal before falling back.
    if (!GLib.file_test(path, GLib.FileTest.EXISTS)) {
      return null;
    }
    console.log(`[app-rules] failed to read ${path}: ${e}`);
    return null;
  }
}

/**
 * Resolve the desktop-file app id for a window.
 *
 * @param {Meta.Window} win - The window to identify.
 * @returns {string|null} The app id (e.g. "spotify.desktop") or null when the
 *   window has no tracked application or lookup fails.
 */
function getAppId(win) {
  try {
    const tracker = Shell.WindowTracker.get_default();
    const app = tracker.get_window_app(win);
    return app ? app.get_id() : null;
  } catch (e) {
    return null;
  }
}

/**
 * Apply a single rule to a window: move it to a workspace and/or stick it.
 *
 * @param {Meta.Window} win - The window to act on. No-op for null or
 *   skip-taskbar (utility/override) windows.
 * @param {{workspace?: number, sticky?: boolean}} rule - The rule to apply.
 *   `workspace` is a zero-based index; `sticky` pins to all workspaces.
 * @returns {void}
 */
function applyRule(win, rule) {
  if (!win || win.skip_taskbar) {
    return;
  }

  if (rule.workspace !== undefined) {
    const targetIndex = Math.max(0, rule.workspace);
    const wsMgr = global.workspace_manager;
    if (wsMgr.n_workspaces > targetIndex) {
      const ws = wsMgr.get_workspace_by_index(targetIndex);
      if (ws) {
        win.change_workspace(ws);
      }
    }
  }

  if (rule.sticky && typeof win.stick === 'function') {
    try {
      win.stick();
    } catch (e) {
      // ignore
    }
  }
}

/**
 * Find the first rule whose app ids match the window and apply it.
 *
 * @param {Meta.Window} win - The window to match.
 * @param {Array<object>} rules - Active rules; user rules precede built-ins
 *   so an installer-managed rule wins for the same app.
 * @returns {void}
 */
function matchAndApply(win, rules) {
  const appId = (getAppId(win) || '').toLowerCase();
  if (!appId) {
    return;
  }

  for (const rule of rules) {
    if (rule.appIds.some((id) => appId === id.toLowerCase())) {
      applyRule(win, rule);
      break;
    }
  }
}

export default class AppRulesExtension extends Extension {
  enable() {
    const userRules = loadUserRules();
    this._rules = userRules === null
      ? [...RULES, ...STICKY_FALLBACK_RULES]
      : [...userRules, ...RULES];

    this._sig = global.display.connect('window-created', (_disp, win) => {
      matchAndApply(win, this._rules);
    });

    global.get_window_actors()
      .map((a) => a.meta_window)
      .forEach((w) => matchAndApply(w, this._rules));
  }

  disable() {
    if (this._sig) {
      global.display.disconnect(this._sig);
      this._sig = null;
    }
    this._rules = null;
  }
}
