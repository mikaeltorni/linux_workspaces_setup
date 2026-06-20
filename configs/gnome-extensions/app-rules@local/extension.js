// extension.js - app-rules@local GNOME Shell extension.
//
// Pins specific applications to fixed workspaces or makes them sticky as their
// windows are created. Rules are matched by desktop-file app id.
//
// Components:
//   - getAppId: Resolve a window's desktop-file app id.
//   - applyRule: Move a window to a workspace and/or make it sticky.
//   - matchAndApply: Find and apply the first rule matching a window.
//   - AppRulesExtension: Extension entry point wiring up window tracking.

import Shell from 'gi://Shell';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';

const RULES = [
  { appIds: ['cursor.desktop'], workspace: 0 },
  { appIds: ['gitkraken.desktop', 'gitkraken_gitkraken.desktop'], workspace: 2 },
  { appIds: ['monkeytype.desktop', 'chrome-picebhhlijnlefeleilfbanaghjlkkna-Default.desktop'], workspace: 7 },
  { appIds: ['chatgpt.desktop'], workspace: 0 },
  { appIds: ['com.obsproject.Studio.desktop', 'obs.desktop'], workspace: 7 },
  { appIds: ['discord_discord.desktop'], sticky: true },
  { appIds: ['spotify.desktop', 'spotify_spotify.desktop'], sticky: true },
];

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
 * @param {Meta.Window} win - The window to match against {@link RULES}.
 * @returns {void}
 */
function matchAndApply(win) {
  const appId = (getAppId(win) || '').toLowerCase();
  if (!appId) {
    return;
  }

  for (const rule of RULES) {
    if (rule.appIds.some((id) => appId === id.toLowerCase())) {
      applyRule(win, rule);
      break;
    }
  }
}

export default class AppRulesExtension extends Extension {
  enable() {
    this._sig = global.display.connect('window-created', (_disp, win) => {
      matchAndApply(win);
    });

    global.get_window_actors()
      .map((a) => a.meta_window)
      .forEach((w) => matchAndApply(w));
  }

  disable() {
    if (this._sig) {
      global.display.disconnect(this._sig);
      this._sig = null;
    }
  }
}
