//! Ctrl + mouse-Back window-placement tiler.
//!
//! Grabs the selected pointer, forwards every other event through a virtual
//! uinput device, and calls the monitor-window-hotkeys D-Bus `TileRightHalf`
//! method when the configured modifier + button chord is pressed.

use std::collections::HashSet;
use std::env;
use std::fs;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use evdev::uinput::VirtualDeviceBuilder;
use evdev::{Device, EventType, InputEvent, Key, RelativeAxisType};
use nix::sys::select::{select, FdSet};
use nix::sys::time::{TimeVal, TimeValLike};

use crate::logging;

const EV_KEY: u16 = 1;
const KEY_LEFTCTRL: u16 = 29;
const KEY_RIGHTCTRL: u16 = 97;
const KEY_LEFTALT: u16 = 56;
const KEY_RIGHTALT: u16 = 100;
const KEY_LEFTMETA: u16 = 125;
const KEY_RIGHTMETA: u16 = 126;
const KEY_LEFTSHIFT: u16 = 42;
const KEY_RIGHTSHIFT: u16 = 54;
const KEY_BACK: u16 = 158;
const BTN_SIDE: u16 = 275;
const BTN_EXTRA: u16 = 276;
const BTN_FORWARD: u16 = 277;

const VIRTUAL_DEVICE_NAME: &str = "ctrl-back-window-tiler";
const DBUS_BUS_NAME: &str = "org.gnome.shell.extensions.MonitorWindowHotkeys";
const DBUS_OBJECT_PATH: &str = "/org/gnome/shell/extensions/monitor_window_hotkeys";
const DBUS_INTERFACE: &str = "org.gnome.shell.extensions.MonitorWindowHotkeys";
const RESCAN_INTERVAL: Duration = Duration::from_secs(2);

/// Sort event device paths by their numeric `eventN` suffix when available.
pub fn input_device_sort_key(path: &str) -> (u8, String) {
    if let Some(suffix) = path.rsplit_once("event").map(|(_, s)| s) {
        if path.contains("/dev/input/") && suffix.chars().all(|c| c.is_ascii_digit()) {
            return (0, format!("{suffix:0>8}"));
        }
    }
    (1, path.to_string())
}

fn modifier_codes_for(name: &str) -> HashSet<u16> {
    match name {
        "Control" => HashSet::from([KEY_LEFTCTRL, KEY_RIGHTCTRL]),
        "Alt" => HashSet::from([KEY_LEFTALT, KEY_RIGHTALT]),
        "Super" => HashSet::from([KEY_LEFTMETA, KEY_RIGHTMETA]),
        "Shift" => HashSet::from([KEY_LEFTSHIFT, KEY_RIGHTSHIFT]),
        _ => HashSet::new(),
    }
}

fn button_codes_for(name: &str) -> HashSet<u16> {
    match name {
        "BTN_FORWARD" => HashSet::from([BTN_FORWARD, BTN_EXTRA]),
        _ => HashSet::from([KEY_BACK, BTN_SIDE, BTN_EXTRA]),
    }
}

/// Return evdev codes for `WINDOW_PLACEMENT_TILE_MODIFIER` (default Control).
pub fn configured_modifier_codes() -> HashSet<u16> {
    let names = env::var("WINDOW_PLACEMENT_TILE_MODIFIER").unwrap_or_else(|_| "Control".into());
    let mut codes = HashSet::new();
    for name in names.replace('|', "+").split('+') {
        codes.extend(modifier_codes_for(name.trim()));
    }
    if codes.is_empty() {
        modifier_codes_for("Control")
    } else {
        codes
    }
}

/// Return evdev codes for `WINDOW_PLACEMENT_TILE_BUTTON` (default BTN_BACK).
pub fn configured_button_codes() -> HashSet<u16> {
    let name = env::var("WINDOW_PLACEMENT_TILE_BUTTON").unwrap_or_else(|_| "BTN_BACK".into());
    button_codes_for(name.trim())
}

/// Resolve a configured stable path against currently available event nodes.
pub fn select_pointer_path(
    target_device: &str,
    current_pointer: &str,
    paths: &[String],
    realpath: impl Fn(&str) -> String,
    reported_missing: &mut bool,
) -> String {
    if !target_device.is_empty() {
        let resolved = realpath(target_device);
        if paths.iter().any(|p| p == &resolved) {
            *reported_missing = false;
            return resolved;
        }
        if !*reported_missing {
            logging::service(
                "WARN",
                format!("configured pointer device is unavailable: {target_device} -> {resolved}"),
            );
            *reported_missing = true;
        }
        return String::new();
    }
    if paths.iter().any(|p| p == current_pointer) {
        return current_pointer.to_string();
    }
    String::new()
}

/// In-memory tiler: tracks modifier state and decides tile vs forward.
pub struct TilerLogic {
    pub ctrl_pressed: HashSet<(String, u16)>,
    pub suppressed: HashSet<(String, u16)>,
    pub forwarded: Vec<(u16, u16, i32)>,
    pub tile_calls: usize,
    pub ui_ok: bool,
    pub ctrl_codes: HashSet<u16>,
    pub back_codes: HashSet<u16>,
    pub forward_codes: HashSet<(u16, u16)>,
}

impl Default for TilerLogic {
    fn default() -> Self {
        Self {
            ctrl_pressed: HashSet::new(),
            suppressed: HashSet::new(),
            forwarded: Vec::new(),
            tile_calls: 0,
            ui_ok: true,
            ctrl_codes: HashSet::from([KEY_LEFTCTRL, KEY_RIGHTCTRL]),
            back_codes: HashSet::from([KEY_BACK, BTN_SIDE, BTN_EXTRA]),
            forward_codes: HashSet::from([(EV_KEY, BTN_SIDE), (EV_KEY, KEY_LEFTCTRL)]),
        }
    }
}

impl TilerLogic {
    /// Handle one EV_KEY event from `path`.
    pub fn handle_key(&mut self, path: &str, grabbed: bool, code: u16, value: i32) {
        if self.ctrl_codes.contains(&code) {
            let key = (path.to_string(), code);
            if value == 0 {
                self.ctrl_pressed.remove(&key);
            } else {
                self.ctrl_pressed.insert(key);
            }
            if grabbed {
                self.forward(EV_KEY, code, value);
            }
            return;
        }
        if self.back_codes.contains(&code) {
            let key = (path.to_string(), code);
            if value == 1 && !self.ctrl_pressed.is_empty() {
                if grabbed {
                    self.suppressed.insert(key);
                }
                self.tile_calls += 1;
                return;
            }
            if self.suppressed.contains(&key) {
                if value == 0 {
                    self.suppressed.remove(&key);
                }
                return;
            }
            if grabbed {
                self.forward(EV_KEY, code, value);
            }
            return;
        }
        if grabbed {
            self.forward(EV_KEY, code, value);
        }
    }

    /// Forward a non-key event from a grabbed pointer.
    pub fn handle_other(&mut self, grabbed: bool, event_type: u16, code: u16, value: i32) {
        if grabbed {
            self.forward(event_type, code, value);
        }
    }

    fn forward(&mut self, event_type: u16, code: u16, value: i32) {
        if !self.ui_ok {
            return;
        }
        if !self.forward_codes.contains(&(event_type, code)) {
            return;
        }
        self.forwarded.push((event_type, code, value));
    }
}

fn tile_right() {
    let status = std::process::Command::new("busctl")
        .args([
            "--user",
            "call",
            DBUS_BUS_NAME,
            DBUS_OBJECT_PATH,
            DBUS_INTERFACE,
            "TileRightHalf",
        ])
        .status();
    match status {
        Ok(st) if st.success() => {
            logging::service("INFO", "tiled focused window to the right half")
        }
        Ok(st) => logging::service("ERROR", format!("D-Bus tiling failed: status {st}")),
        Err(err) => logging::service("ERROR", format!("D-Bus tiling failed: {err}")),
    }
}

fn stable_device_path(path: &Path) -> PathBuf {
    let Ok(resolved) = fs::canonicalize(path) else {
        return path.to_path_buf();
    };
    let by_id = Path::new("/dev/input/by-id");
    if let Ok(entries) = fs::read_dir(by_id) {
        let mut aliases: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.contains("event-mouse"))
                    && fs::canonicalize(p).ok().as_ref() == Some(&resolved)
            })
            .collect();
        aliases.sort();
        if let Some(first) = aliases.into_iter().next() {
            return first;
        }
    }
    path.to_path_buf()
}

fn is_back_pointer(device: &Device) -> bool {
    let keys = device.supported_keys();
    let rels = device.supported_relative_axes();
    let Some(keys) = keys else { return false };
    let Some(rels) = rels else { return false };
    let has_rel = rels.contains(RelativeAxisType::REL_X) && rels.contains(RelativeAxisType::REL_Y);
    let has_back = keys.contains(Key::KEY_BACK)
        || keys.contains(Key::BTN_SIDE)
        || keys.contains(Key::BTN_EXTRA);
    has_rel && has_back
}

/// Print `path|name` lines for back-button pointers (installer device picker).
pub fn list_pointers() -> i32 {
    let mut devices: Vec<(PathBuf, Device)> = evdev::enumerate().collect();
    devices.sort_by_key(|(path, _)| input_device_sort_key(&path.to_string_lossy()));
    for (path, device) in devices {
        let name = device.name().unwrap_or("").to_string();
        if name.contains("Keychron") || name.contains(VIRTUAL_DEVICE_NAME) {
            continue;
        }
        if !is_back_pointer(&device) {
            continue;
        }
        let stable = stable_device_path(&path);
        println!("{}|{name}", stable.display());
    }
    0
}

struct Watched {
    device: Device,
    path: String,
    grabbed: bool,
}

/// Run the tiler service until the process is stopped.
pub fn run() -> ! {
    logging::service("INFO", "running in direct D-Bus mode");
    let target = env::var("CTRL_BACK_TILE_DEVICE").unwrap_or_default();
    let mut logic = TilerLogic {
        ctrl_codes: configured_modifier_codes(),
        back_codes: configured_button_codes(),
        ..TilerLogic::default()
    };
    let mut watched: Vec<Watched> = Vec::new();
    let mut virtual_dev = None;
    let mut last_scan = Instant::now() - RESCAN_INTERVAL;
    let mut reported_missing = false;
    let mut pointer_path = target.clone();

    loop {
        if last_scan.elapsed() >= RESCAN_INTERVAL || watched.is_empty() {
            rescan(
                &target,
                &mut pointer_path,
                &mut reported_missing,
                &mut watched,
                &mut logic,
                &mut virtual_dev,
            );
            last_scan = Instant::now();
        }
        if watched.is_empty() {
            std::thread::sleep(RESCAN_INTERVAL);
            continue;
        }
        let mut fds = FdSet::new();
        let mut max_fd = 0;
        for entry in &watched {
            let fd = entry.device.as_raw_fd();
            fds.insert(fd);
            if fd > max_fd {
                max_fd = fd;
            }
        }
        let mut timeout = TimeVal::seconds(2);
        match select(max_fd + 1, Some(&mut fds), None, None, Some(&mut timeout)) {
            Ok(0) | Err(_) => continue,
            Ok(_) => {}
        }
        let ready: Vec<i32> = watched
            .iter()
            .map(|e| e.device.as_raw_fd())
            .filter(|fd| fds.contains(*fd))
            .collect();
        let mut disconnected = false;
        for fd in ready {
            let Some(idx) = watched.iter().position(|e| e.device.as_raw_fd() == fd) else {
                continue;
            };
            let events = match watched[idx].device.fetch_events() {
                Ok(iter) => iter.collect::<Vec<_>>(),
                Err(err) => {
                    logging::service("WARN", format!("device read failed: {err}"));
                    disconnected = true;
                    break;
                }
            };
            let path = watched[idx].path.clone();
            let grabbed = watched[idx].grabbed;
            for event in events {
                handle_live_event(&mut logic, &mut virtual_dev, &path, grabbed, event);
            }
        }
        if disconnected {
            watched.clear();
            if target.is_empty() {
                pointer_path.clear();
            }
        }
    }
}

fn handle_live_event(
    logic: &mut TilerLogic,
    virtual_dev: &mut Option<evdev::uinput::VirtualDevice>,
    path: &str,
    grabbed: bool,
    event: InputEvent,
) {
    let event_type = event.event_type().0;
    let code = event.code();
    let value = event.value();
    let tiles_before = logic.tile_calls;
    let forwarded_before = logic.forwarded.len();
    if event.event_type() == EventType::KEY {
        logic.handle_key(path, grabbed, code, value);
    } else {
        logic.handle_other(grabbed, event_type, code, value);
    }
    if logic.tile_calls > tiles_before {
        tile_right();
    }
    if logic.forwarded.len() > forwarded_before {
        if let Some(ui) = virtual_dev.as_mut() {
            let ev = InputEvent::new(event.event_type(), code, value);
            let syn = InputEvent::new(EventType::SYNCHRONIZATION, 0, 0);
            if ui.emit(&[ev, syn]).is_err() {
                logging::service(
                    "ERROR",
                    format!("could not forward input event {event_type}/{code}"),
                );
                *virtual_dev = None;
                logic.ui_ok = false;
            }
        }
    }
}

fn rescan(
    target: &str,
    pointer_path: &mut String,
    reported_missing: &mut bool,
    watched: &mut Vec<Watched>,
    logic: &mut TilerLogic,
    virtual_dev: &mut Option<evdev::uinput::VirtualDevice>,
) {
    let mut enumerated: Vec<(PathBuf, Device)> = evdev::enumerate().collect();
    enumerated.sort_by_key(|(path, _)| input_device_sort_key(&path.to_string_lossy()));
    let paths: Vec<String> = enumerated
        .iter()
        .map(|(p, _)| p.to_string_lossy().into_owned())
        .collect();
    let mut selected = select_pointer_path(
        target,
        pointer_path,
        &paths,
        |p| {
            fs::canonicalize(p)
                .map(|x| x.to_string_lossy().into_owned())
                .unwrap_or_else(|_| p.to_string())
        },
        reported_missing,
    );
    if selected.is_empty() && target.is_empty() {
        selected = find_pointer_path(&enumerated);
    }
    if !selected.is_empty() {
        *pointer_path = selected;
    }

    let open: HashSet<String> = watched.iter().map(|w| w.path.clone()).collect();
    let mut forward: HashSet<(u16, u16)> = logic.forward_codes.clone();
    for (path, mut device) in enumerated {
        let path_s = path.to_string_lossy().into_owned();
        if open.contains(&path_s) {
            continue;
        }
        let name = device.name().unwrap_or("").to_string();
        if name == VIRTUAL_DEVICE_NAME {
            continue;
        }
        let keys = device.supported_keys();
        let watches_ctrl = keys.is_some_and(|k| {
            logic
                .ctrl_codes
                .iter()
                .any(|code| k.iter().any(|key| key.code() == *code))
        });
        let is_pointer = path_s == *pointer_path;
        if !watches_ctrl && !is_pointer {
            continue;
        }
        let mut grabbed = false;
        if is_pointer {
            if !is_back_pointer(&device) {
                logging::service(
                    "WARN",
                    format!("{path_s} is not a back-button pointing device"),
                );
                pointer_path.clear();
                continue;
            }
            match device.grab() {
                Ok(()) => {
                    grabbed = true;
                    if let Some(keys) = device.supported_keys() {
                        for key in keys.iter() {
                            forward.insert((EV_KEY, key.code()));
                        }
                    }
                    if let Some(rels) = device.supported_relative_axes() {
                        for axis in rels.iter() {
                            forward.insert((EventType::RELATIVE.0, axis.0));
                        }
                    }
                }
                Err(err) => logging::service("ERROR", format!("could not grab {path_s}: {err}")),
            }
        }
        let mode = if grabbed {
            "grabbed pointer"
        } else {
            "Ctrl monitor"
        };
        logging::service("INFO", format!("watching {path_s}: {name} [{mode}]"));
        watched.push(Watched {
            device,
            path: path_s,
            grabbed,
        });
    }
    let caps_changed = logic.forward_codes != forward;
    logic.forward_codes = forward;
    if watched.iter().any(|w| w.grabbed) && (virtual_dev.is_none() || caps_changed) {
        *virtual_dev = open_virtual(&logic.forward_codes);
        logic.ui_ok = virtual_dev.is_some();
    }
}

/// Choose the first non-keyboard pointing node with a back button.
fn find_pointer_path(enumerated: &[(PathBuf, Device)]) -> String {
    for (path, device) in enumerated {
        let name = device.name().unwrap_or("");
        if name == VIRTUAL_DEVICE_NAME || name.contains("Keychron") {
            continue;
        }
        if is_back_pointer(device) {
            return path.to_string_lossy().into_owned();
        }
    }
    String::new()
}

fn open_virtual(forward: &HashSet<(u16, u16)>) -> Option<evdev::uinput::VirtualDevice> {
    let mut keys = evdev::AttributeSet::<Key>::new();
    let mut rels = evdev::AttributeSet::<RelativeAxisType>::new();
    let mut has_key = false;
    let mut has_rel = false;
    for (ty, code) in forward {
        if *ty == EV_KEY {
            keys.insert(Key::new(*code));
            has_key = true;
        } else if *ty == EventType::RELATIVE.0 {
            rels.insert(RelativeAxisType(*code));
            has_rel = true;
        }
    }
    if !has_key && !has_rel {
        return None;
    }
    let mut builder = VirtualDeviceBuilder::new().ok()?.name(VIRTUAL_DEVICE_NAME);
    if has_key {
        builder = builder.with_keys(&keys).ok()?;
    }
    if has_rel {
        builder = builder.with_relative_axes(&rels).ok()?;
    }
    match builder.build() {
        Ok(dev) => {
            logging::service("INFO", "opened virtual forwarding input device");
            Some(dev)
        }
        Err(err) => {
            logging::service(
                "ERROR",
                format!("could not open virtual forwarding input device: {err}"),
            );
            None
        }
    }
}

/// CLI: `tiler` or `list-pointers`.
pub fn run_cli(args: &[String]) -> i32 {
    match args.first().map(String::as_str) {
        None | Some("tiler") => run(),
        Some("list-pointers") => list_pointers(),
        Some(other) => {
            eprintln!("Usage: wss-tools tiler|list-pointers (got {other})");
            2
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn input_devices_are_sorted_by_numeric_event_suffix() {
        let mut paths = vec![
            "/dev/input/event13".to_string(),
            "/dev/input/event4".to_string(),
            "/dev/input/event6".to_string(),
        ];
        paths.sort_by_key(|p| input_device_sort_key(p));
        assert_eq!(
            paths,
            vec![
                "/dev/input/event4".to_string(),
                "/dev/input/event6".to_string(),
                "/dev/input/event13".to_string()
            ]
        );
    }

    #[test]
    fn configured_stable_pointer_path_is_resolved() {
        let mut reported = false;
        let selected = select_pointer_path(
            "/dev/input/by-id/razer-event-mouse",
            "",
            &["/dev/input/event4".into(), "/dev/input/event13".into()],
            |_| "/dev/input/event4".into(),
            &mut reported,
        );
        assert_eq!(selected, "/dev/input/event4");
    }

    #[test]
    fn missing_configured_pointer_does_not_fall_back() {
        let mut reported = false;
        let selected = select_pointer_path(
            "/dev/input/by-id/razer-event-mouse",
            "/dev/input/event4",
            &["/dev/input/event13".into()],
            |_| "/dev/input/event99".into(),
            &mut reported,
        );
        assert_eq!(selected, "");
        assert!(reported);
    }

    #[test]
    fn ctrl_back_is_consumed_and_tiles_once() {
        let mut tiler = TilerLogic::default();
        tiler.handle_key("/dev/input/keyboard", false, KEY_LEFTCTRL, 1);
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 1);
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 0);
        assert_eq!(tiler.tile_calls, 1);
        assert!(tiler.forwarded.is_empty());
        assert!(tiler.suppressed.is_empty());
    }

    #[test]
    fn plain_back_is_forwarded_to_applications() {
        let mut tiler = TilerLogic::default();
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 1);
        tiler.handle_key("/dev/input/mouse", true, BTN_SIDE, 0);
        assert_eq!(
            tiler.forwarded,
            vec![(EV_KEY, BTN_SIDE, 1), (EV_KEY, BTN_SIDE, 0)]
        );
    }
}
