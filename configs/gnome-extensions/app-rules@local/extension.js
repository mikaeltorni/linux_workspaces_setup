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
//   - isWindowMoveSafe: Mapped + valid-monitor gate before Mutter move APIs.
//   - applyMonitor: Move a window onto its assigned monitor (retried).
//   - applyRule: Move a window to a workspace/monitor and/or make it sticky.
//   - matchAndApply: Find and apply the first rule matching a window.
//   - AppRulesExtension: Extension entry point wiring up window tracking.

import GLib from 'gi://GLib';
import Meta from 'gi://Meta';
import Shell from 'gi://Shell';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import { workspaceIndexForRule } from './workspacePolicy.js';

// Retry delays (ms) after window-created for monitor moves. Mirrors
// active-monitor-placement: early passes often see an unassigned monitor, and
// slow clients (Electron apps like Discord) settle only after ~1s.
const MONITOR_RETRY_DELAYS_MS = [0, 150, 400, 900, 1600];

// Built-in workspace pins. Always active.
const RULES = [
  { appIds: ['cursor.desktop'], workspace: 1 },
  { appIds: ['gitkraken.desktop', 'gitkraken_gitkraken.desktop'], workspace: 3, monitor: 2 },
  { appIds: ['smartgit.desktop'], workspace: 3, monitor: 3 },
  { appIds: ['monkeytype.desktop', 'chrome-picebhhlijnlefeleilfbanaghjlkkna-Default.desktop'], workspace: 8 },
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
  if (Number.isFinite(number) && number >= 1 && number <= count) {
    return Math.trunc(number) - 1;
  }
  return -1;
}

/**
 * Whether it is safe to call move_to_monitor on this window.
 *
 * Requires a compositor actor (mapped) and a non-negative get_monitor().
 * Calling Mutter's move APIs on an unmapped or monitor-less window can
 * SIGSEGV the whole Shell, which JS cannot catch — so this gate is mandatory.
 *
 * @param {Meta.Window|null} win - Window under consideration.
 * @returns {boolean} true only when Mutter move APIs may be called.
 */
function isWindowMoveSafe(win) {
  if (!win || typeof win.move_to_monitor !== 'function') {
    return false;
  }
  try {
    if (typeof win.get_compositor_private === 'function' &&
        !win.get_compositor_private()) {
      return false;
    }
    if (typeof win.get_monitor !== 'function') {
      return false;
    }
    const index = Number(win.get_monitor());
    return Number.isFinite(index) && index >= 0;
  } catch (e) {
    return false;
  }
}

/**
 * Move a window onto the monitor its rule assigns, retrying while Mutter
 * settles.
 *
 * A maximized or fullscreen window is unmaximized around the move and restored
 * afterwards, because Mutter keeps a maximized window's size tied to its
 * current monitor.
 *
 * @param {Meta.Window} win - The window to place.
 * @param {object} rule - The matched rule (must carry monitor information).
 * @param {Array<number>} timeouts - Extension-owned list that receives the
 *   scheduled GLib source ids so disable() can cancel them.
 * @returns {void}
 */
function applyMonitor(win, rule, timeouts) {
  const attempt = () => {
    const target = resolveRuleMonitor(rule);
    if (target < 0) {
      console.log(`[app-rules] no monitor matches rule ${JSON.stringify(rule.monitor)}; leaving window alone`);
      return true;
    }
    if (!isWindowMoveSafe(win)) {
      return false;
    }
    if (win.get_monitor() === target) {
      return true;
    }
    let restore = null;
    try {
      if (typeof win.get_maximized === 'function' && win.get_maximized()) {
        restore = win.get_maximized();
        win.unmaximize(Meta.MaximizeFlags.BOTH);
      }
      win.move_to_monitor(target);
      if (restore) {
        win.maximize(restore);
      }
      console.log(`[app-rules] moved window to monitor index ${target}`);
      return true;
    } catch (e) {
      console.log(`[app-rules] move_to_monitor(${target}) failed: ${e}`);
      return true;
    }
  };

  if (attempt()) {
    return;
  }
  for (const delayMs of MONITOR_RETRY_DELAYS_MS) {
    if (delayMs === 0) {
      continue;
    }
    const sourceId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, delayMs, () => {
      const index = timeouts.indexOf(sourceId);
      if (index >= 0) {
        timeouts.splice(index, 1);
      }
      try {
        attempt();
      } catch (e) {
        console.log(`[app-rules] monitor retry failed: ${e}`);
      }
      return GLib.SOURCE_REMOVE;
    });
    timeouts.push(sourceId);
  }
}

/**
 * Apply a single rule to a window: move it to a workspace and/or stick it.
 *
 * @param {Meta.Window} win - The window to act on. No-op for null or
 *   skip-taskbar (utility/override) windows.
 * @param {{workspace?: number, sticky?: boolean, monitor?: number}} rule - The
 *   rule to apply. `workspace` is the visible one-based number; `sticky` pins
 *   to all workspaces; `monitor` is the installer's 1-based display number.
 * @param {Array<number>} timeouts - Extension-owned list receiving GLib source
 *   ids for the deferred monitor placement retries.
 * @returns {void}
 */
function applyRule(win, rule, timeouts) {
  if (!win || win.skip_taskbar) {
    return;
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

  if (rule.sticky && typeof win.stick === 'function') {
    try {
      win.stick();
    } catch (e) {
      // ignore
    }
  }

  if (rule.monitor !== undefined && rule.monitor !== null && rule.monitor !== 0) {
    applyMonitor(win, rule, timeouts || []);
  }
}

/**
 * Find the first rule whose app ids match the window and apply it.
 *
 * @param {Meta.Window} win - The window to match.
 * @param {Array<object>} rules - Active rules; user rules precede built-ins
 *   so an installer-managed rule wins for the same app.
 * @param {Array<number>} timeouts - Extension-owned list receiving GLib source
 *   ids for the deferred monitor placement retries.
 * @returns {void}
 */
function matchAndApply(win, rules, timeouts) {
  const appId = (getAppId(win) || '').toLowerCase();
  if (!appId) {
    return;
  }

  for (const rule of rules) {
    if (rule.appIds.some((id) => appId === id.toLowerCase())) {
      applyRule(win, rule, timeouts);
      break;
    }
  }
}

export default class AppRulesExtension extends Extension {
  enable() {
    this._timeouts = [];
    const userRules = loadUserRules();
    // Spotify and Discord are installation defaults: keep them sticky even
    // when the master installer has created an empty user-rules file.
    this._rules = userRules === null
      ? [...RULES, ...STICKY_FALLBACK_RULES]
      : [...userRules, ...RULES, ...STICKY_FALLBACK_RULES];

    this._sig = global.display.connect('window-created', (_disp, win) => {
      matchAndApply(win, this._rules, this._timeouts);
    });

    global.get_window_actors()
      .map((a) => a.meta_window)
      .forEach((w) => matchAndApply(w, this._rules, this._timeouts));
  }

  disable() {
    if (this._sig) {
      global.display.disconnect(this._sig);
      this._sig = null;
    }
    for (const sourceId of this._timeouts || []) {
      GLib.source_remove(sourceId);
    }
    this._timeouts = [];
    this._rules = null;
  }
}
