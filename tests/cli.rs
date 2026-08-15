//! CLI contract formerly covered by tests/test_extension_assets.py.

use std::process::Command;

fn bin() -> Command {
    Command::new(env!("CARGO_BIN_EXE_wss-tools"))
}

#[test]
fn append_and_remove_round_trip() {
    let added = bin()
        .args(["append", "linux-workspaces-setup@local"])
        .env("CURRENT", "['a']")
        .output()
        .expect("append");
    assert!(
        added.status.success(),
        "stderr={}",
        String::from_utf8_lossy(&added.stderr)
    );
    let added_out = String::from_utf8_lossy(&added.stdout);
    assert!(added_out.contains("linux-workspaces-setup@local"));
    assert!(added_out.contains("'a'"));

    let removed = bin()
        .args(["remove", "linux-workspaces-setup@local"])
        .env("CURRENT", "['a', 'linux-workspaces-setup@local']")
        .output()
        .expect("remove");
    assert!(removed.status.success());
    assert_eq!(String::from_utf8_lossy(&removed.stdout).trim(), "['a']");
}

#[test]
fn rejects_wrong_usage() {
    let none = bin().output().expect("no args");
    assert_eq!(none.status.code(), Some(2));
    let bad = bin().args(["update", "x"]).output().expect("bad action");
    assert_eq!(bad.status.code(), Some(2));
}
