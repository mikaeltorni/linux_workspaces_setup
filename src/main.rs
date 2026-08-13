//! `wss-tools` — installer helpers and the window-placement tiler.
//!
//! ```text
//! CURRENT="['a']" wss-tools append monitor-window-hotkeys@local
//! wss-tools list-pointers
//! wss-tools tiler
//! ```

mod gsettings_strv;
mod logging;
mod tiler;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let code = match args.first().map(String::as_str) {
        Some("tiler") | Some("list-pointers") => tiler::run_cli(&args),
        _ => gsettings_strv::run_cli(),
    };
    std::process::exit(code);
}
