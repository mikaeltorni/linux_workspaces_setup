//! `wss-tools` — workspace installer helpers.
//!
//! ```text
//! CURRENT="['a']" wss-tools append monitor-window-hotkeys@local
//! ```

mod gsettings_strv;
mod logging;

fn main() {
    let code = gsettings_strv::run_cli();
    std::process::exit(code);
}
