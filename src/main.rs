//! `wss-tools` — installer-facing GSettings string-array helper.
//!
//! ```text
//! CURRENT="['a']" wss-tools append monitor-window-hotkeys@local
//! CURRENT="['a', 'x']" wss-tools remove x
//! ```

mod gsettings_strv;
mod logging;

fn main() {
    std::process::exit(gsettings_strv::run_cli());
}
