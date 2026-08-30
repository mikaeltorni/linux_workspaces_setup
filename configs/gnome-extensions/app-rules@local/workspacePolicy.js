// workspacePolicy.js - pure workspace-number conversion for app-rules@local.
//
// Rules store the one-based workspace number shown by GNOME and the installer;
// Meta.Window APIs require a zero-based index. Keeping that conversion here
// makes the configuration readable and lets repository tests exercise the
// boundary without importing GNOME Shell modules.

/**
 * Convert a GNOME-visible workspace number to a Meta workspace index.
 *
 * @param {unknown} workspaceNumber - One-based workspace number from a rule.
 * @returns {number} Zero-based workspace index, or -1 for an invalid value.
 */
export function workspaceIndexForRule(workspaceNumber) {
  const number = Number(workspaceNumber);
  if (!Number.isInteger(number) || number < 1) {
    return -1;
  }
  return number - 1;
}
