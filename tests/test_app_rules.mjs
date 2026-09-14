// Exercise the shipped extension with a fake compositor; never open windows.
// Run: node --test tests/test_app_rules.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = fs.readFileSync(new URL('../configs/gnome-extensions/app-rules@local/extension.js', import.meta.url), 'utf8')
  .replace(/^import .*;\n/gm, '')
  .replace('export default class', 'class');

class Signals {
  handlers = new Map();
  next = 1;
  connect(name, callback) { const id = this.next++; this.handlers.set(id, [name, callback]); return id; }
  disconnect(id) { assert.ok(this.handlers.delete(id)); }
  emit(name, ...args) {
    for (const [event, callback] of [...this.handlers.values()])
      if (event === name) callback(this, ...args);
  }
}

function harness({existing = [], rules = [{appIds: ['cursor.desktop'], monitor: 2}], monitorCount = 2, geometries = [], primary = 0} = {}) {
  const display = new Signals();
  display.get_n_monitors = () => monitorCount;
  display.get_primary_monitor = () => primary;
  display.get_monitor_geometry = index => geometries[index];
  const timers = new Map();
  let next = 1;
  const context = vm.createContext({
    console: {log() {}}, TextDecoder, Extension: class {},
    GLib: {
      PRIORITY_DEFAULT: 0, SOURCE_REMOVE: false, SOURCE_CONTINUE: true,
      build_filenamev: parts => parts.join('/'), get_user_config_dir: () => '/config',
      file_get_contents: () => [true, Buffer.from(JSON.stringify({rules}))],
      timeout_add: (_priority, _delay, callback) => {const id = next++; timers.set(id, callback); return id;},
      source_remove: id => assert.ok(timers.delete(id)),
    },
    Shell: {WindowTracker: {get_default: () => ({get_window_app: win => win.appId ? {get_id: () => win.appId} : null})}},
    global: {display, get_window_actors: () => existing.map(meta_window => ({meta_window})),
      workspace_manager: {n_workspaces: 8, get_workspace_by_index: index => index}},
  });
  const policies = ['monitorMovePolicy.js', 'workspacePolicy.js'].map(name => fs.readFileSync(new URL('../configs/gnome-extensions/app-rules@local/' + name, import.meta.url), 'utf8').replace(/export /g, '')).join('\n');
  vm.runInContext(policies + '\n' + source + '\nthis.extension = new AppRulesExtension(); this.applyRule = applyRule;', context);
  context.extension.enable();
  return {display, timers, extension: context.extension, applyRule: context.applyRule,
    tick() {for (const [id, callback] of [...timers]) if (!callback()) timers.delete(id);}};
}

function windowMock({monitor = -1, mapped = false, appId = 'cursor.desktop'} = {}) {
  const win = new Signals();
  Object.assign(win, {monitor, appId, actor: {mapped}, moves: [], attempts: [], workspace: null, sticky: false,
    get_monitor() {return this.monitor;}, get_compositor_private() {return this.actor;},
    move_to_monitor(target) {this.attempts.push(target); assert.ok(this.monitor >= 0 && this.actor?.mapped, 'unsafe native monitor move'); this.moves.push(target); this.monitor = target;},
    change_workspace(target) {this.workspace = target;}, stick() {this.sticky = true;},
  });
  return win;
}

test('creation waits for mapping and a valid source monitor, then applies once', () => {
  const h = harness(), win = windowMock();
  h.display.emit('window-created', win);
  assert.deepEqual(win.attempts, []);
  h.tick();
  win.monitor = 0;
  h.tick();
  assert.deepEqual(win.moves, []);
  assert.deepEqual(win.attempts, []);
  win.actor.mapped = true;
  h.tick(); h.tick();
  assert.deepEqual(win.moves, [1]);
  assert.equal(h.timers.size, 0);
  assert.equal(win.handlers.size, 0);
  h.extension.disable();
});

test('direct calls reject absent actors and invalid source or destination monitors', () => {
  const h = harness();
  for (const monitor of [-1, NaN, 0.5, 2]) {
    const win = windowMock({monitor, mapped: true});
    h.applyRule(win, {monitor: 2});
    assert.deepEqual(win.moves, []);
    assert.deepEqual(win.attempts, []);
  }
  for (const target of [-1, NaN, 0.5, 3, 'bad']) {
    const win = windowMock({monitor: 0, mapped: true});
    h.applyRule(win, {monitor: target});
    assert.deepEqual(win.moves, []);
    assert.deepEqual(win.attempts, []);
  }
  const win = windowMock({monitor: 0, mapped: true});
  win.actor = null;
  h.applyRule(win, {monitor: 2});
  assert.deepEqual(win.moves, []);
  assert.deepEqual(win.attempts, []);
  h.extension.disable();
});

test('closing a pending window and disabling cancel callbacks and signals', () => {
  const h = harness(), closed = windowMock(), pending = windowMock();
  h.display.emit('window-created', closed);
  assert.equal(h.timers.size, 1);
  closed.emit('unmanaged');
  assert.equal(h.timers.size, 0);
  assert.equal(closed.handlers.size, 0);
  h.display.emit('window-created', pending);
  h.extension.disable();
  assert.equal(h.timers.size, 0);
  assert.equal(pending.handlers.size, 0);
  assert.equal(h.display.handlers.size, 0);
});

test('unmapped windows expire without any native moves', () => {
  const h = harness(), win = windowMock();
  h.display.emit('window-created', win);
  assert.equal(h.timers.size, 1);
  for (let i = 0; i < 200; i++) h.tick();
  assert.deepEqual(win.moves, []);
  assert.equal(h.timers.size, 0);
  assert.equal(win.handlers.size, 0);
  h.extension.disable();
});

test('late app identity, existing windows, user precedence and sticky/workspace rules survive', () => {
  const existing = windowMock({monitor: 0, mapped: true});
  const h = harness({existing: [existing], rules: [{appIds: ['CURSOR.desktop'], monitor: 2, workspace: 3, sticky: true}]});
  h.tick();
  assert.deepEqual(existing.moves, [1]);
  assert.equal(existing.workspace, 2);
  assert.equal(existing.sticky, true);
  const late = windowMock({monitor: 0, mapped: true, appId: null});
  h.display.emit('window-created', late); h.tick();
  late.appId = 'cursor.desktop'; h.tick();
  assert.deepEqual(late.moves, [1]);
  h.extension.disable();
});

test('saved geometry survives index changes and connector renaming', () => {
  const upper = {x: 0, y: 0, width: 3840, height: 2160};
  const lower = {...upper, y: 2160};
  const h = harness({monitorCount: 3, geometries: [lower, upper, {x: 3840, y: 1166}],
    rules: [{appIds: ['cursor.desktop'], monitor: 2, monitorConnector: 'DP-3', monitorGeometry: lower}]});
  const win = windowMock({monitor: 2, mapped: true});
  h.display.emit('window-created', win); h.tick();
  assert.deepEqual(win.moves, [0]);
  h.extension.disable();
});

test('Spotify and Discord follow the upper screen while Cursor follows the lower screen', () => {
  const upper = {x: 0, y: 0, width: 3840, height: 2160};
  const lower = {...upper, y: 2160};
  const portrait = {x: 3840, y: 1166, width: 2160, height: 3840};
  const rules = [
    {appIds: ['spotify.desktop'], monitor: 1, monitorGeometry: upper, sticky: true},
    {appIds: ['discord.desktop'], monitor: 1, monitorGeometry: upper, sticky: true},
    {appIds: ['cursor.desktop'], monitor: 2, monitorGeometry: lower},
  ];
  for (const geometries of [[lower, upper, portrait], [upper, portrait, lower]]) {
    const h = harness({monitorCount: 3, geometries, rules});
    for (const rule of rules) {
      const target = geometries.indexOf(rule.monitorGeometry);
      const win = windowMock({monitor: (target + 1) % 3, mapped: true, appId: rule.appIds[0]});
      h.display.emit('window-created', win); h.tick();
      assert.deepEqual(win.moves, [target]);
      assert.equal(win.sticky, Boolean(rule.sticky));
    }
    h.extension.disable();
  }
});

test('Monkeytype uses workspace 7 and the primary monitor even when hidden', () => {
  const h = harness({rules: [], monitorCount: 3, primary: 1});
  const win = windowMock({monitor: 2, mapped: false, appId: 'google-chrome.desktop'});
  win.get_wm_class_instance = () => 'crx_picebhhlijnlefeleilfbanaghjlkkna';
  win.showing_on_its_workspace = () => false;
  win.get_frame_rect = () => ({x: 4000, y: 1200, width: 1200, height: 900});
  win.move_to_monitor = function(target) { this.moves.push(target); this.monitor = target; };
  h.display.emit('window-created', win); h.tick();
  assert.equal(win.workspace, 6);
  assert.deepEqual(win.moves, [1]);
  h.extension.disable();
});

test('Cursor with late desktop identity honors its saved main-screen rule', () => {
  const main = {x: 0, y: 2160, width: 3840, height: 2160};
  const h = harness({monitorCount: 3, primary: 0, geometries: [main, {}, {}],
    rules: [{appIds: ['cursor.desktop'], monitor: 2, monitorGeometry: main}]});
  const win = windowMock({monitor: 2, mapped: true, appId: null});
  win.get_wm_class = () => 'Cursor';
  h.display.emit('window-created', win); h.tick();
  assert.deepEqual(win.moves, [0]);
  assert.equal(win.workspace, null);
  h.extension.disable();
});

test('Cursor defaults to the primary monitor without a saved rule', () => {
  const h = harness({rules: [], monitorCount: 3, primary: 2});
  const win = windowMock({monitor: 0, mapped: true});
  h.display.emit('window-created', win); h.tick();
  assert.deepEqual(win.moves, [2]);
  h.extension.disable();
});

test('SmartGit with late desktop identity moves from monitor 1 to monitor 3', () => {
  const h = harness({rules: [], monitorCount: 3});
  const win = windowMock({monitor: 0, mapped: true, appId: null});
  win.get_wm_class = () => 'SmartGit';
  // Moving workspaces can hide the actor: monitor placement must happen first.
  win.change_workspace = function(target) { this.workspace = target; this.actor.mapped = false; };
  h.display.emit('window-created', win); h.tick();
  assert.deepEqual(win.moves, [2]);
  assert.equal(win.workspace, 2);
  h.extension.disable();
});

test('programmatic monitor and workspace moves preserve existing all-workspace state', () => {
  const h = harness();
  for (const throws of [false, true]) {
    const win = windowMock({monitor: 0, mapped: true, appId: 'spotify.desktop'});
    win.sticky = true;
    win.is_on_all_workspaces = () => win.sticky;
    win.move_to_monitor = function(target) { this.monitor = target; this.sticky = false; };
    win.change_workspace = function(target) {
      this.workspace = target; this.sticky = false;
      if (throws) throw new Error('workspace move failed');
    };
    try { h.applyRule(win, {monitor: 2, workspace: 3}); } catch (error) {
      assert.equal(error.message, 'workspace move failed');
    }
    assert.equal(win.sticky, true);
  }
  h.extension.disable();
});

test('Monkeytype Chrome PWA still moves to workspace 7 when skip_taskbar is set', () => {
  const h = harness({rules: [], monitorCount: 3, primary: 1});
  const win = windowMock({monitor: 2, mapped: true, appId: 'google-chrome.desktop'});
  win.skip_taskbar = true;
  win.get_wm_class = () => 'Google-chrome';
  win.get_wm_class_instance = () => 'crx_picebhhlijnlefeleilfbanaghjlkkna';
  h.display.emit('window-created', win); h.tick();
  assert.equal(win.workspace, 6);
  assert.deepEqual(win.moves, [1]);
  h.extension.disable();
});

test('Monkeytype waits for the Chrome PWA class instance before treating google-chrome as done', () => {
  const h = harness({rules: [], monitorCount: 3, primary: 1});
  let instance = '';
  const win = windowMock({monitor: 2, mapped: true, appId: 'google-chrome.desktop'});
  win.get_wm_class = () => 'Google-chrome';
  win.get_wm_class_instance = () => instance;
  h.display.emit('window-created', win); h.tick();
  assert.equal(win.workspace, null);
  assert.deepEqual(win.moves, []);
  instance = 'crx_picebhhlijnlefeleilfbanaghjlkkna';
  h.tick();
  assert.equal(win.workspace, 6);
  assert.deepEqual(win.moves, [1]);
  h.extension.disable();
});

test('Spotify and Discord become sticky from wm class when WindowTracker has no app id', () => {
  const h = harness({rules: [], monitorCount: 1, primary: 0});
  for (const [appId, wmClass] of [[null, 'Spotify'], [null, 'discord']]) {
    const win = windowMock({monitor: 0, mapped: true, appId});
    win.get_wm_class = () => wmClass;
    h.display.emit('window-created', win); h.tick();
    assert.equal(win.sticky, true, wmClass);
    assert.equal(win.workspace, null);
  }
  h.extension.disable();
});

test('title match does not pin unrelated windows that mention Monkeytype', () => {
  const h = harness({rules: [], monitorCount: 3, primary: 1});
  const win = windowMock({monitor: 0, mapped: true, appId: 'kitty.desktop'});
  win.get_wm_class = () => 'kitty-acc-agent-grok';
  win.get_title = () => 'linux_workspaces_setup_feat-monkeytype-ws7';
  h.display.emit('window-created', win); h.tick();
  assert.equal(win.workspace, null);
  h.extension.disable();
});

test('Monkeytype matches a Chrome window by title when the crx instance is missing', () => {
  const h = harness({rules: [], monitorCount: 3, primary: 1});
  const win = windowMock({monitor: 2, mapped: true, appId: 'google-chrome.desktop'});
  win.get_wm_class = () => 'Google-chrome';
  win.get_title = () => 'Monkeytype | A minimalistic, customizable typing test';
  h.display.emit('window-created', win); h.tick();
  assert.equal(win.workspace, 6);
  assert.deepEqual(win.moves, [1]);
  h.extension.disable();
});

test('Monkeytype workspace pin applies when monitor move is not yet safe', () => {
  const h = harness({rules: [], monitorCount: 3, primary: 1});
  const win = windowMock({monitor: -1, mapped: false, appId: 'google-chrome.desktop'});
  win.get_wm_class_instance = () => 'crx_picebhhlijnlefeleilfbanaghjlkkna';
  h.display.emit('window-created', win); h.tick();
  assert.equal(win.workspace, 6);
  assert.deepEqual(win.moves, []);
  h.extension.disable();
});

test('Spotify stays sticky even when the window reports skip_taskbar', () => {
  const h = harness({rules: [], monitorCount: 1, primary: 0});
  const win = windowMock({monitor: 0, mapped: true, appId: 'spotify_spotify.desktop'});
  win.skip_taskbar = true;
  win.get_wm_class = () => 'Spotify';
  h.display.emit('window-created', win); h.tick();
  assert.equal(win.sticky, true);
  h.extension.disable();
});
