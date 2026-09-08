// monitorMovePolicy.js - fail-closed safety checks for native Mutter moves.
//
// A Meta.Window may retain a compositor wrapper while it is being mapped or
// destroyed. Calling move_to_monitor() in either transition can SIGSEGV GNOME
// Shell, so app-rules validates the window and its actor immediately before
// every native move.

/**
 * Whether a window is stable enough for Meta.Window.move_to_monitor().
 *
 * @param {Meta.Window|null} win - Window under consideration.
 * @returns {boolean} true only for a live window with a live, mapped compositor
 *   actor and an assigned source monitor.
 */
export function isWindowMoveSafe(win) {
  if (!win || typeof win.move_to_monitor !== 'function') {
    return false;
  }

  try {
    if (win.is_alive === false) {
      return false;
    }
    if (typeof win.get_compositor_private !== 'function' ||
        typeof win.get_monitor !== 'function') {
      return false;
    }

    const actor = win.get_compositor_private();
    // Clutter.Actor exposes mapped as a GObject property. Do not require
    // nonstandard liveness helpers; unmanaged signals cancel pending windows.
    if (!actor || (typeof actor.is_destroyed === 'function' && actor.is_destroyed())) return false;
    const mapped = typeof actor.is_mapped === 'function' ? actor.is_mapped() : actor.mapped;
    if (!mapped) {
      // Off-workspace actors are intentionally unmapped. Require explicit
      // hidden-workspace state and initialized geometry, never an early map.
      if (typeof win.showing_on_its_workspace !== 'function' ||
          win.showing_on_its_workspace() || typeof win.get_frame_rect !== 'function') return false;
      const rect = win.get_frame_rect();
      if (!rect || ![rect.x, rect.y, rect.width, rect.height].every(Number.isFinite) ||
          rect.width <= 0 || rect.height <= 0) return false;
    }

    const index = win.get_monitor();
    return Number.isInteger(index) && index >= 0;
  } catch (e) {
    return false;
  }
}
