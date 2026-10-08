//! Public native lifecycle list filtering checks.
use std::process::Command;

#[test]
/// Remove all substring matches while retaining unrelated ordered entries.
/// Parameters: none.
/// Returns: None.
fn filter_fragment_matches_original() {
    for current in ["['keep', 'albert-aring', 'prefix-albert-aring', 'second']"] {
        let output = Command::new(env!("CARGO_BIN_EXE_wss-tools"))
            .args(["remove-containing", "albert-aring"])
            .env("CURRENT", current)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(output.stdout, b"['keep', 'second']\n");
    }
    for current in ["", "not a list"] {
        let output = Command::new(env!("CARGO_BIN_EXE_wss-tools"))
            .args(["remove-containing", "albert-aring"])
            .env("CURRENT", current)
            .output()
            .unwrap();
        assert_eq!(output.status.code(), Some(0));
        assert_eq!(output.stdout, b"[]\n");
    }
    for args in [
        vec!["remove-containing"],
        vec!["remove-containing", "x", "extra"],
    ] {
        let rejected = Command::new(env!("CARGO_BIN_EXE_wss-tools"))
            .args(args)
            .env("CURRENT", "['keep', 'albert-aring']")
            .output()
            .unwrap();
        assert_eq!(rejected.status.code(), Some(2));
        let observation = Command::new(env!("CARGO_BIN_EXE_wss-tools"))
            .args(["append", "keep"])
            .env("CURRENT", "['keep', 'albert-aring']")
            .output()
            .unwrap();
        assert_eq!(observation.status.code(), Some(0));
        assert_eq!(observation.stdout, b"['keep', 'albert-aring']\n");
    }
}
