//! Installed process entry for the native app-rule serializer.
mod app_rules;

/// Delegate process arguments to the app-rule command dispatcher.
/// Parameters: none.
/// Returns: exits with the command status.
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(app_rules::run(&args));
}
