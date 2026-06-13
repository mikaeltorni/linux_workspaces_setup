/**
 * extension.js — Monitor & Window Hotkeys GNOME Shell extension.
 *
 * Provides keyboard shortcuts (and a D-Bus API) to move the focused window
 * between monitors, tile it to screen halves, resize it edge-by-edge, and drag
 * it with the pointer. The D-Bus interface (TileRightHalf, …) lets the
 * companion Ctrl+Back tiler systemd service trigger tiling without keybindings.
 *
 * Components:
 *   - getFocusWindow(): Resolve the focused, user-manageable window.
 *   - moveFocusedWindowToMonitor(): Move the focused window between monitors.
 *   - resizeFocusedWindow(): Resize the focused window along one edge.
 *   - tileFocusedWindow{Top,Bottom,Left,Right}Half(): Half-screen tiling.
 *   - startPointerDrag()/stopPointerDrag(): Pointer-driven window dragging.
 *   - MonitorWindowHotkeysExtension: Extension lifecycle (enable/disable).
 */
import Shell from 'gi://Shell';
import Meta from 'gi://Meta';
import GLib from 'gi://GLib';
import Clutter from 'gi://Clutter';
import Gio from 'gi://Gio';
import { Extension } from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const MONITOR_KEYBINDINGS = [
  { name: 'move-active-window-to-monitor-1', monitor: 0 },
  { name: 'move-active-window-to-monitor-2', monitor: 1 },
  { name: 'move-active-window-to-monitor-3', monitor: 2 },
  { name: 'move-active-window-to-monitor-4', monitor: 3 },
  { name: 'move-active-window-to-monitor-5', monitor: 4 },
  { name: 'move-active-window-to-monitor-6', monitor: 5 },
];

const RESIZE_STEP = 40;
const POINTER_DRAG_INTERVAL_MS = 8;
const MIN_WINDOW_WIDTH = 160;
const MIN_WINDOW_HEIGHT = 120;

const RESIZE_KEYBINDINGS = [
  { name: 'resize-active-window-left-out', edge: 'left', direction: -1 },
  { name: 'resize-active-window-left-in', edge: 'left', direction: 1 },
  { name: 'resize-active-window-right-out', edge: 'right', direction: 1 },
  { name: 'resize-active-window-right-in', edge: 'right', direction: -1 },
  { name: 'resize-active-window-up-out', edge: 'top', direction: -1 },
  { name: 'resize-active-window-up-in', edge: 'top', direction: 1 },
  { name: 'resize-active-window-down-out', edge: 'bottom', direction: 1 },
  { name: 'resize-active-window-down-in', edge: 'bottom', direction: -1 },
];

const POINTER_DRAG_KEY = 'drag-active-window-with-pointer';
const DBUS_BUS_NAME = 'org.gnome.shell.extensions.MonitorWindowHotkeys';
const DBUS_OBJECT_PATH = '/org/gnome/shell/extensions/monitor_window_hotkeys';

// D-Bus XML interface definition for programmatic window tiling.
const DBUS_INTERFACE_XML = `
<node name="/org/gnome/shell/extensions/monitor_window_hotkeys">
  <interface name="org.gnome.shell.extensions.MonitorWindowHotkeys">
    <method name="TileRightHalf"/>
    <method name="TileLeftHalf"/>
    <method name="TileTopHalf"/>
    <method name="TileBottomHalf"/>
    <method name="MoveToMonitor1"/>
    <method name="MoveToMonitor2"/>
    <method name="MoveToMonitor3"/>
    <method name="MoveToMonitor4"/>
    <method name="MoveToMonitor5"/>
    <method name="MoveToMonitor6"/>
  </interface>
</node>`;

/**
 * Return the currently focused, user-manageable window.
 *
 * Windows that are absent or marked skip-taskbar (panels, docks, OSDs) are
 * ignored so hotkeys only ever act on real application windows.
 *
 * @returns {Meta.Window|null} The focused window, or null when none qualifies.
 */
function getFocusWindow() {
  const win = global.display.focus_window;
  const skipTaskbar = typeof win?.is_skip_taskbar === 'function'
    ? win.is_skip_taskbar()
    : win?.skip_taskbar;

  if (!win || skipTaskbar) {
    return null;
  }

  return win;
}

/**
 * Move the focused window to the given monitor.
 *
 * No-ops when there is no focused window, the window cannot be moved, the
 * monitor index is out of range, or the window already lives on that monitor.
 *
 * @param {number} monitorIndex Zero-based index of the destination monitor.
 * @returns {void}
 */
function moveFocusedWindowToMonitor(monitorIndex) {
  const win = getFocusWindow();
  if (!win || typeof win.move_to_monitor !== 'function') {
    return;
  }

  const monitorCount = global.display.get_n_monitors();
  if (monitorIndex < 0 || monitorIndex >= monitorCount) {
    return;
  }

  if (typeof win.get_monitor === 'function' && win.get_monitor() === monitorIndex) {
    return;
  }

  win.move_to_monitor(monitorIndex);
}

/**
 * Unmaximize a window across the differing GNOME Shell/Mutter APIs.
 *
 * Newer Mutter exposes get_maximized(); older versions expose the
 * maximizedHorizontally/maximizedVertically flags. Both paths are handled.
 *
 * @param {Meta.Window} win Window to unmaximize.
 * @returns {void}
 */
function unmaximizeWindow(win) {
  if (typeof win.get_maximized === 'function') {
    const maximized = win.get_maximized();
    if (maximized) {
      win.unmaximize(maximized);
    }
    return;
  }

  if (win.maximizedHorizontally && typeof win.unmaximize === 'function') {
    win.unmaximize(Meta.MaximizeFlags.HORIZONTAL);
  }
  if (win.maximizedVertically && typeof win.unmaximize === 'function') {
    win.unmaximize(Meta.MaximizeFlags.VERTICAL);
  }
}

/**
 * Report whether a window can be both moved and resized.
 *
 * @param {Meta.Window|null} win Candidate window.
 * @returns {boolean} True when the window supports move_resize_frame and any
 *   available allows_resize()/allows_move() checks pass.
 */
function canMoveResizeWindow(win) {
  if (!win || typeof win.move_resize_frame !== 'function') {
    return false;
  }

  // Check allows_resize/allows_move only when those methods exist.
  if (typeof win.allows_resize === 'function' && !win.allows_resize()) {
    return false;
  }
  if (typeof win.allows_move === 'function' && !win.allows_move()) {
    return false;
  }

  return true;
}

/**
 * Report whether a window can be moved (without requiring resize support).
 *
 * @param {Meta.Window|null} win Candidate window.
 * @returns {boolean} True when the window supports move_frame and any available
 *   allows_move() check passes.
 */
function canMoveWindow(win) {
  if (!win || typeof win.move_frame !== 'function') {
    return false;
  }

  if (typeof win.allows_move === 'function' && !win.allows_move()) {
    return false;
  }

  return true;
}

/**
 * Normalize a window's state so it can be freely positioned/resized.
 *
 * Clears maximized, fullscreen, minimized, and always-on-top states when the
 * corresponding methods are available on this GNOME Shell version.
 *
 * @param {Meta.Window} win Window to prepare.
 * @returns {void}
 */
function prepareWindowForMoveResize(win) {
  unmaximizeWindow(win);
  if (typeof win.unmake_fullscreen === 'function') {
    win.unmake_fullscreen();
  }
  if (typeof win.unminimize === 'function') {
    win.unminimize();
  }
  if (typeof win.unmake_above === 'function') {
    win.unmake_above();
  }
}

/**
 * Raise a window to the top and mark it most-recently-used.
 *
 * Uses the workspace-aware API when present, otherwise falls back to the
 * legacy raise_and_make_recent().
 *
 * @param {Meta.Window} win Window to raise.
 * @returns {void}
 */
function raiseWindow(win) {
  if (typeof win.raise_and_make_recent_on_workspace === 'function') {
    win.raise_and_make_recent_on_workspace(global.workspace_manager.get_active_workspace());
  } else if (typeof win.raise_and_make_recent === 'function') {
    win.raise_and_make_recent();
  }
}

/**
 * Get the usable work area (excluding panels) for a window's monitor.
 *
 * @param {Meta.Window} win Window whose monitor work area is requested.
 * @returns {Meta.Rectangle} The work area rectangle for that monitor.
 */
function getWindowWorkArea(win) {
  const monitorIndex = typeof win.get_monitor === 'function'
    ? win.get_monitor()
    : global.display.get_current_monitor();

  return win.get_work_area_for_monitor(monitorIndex);
}

/**
 * Resize the focused window by one RESIZE_STEP along a single edge.
 *
 * The opposite edge stays anchored; the moving edge is clamped to the work
 * area and to MIN_WINDOW_WIDTH/MIN_WINDOW_HEIGHT. Errors are logged, never
 * thrown.
 *
 * @param {('left'|'right'|'top'|'bottom')} edge Edge to move.
 * @param {number} direction -1 to shrink toward / +1 to grow away from the edge.
 * @returns {void}
 */
function resizeFocusedWindow(edge, direction) {
  const win = getFocusWindow();
  if (!canMoveResizeWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);

    const frame = win.get_frame_rect();
    const workArea = getWindowWorkArea(win);
    let x = frame.x;
    let y = frame.y;
    let width = frame.width;
    let height = frame.height;
    const delta = direction * RESIZE_STEP;

    switch (edge) {
    case 'left': {
      const newX = Math.max(workArea.x, Math.min(x + delta, x + width - MIN_WINDOW_WIDTH));
      width += x - newX;
      x = newX;
      break;
    }
    case 'right': {
      const right = Math.max(x + MIN_WINDOW_WIDTH, Math.min(x + width + delta, workArea.x + workArea.width));
      width = right - x;
      break;
    }
    case 'top': {
      const newY = Math.max(workArea.y, Math.min(y + delta, y + height - MIN_WINDOW_HEIGHT));
      height += y - newY;
      y = newY;
      break;
    }
    case 'bottom': {
      const bottom = Math.max(y + MIN_WINDOW_HEIGHT, Math.min(y + height + delta, workArea.y + workArea.height));
      height = bottom - y;
      break;
    }
    default:
      return;
    }

    if (width <= 0 || height <= 0) {
      return;
    }

    win.move_resize_frame(true, x, y, width, height);
    raiseWindow(win);
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to resize focused window: ${error}`);
  }
}

/**
 * Test whether an event signals the end of a pointer drag.
 *
 * @param {Clutter.Event} event Event received from the captured-event signal.
 * @returns {boolean} True for a primary (left) mouse button release.
 */
function pointerDragReleaseEvent(event) {
  if (event.type !== Clutter.EventType.BUTTON_RELEASE) {
    return false;
  }

  const button = event.get_button();
  return button === 1;
}

/**
 * Stop an in-progress pointer drag and settle the window in place.
 *
 * Cancels the drag timeout, clamps the window inside its work area, raises it,
 * and clears the drag state. Safe to call when no drag is active.
 *
 * @param {{timeoutId: ?number, window: ?Meta.Window}} state Pointer drag state.
 * @returns {void}
 */
function stopPointerDrag(state) {
  if (!state) {
    return;
  }

  if (state.timeoutId) {
    GLib.source_remove(state.timeoutId);
    state.timeoutId = null;
  }

  const win = state.window;
  if (!win) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);
    const workArea = getWindowWorkArea(win);
    const frame = win.get_frame_rect();

    // Clamp to work area.
    let x = Math.max(workArea.x, Math.min(frame.x, workArea.x + workArea.width - frame.width));
    let y = Math.max(workArea.y, Math.min(frame.y, workArea.y + workArea.height - frame.height));

    win.move_frame(true, x, y);
    raiseWindow(win);
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to stop pointer drag: ${error}`);
  }

  state.window = null;
}

/**
 * Begin dragging the focused window with the pointer.
 *
 * Records the pointer-to-frame offset and installs a periodic timeout
 * (POINTER_DRAG_INTERVAL_MS) that follows the pointer until stopPointerDrag()
 * runs. No-ops when the focused window cannot be moved. Errors are logged.
 *
 * @param {{timeoutId: ?number, window: ?Meta.Window, pointerX: number,
 *   pointerY: number}} state Pointer drag state to populate.
 * @returns {void}
 */
function startPointerDrag(state) {
  if (!state) {
    return;
  }

  const win = getFocusWindow();
  if (!canMoveWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);
    state.window = win;
    const [, pointerX, pointerY] = global.get_pointer();
    const frame = win.get_frame_rect();
    state.pointerX = pointerX - frame.x;
    state.pointerY = pointerY - frame.y;

    // Start a timeout to handle the drag.
    state.timeoutId = GLib.timeout_add(GLib.PRIORITY_DEFAULT, POINTER_DRAG_INTERVAL_MS, () => {
      if (!state || !state.window) {
        return GLib.SOURCE_REMOVE;
      }

      const win = state.window;
      const [, pointerX, pointerY] = global.get_pointer();
      let newX = pointerX - state.pointerX;
      let newY = pointerY - state.pointerY;

      // Clamp to work area.
      const workArea = getWindowWorkArea(win);
      newX = Math.max(workArea.x, Math.min(newX, workArea.x + workArea.width - win.get_frame_rect().width));
      newY = Math.max(workArea.y, Math.min(newY, workArea.y + workArea.height - win.get_frame_rect().height));

      win.move_frame(true, newX, newY);
      raiseWindow(win);

      return GLib.SOURCE_CONTINUE;
    });
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to start pointer drag: ${error}`);
  }
}

/**
 * Tile the focused window to the top half of its monitor's work area.
 *
 * No-ops when the window cannot be move/resized or the work area is degenerate.
 * Errors are logged, never thrown.
 *
 * @returns {void}
 */
function tileFocusedWindowTopHalf() {
  const win = getFocusWindow();
  if (!canMoveResizeWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);

    const monitorIndex = typeof win.get_monitor === 'function'
      ? win.get_monitor()
      : global.display.get_current_monitor();
    const workArea = win.get_work_area_for_monitor(monitorIndex);
    const topHeight = Math.floor(workArea.height / 2);

    if (topHeight <= 0 || workArea.height <= 0) {
      return;
    }

    if (typeof win.move_to_monitor === 'function') {
      win.move_to_monitor(monitorIndex);
    }
    if (typeof win.move_frame === 'function') {
      win.move_frame(true, workArea.x, workArea.y);
    }
    win.move_resize_frame(true, workArea.x, workArea.y, workArea.width, topHeight);
    raiseWindow(win);
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to tile focused window top: ${error}`);
  }
}

/**
 * Tile the focused window to the bottom half of its monitor's work area.
 *
 * No-ops when the window cannot be move/resized or the work area is degenerate.
 * Errors are logged, never thrown.
 *
 * @returns {void}
 */
function tileFocusedWindowBottomHalf() {
  const win = getFocusWindow();
  if (!canMoveResizeWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);

    const monitorIndex = typeof win.get_monitor === 'function'
      ? win.get_monitor()
      : global.display.get_current_monitor();
    const workArea = win.get_work_area_for_monitor(monitorIndex);
    const bottomHeight = Math.floor(workArea.height / 2);
    const y = workArea.y + Math.floor(workArea.height / 2);

    if (bottomHeight <= 0 || workArea.height <= 0) {
      return;
    }

    if (typeof win.move_to_monitor === 'function') {
      win.move_to_monitor(monitorIndex);
    }
    if (typeof win.move_frame === 'function') {
      win.move_frame(true, workArea.x, y);
    }
    win.move_resize_frame(true, workArea.x, y, workArea.width, bottomHeight);
    raiseWindow(win);
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to tile focused window bottom: ${error}`);
  }
}

/**
 * Tile the focused window to the left half of its monitor's work area.
 *
 * No-ops when the window cannot be move/resized or the work area is degenerate.
 * Errors are logged, never thrown.
 *
 * @returns {void}
 */
function tileFocusedWindowLeftHalf() {
  const win = getFocusWindow();
  if (!canMoveResizeWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);

    const monitorIndex = typeof win.get_monitor === 'function'
      ? win.get_monitor()
      : global.display.get_current_monitor();
    const workArea = win.get_work_area_for_monitor(monitorIndex);
    const leftWidth = Math.floor(workArea.width / 2);
    const y = workArea.y;
    const width = workArea.width - leftWidth;
    const height = workArea.height;

    if (width <= 0 || height <= 0) {
      return;
    }

    if (typeof win.move_to_monitor === 'function') {
      win.move_to_monitor(monitorIndex);
    }
    if (typeof win.move_frame === 'function') {
      win.move_frame(true, workArea.x, y);
    }
    win.move_resize_frame(true, workArea.x, y, width, height);
    raiseWindow(win);
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to tile focused window left: ${error}`);
  }
}

/**
 * Tile the focused window to the right half of its monitor's work area.
 *
 * Also invoked over D-Bus (TileRightHalf) by the Ctrl+Back tiler service.
 * No-ops when the window cannot be move/resized or the work area is degenerate.
 * Errors are logged, never thrown.
 *
 * @returns {void}
 */
function tileFocusedWindowRightHalf() {
  const win = getFocusWindow();
  if (!canMoveResizeWindow(win)) {
    return;
  }

  try {
    prepareWindowForMoveResize(win);

    const monitorIndex = typeof win.get_monitor === 'function'
      ? win.get_monitor()
      : global.display.get_current_monitor();
    const workArea = win.get_work_area_for_monitor(monitorIndex);
    const leftWidth = Math.floor(workArea.width / 2);
    const x = workArea.x + leftWidth;
    const y = workArea.y;
    const width = workArea.width - leftWidth;
    const height = workArea.height;

    if (width <= 0 || height <= 0) {
      return;
    }

    if (typeof win.move_to_monitor === 'function') {
      win.move_to_monitor(monitorIndex);
    }
    if (typeof win.move_frame === 'function') {
      win.move_frame(true, x, y);
    }
    win.move_resize_frame(true, x, y, width, height);
    raiseWindow(win);
  } catch (error) {
    console.error(`monitor-window-hotkeys: failed to tile focused window right: ${error}`);
  }
}

/**
 * GNOME Shell extension entry point for monitor/window hotkeys.
 *
 * On enable() it exports the D-Bus tiling interface, registers every keybinding
 * defined in the extension schema, and listens for pointer-drag releases. On
 * disable() it tears all of that down so the extension can be cleanly reloaded.
 */
export default class MonitorWindowHotkeysExtension extends Extension {
  /**
   * Export the D-Bus interface and register all keybindings and listeners.
   *
   * @returns {void}
   */
  enable() {
    this._settings = this.getSettings();
    this._keybindings = [];
    this._pointerDragState = {
      timeoutId: null,
      window: null,
      pointerX: 0,
      pointerY: 0,
    };

    const dbusImplementation = {
      TileRightHalf: tileFocusedWindowRightHalf,
      TileLeftHalf: tileFocusedWindowLeftHalf,
      TileTopHalf: tileFocusedWindowTopHalf,
      TileBottomHalf: tileFocusedWindowBottomHalf,
      MoveToMonitor1: () => moveFocusedWindowToMonitor(0),
      MoveToMonitor2: () => moveFocusedWindowToMonitor(1),
      MoveToMonitor3: () => moveFocusedWindowToMonitor(2),
      MoveToMonitor4: () => moveFocusedWindowToMonitor(3),
      MoveToMonitor5: () => moveFocusedWindowToMonitor(4),
      MoveToMonitor6: () => moveFocusedWindowToMonitor(5),
    };
    this._dbusObject = Gio.DBusExportedObject.wrapJSObject(
      DBUS_INTERFACE_XML,
      dbusImplementation,
    );
    this._dbusObject.export(Gio.DBus.session, DBUS_OBJECT_PATH);
    this._dbusOwnerId = Gio.bus_own_name_on_connection(
      Gio.DBus.session,
      DBUS_BUS_NAME,
      Gio.BusNameOwnerFlags.NONE,
      null,
      null,
    );

    this._capturedEventId = global.stage.connect('captured-event', (actor, event) => {
      if (this._pointerDragState?.timeoutId && pointerDragReleaseEvent(event)) {
        stopPointerDrag(this._pointerDragState);
      }

      return Clutter.EVENT_PROPAGATE;
    });

    for (const binding of MONITOR_KEYBINDINGS) {
      Main.wm.addKeybinding(
        binding.name,
        this._settings,
        Meta.KeyBindingFlags.NONE,
        Shell.ActionMode.NORMAL,
        () => moveFocusedWindowToMonitor(binding.monitor),
      );
      this._keybindings.push(binding.name);
    }

    Main.wm.addKeybinding(
      'tile-active-window-right-half',
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      tileFocusedWindowRightHalf,
    );
    this._keybindings.push('tile-active-window-right-half');
    Main.wm.addKeybinding(
      'tile-top-half',
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      () => tileFocusedWindowTopHalf(),
    );
    this._keybindings.push('tile-top-half');

    Main.wm.addKeybinding(
      'tile-bottom-half',
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      () => tileFocusedWindowBottomHalf(),
    );
    this._keybindings.push('tile-bottom-half');

    Main.wm.addKeybinding(
      'tile-left-half',
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      () => tileFocusedWindowLeftHalf(),
    );
    this._keybindings.push('tile-left-half');

    for (const binding of RESIZE_KEYBINDINGS) {
      Main.wm.addKeybinding(
        binding.name,
        this._settings,
        Meta.KeyBindingFlags.NONE,
        Shell.ActionMode.NORMAL,
        () => resizeFocusedWindow(binding.edge, binding.direction),
      );
      this._keybindings.push(binding.name);
    }

    Main.wm.addKeybinding(
      POINTER_DRAG_KEY,
      this._settings,
      Meta.KeyBindingFlags.NONE,
      Shell.ActionMode.NORMAL,
      () => startPointerDrag(this._pointerDragState),
    );
    this._keybindings.push(POINTER_DRAG_KEY);

  }

  /**
   * Unregister keybindings, listeners, and the D-Bus interface, releasing all
   * resources acquired in enable().
   *
   * @returns {void}
   */
  disable() {
    if (this._dbusOwnerId) {
      Gio.bus_unown_name(this._dbusOwnerId);
      this._dbusOwnerId = null;
    }

    if (this._dbusObject) {
      this._dbusObject.unexport();
      this._dbusObject = null;
    }

    if (this._pointerDragState) {
      stopPointerDrag(this._pointerDragState);
      this._pointerDragState = null;
    }

    if (this._capturedEventId) {
      global.stage.disconnect(this._capturedEventId);
      this._capturedEventId = null;
    }

    if (this._keybindings) {
      for (const bindingName of this._keybindings) {
        Main.wm.removeKeybinding(bindingName);
      }
      this._keybindings = null;
    }

    this._settings = null;
  }
}
