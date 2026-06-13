import Shell from 'gi://Shell';
import Meta from 'gi://Meta';
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

function getAppId(win) {
  try {
    const tracker = Shell.WindowTracker.get_default();
    const app = tracker.get_window_app(win);
    return app ? app.get_id() : null;
  } catch (e) {
    return null;
  }
}

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
