// extension.js - app-rules@local GNOME Shell extension.
//
// Pins specific applications to fixed workspaces, to a fixed display monitor,
// or makes them sticky (shown on all workspaces) as their windows are created.
// Rules are matched by desktop-file app id.
//
// Sticky and monitor rules are dynamic: the installer's [p] and [m] menu
// actions write them to ~/.config/app-rules/user-rules.json, which is read once
// per enable. When that file has never been written, the legacy built-in sticky
// fallback (Spotify and Discord) applies so a clean install keeps its old
// behavior.
//
// Monitor rules carry the installer's 1-based monitor number (the same number
// the GNOME Settings -> Displays panel shows) plus the connector and logical
// geometry that number referred to at install time. Geometry is matched first
// so the rule survives Mutter renumbering its monitors; the stored number is
// only a fallback. A rule that resolves to nothing is dropped rather than
// guessed, leaving the window where the session put it.
// Workspace rules likewise carry the 1-based number shown by GNOME and are
// converted to Mutter's zero-based index only at the move boundary.
//
// Placement is retried briefly after create: Mutter frequently assigns the
// final monitor after the first map, and moving an unmapped or
// monitor-less window can crash the Shell.
//
// Components:
//   - loadUserRules: Read installer-managed rules from user-rules.json.
//   - getAppId: Resolve a window's desktop-file app id.
//   - workspaceIndexForRule: Convert visible workspace numbers to Meta indexes.
//   - resolveRuleMonitor: Map a rule's monitor number/geometry to a Meta index.
//   - monitorMovePolicy: Lifecycle-safe gate before Mutter move APIs.
//   - applyMonitor: Move a mapped window onto its assigned monitor.
//   - applyRule: Move a window to a workspace/monitor and/or make it sticky.
//   - matchAndApply: Find and apply the first rule matching a window.
//   - AppRulesExtension: Extension entry point wiring up window tracking.

import GLib from 'gi://GLib';
import Shell from 'gi://Shell';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import { isWindowMoveSafe } from './monitorMovePolicy.js';
import { workspaceIndexForRule } from './workspacePolicy.js';

const RECHECK_INTERVAL_MS = 100;
const MAX_RECHECKS = 50;

// Built-in workspace pins. Always active.
const RULES = [
  { appIds: ['cursor.desktop'], wmClasses: ['cursor'], workspace: 1, monitor: 'primary' },
  { appIds: ['gitkraken.desktop', 'gitkraken_gitkraken.desktop'], workspace: 3, monitor: 2 },
  { appIds: ['smartgit.desktop'], workspace: 3, monitor: 3, wmClasses: ['smartgit'] },
  { appIds: ['monkeytype.desktop', 'chrome-picebhhlijnlefeleilfbanaghjlkkna-Default.desktop'], wmClasses: ['crx_picebhhlijnlefeleilfbanaghjlkkna'], workspace: 8, monitor: 'primary' },
  { appIds: ['chatgpt.desktop'], workspace: 1 },
  { appIds: ['com.obsproject.Studio.desktop', 'obs.desktop'], workspace: 8 },
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
 * Resolve the Meta monitor index a rule refers to.
 *
 * Geometry is authoritative: Mutter's monitor indices are not guaranteed to
 * keep the order the installer saw, but the logical position of a screen is
 * what the user actually pointed at in the Displays panel. The stored 1-based
 * number is used only when geometry cannot be matched (rules written before
 * geometry was recorded, or a layout the user has since changed).
 *
 * @param {{monitor?: number, monitorGeometry?: {x: number, y: number,
 *   width: number, height: number}}} rule - Rule to resolve.
 * @returns {number} Zero-based Meta monitor index, or -1 when the rule cannot
 *   be resolved (caller then leaves the window alone).
 */
function resolveRuleMonitor(rule) {
  const display = global.display;
  const count = typeof display.get_n_monitors === 'function'
    ? display.get_n_monitors()
    : 0;
  if (count <= 0) {
    return -1;
  }

  if (rule.monitor === 'primary') {
    const primary = display.get_primary_monitor();
    return Number.isInteger(primary) && primary >= 0 && primary < count ? primary : -1;
  }
  const wanted = rule.monitorGeometry;
  if (wanted && Number.isFinite(wanted.x) && Number.isFinite(wanted.y)) {
    let positionMatch = -1;
    for (let index = 0; index < count; index += 1) {
      let geometry = null;
      try {
        geometry = display.get_monitor_geometry(index);
      } catch (e) {
        geometry = null;
      }
      if (!geometry || geometry.x !== wanted.x || geometry.y !== wanted.y) {
        continue;
      }
      // Same corner and same size: an unambiguous match.
      if (geometry.width === wanted.width && geometry.height === wanted.height) {
        return index;
      }
      if (positionMatch < 0) {
        positionMatch = index;
      }
    }
    // Same corner, different resolution (mode changed) still identifies it.
    if (positionMatch >= 0) {
      return positionMatch;
    }
  }

  const number = Number(rule.monitor);
  if (Number.isInteger(number) && number >= 1 && number <= count) {
    return number - 1;
  }
  return -1;
}

/** Move a mapped window to the resolved monitor without changing maximization. */
function applyMonitor(win, rule) {
  const target = resolveRuleMonitor(rule);
  if (target < 0) {
    console.log('[app-rules] no monitor matches rule; leaving window alone');
    return;
  }
  if (!isWindowReady(win) || win.get_monitor() === target) return;
  try {
    win.move_to_monitor(target);
    console.log(`[app-rules] moved ${getAppId(win) || 'window'} to monitor index ${target}`);
  } catch (error) {
    console.log(`[app-rules] monitor move failed: ${error}`);
  }
}

/** Check mapped actor and source bounds immediately before native window moves. */
function isWindowReady(win) {
  return isWindowMoveSafe(win) && win.get_monitor() < global.display.get_n_monitors();
}

/**
 * Apply a single rule to a window: move it to a workspace and/or stick it.
 *
 * @param {Meta.Window} win - The window to act on. No-op for null or
 *   skip-taskbar (utility/override) windows.
 * @param {{workspace?: number, sticky?: boolean, monitor?: number}} rule - The
 *   rule to apply. `workspace` is the visible one-based number; `sticky` pins
 *   to all workspaces; `monitor` is the installer's 1-based display number.
 * @returns {void}
 */
function applyRule(win, rule) {
  if (!win || win.skip_taskbar || !isWindowReady(win)) {
    return;
  }

  // Placement is independent of the user's all-workspaces preference.
  // Mutter workspace changes can clear it, so restore it even after a failure.
  const keepSticky = Boolean(rule.sticky || win.is_on_all_workspaces?.());
  try {
    if (rule.monitor !== undefined && rule.monitor !== null && rule.monitor !== 0) {
      applyMonitor(win, rule);
    }

    if (rule.workspace !== undefined) {
      const targetIndex = workspaceIndexForRule(rule.workspace);
      if (targetIndex < 0) {
        console.log(`[app-rules] invalid workspace number ${JSON.stringify(rule.workspace)}; ignoring workspace move`);
      } else {
        const wsMgr = global.workspace_manager;
        if (wsMgr.n_workspaces > targetIndex) {
          const ws = wsMgr.get_workspace_by_index(targetIndex);
          if (ws) {
            win.change_workspace(ws);
          }
        }
      }
    }
  } finally {
    if (keepSticky && typeof win.stick === 'function') {
      try {
        win.stick();
        console.log(`[app-rules] preserved all-workspaces for ${getAppId(win) || 'window'}`);
      } catch (error) {
        console.log(`[app-rules] failed to preserve all-workspaces: ${error}`);
      }
    }
  }

}

/**
 * Find the first rule whose app ids match the window and apply it.
 *
 * @param {Meta.Window} win - The window to match.
 * @param {Array<object>} rules - Active rules; user rules precede built-ins
 *   so an installer-managed rule wins for the same app.
 * @returns {boolean} False while the application identity is unavailable.
 */
function matchAndApply(win, rules) {
  let appId = (getAppId(win) || '').toLowerCase();
  const classes = [win.get_wm_class?.(), win.get_wm_class_instance?.()]
    .filter(value => typeof value === 'string').map(value => value.toLowerCase());
  // Infer the canonical id from a known class before searching user rules,
  // so a late desktop-file association cannot bypass saved monitor choices.
  if (!appId) {
    const known = rules.find(rule => rule.wmClasses?.some(id => classes.includes(id.toLowerCase())));
    appId = known?.appIds[0]?.toLowerCase() || '';
  }
  if (!appId && classes.length === 0) return false;

  for (const rule of rules) {
    if (rule.appIds.some((id) => appId === id.toLowerCase()) ||
        rule.wmClasses?.some(id => classes.includes(id.toLowerCase()))) {
      applyRule(win, rule);
      return true;
    }
  }
  return Boolean(appId);
}

export default class AppRulesExtension extends Extension {
  enable() {
    const userRules = loadUserRules();
    this._rules = userRules === null
      ? [...RULES, ...STICKY_FALLBACK_RULES]
      : [...userRules, ...RULES, ...STICKY_FALLBACK_RULES];
    this._pending = new Map();

    this._sig = global.display.connect('window-created', (_disp, win) => {
      this._schedule(win);
    });

    global.get_window_actors()
      .map((a) => a.meta_window)
      .forEach((w) => this._schedule(w));
    console.log('[app-rules] enabled; waiting for mapped windows before applying rules');
  }

  /** Defer new/existing windows until mapped, with a bounded identity retry. */
  _schedule(win) {
    if (!win || win.skip_taskbar || this._pending.has(win)) return;
    const pending = {sourceId: 0, unmanagedId: 0, attempts: 0};
    this._pending.set(win, pending);
    pending.unmanagedId = win.connect('unmanaged', () => this._cancel(win));
    pending.sourceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, RECHECK_INTERVAL_MS, () => {
      pending.attempts++;
      let done = false;
      try {
        done = win.skip_taskbar || (isWindowReady(win) && matchAndApply(win, this._rules));
      } catch (error) {
        console.log(`[app-rules] deferred rule application failed: ${error}`);
        done = true;
      }
      if (!done && pending.attempts < MAX_RECHECKS) return GLib.SOURCE_CONTINUE;
      if (!done) console.log('[app-rules] stopped waiting for window mapping or application identity');
      pending.sourceId = 0; // This callback removes its own source on return.
      this._cancel(win);
      return GLib.SOURCE_REMOVE;
    });
  }

  /** Cancel work before a window is unmanaged or the extension is disabled. */
  _cancel(win) {
    const pending = this._pending.get(win);
    if (!pending) return;
    if (pending.sourceId) GLib.source_remove(pending.sourceId);
    if (pending.unmanagedId) win.disconnect(pending.unmanagedId);
    this._pending.delete(win);
  }

  disable() {
    if (this._sig) {
      global.display.disconnect(this._sig);
      this._sig = null;
    }
    for (const win of this._pending.keys()) this._cancel(win);
    this._rules = null;
    console.log('[app-rules] disabled; pending window rules cancelled');
  }
}
