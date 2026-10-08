//! Public native app-rule writer/readers against independent merge expectations.
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

const LAYOUT: &str =
    "1\tDP-4\tPanel\t1\t0\t0\t3840\t2160\n2\tHDMI-0\tPanel\t0\t3840\t0\t2560\t1440\n";

/// Create fresh isolated file state for one public sequence.
/// Parameters: label - independent case identifier.
/// Returns: new fixture directory.
fn fixture(label: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!("wss-{label}-{}", std::process::id()));
    fs::create_dir_all(&path).unwrap();
    path
}

/// Invoke the delivered app-rule public CLI.
/// Parameters: file - rules destination; args - operation and flags.
/// Returns: captured process status and output.
fn run(file: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_app-rules-rules"))
        .arg("--file")
        .arg(file)
        .args(args)
        .output()
        .unwrap()
}

/// Assert both currently exposed dimensions immediately after a rejection.
/// Parameters: file - seeded rules destination; original - independently required file bytes.
/// Returns: None.
fn observe(file: &Path, original: &[u8]) {
    let sticky = run(file, &["list-sticky"]);
    assert_eq!(sticky.status.code(), Some(0));
    assert_eq!(sticky.stdout, b"code.desktop\n");
    let monitors = run(file, &["list-monitors"]);
    assert_eq!(monitors.status.code(), Some(0));
    assert_eq!(monitors.stdout, b"code.desktop\t2\n");
    assert_eq!(fs::read(file).unwrap(), original);
}

#[test]
/// Merge case-insensitive groups once and preserve exact original JSON bytes.
/// Parameters: none.
/// Returns: None.
fn merge_dimensions_and_original_serialization() {
    let root = fixture("merge");
    let file = root.join("nested/user-rules.json");
    let written = run(
        &file,
        &[
            "write",
            "--managed-sticky",
            "--sticky",
            "spotify.desktop|spotify_spotify.desktop;éditeur.desktop",
            "--managed-monitors",
            "--monitors",
            "spotify_spotify.desktop|SPOTIFY.desktop=2;discord.desktop=1",
            "--monitor-layout",
            LAYOUT,
        ],
    );
    assert_eq!(
        written.status.code(),
        Some(0),
        "{}",
        String::from_utf8_lossy(&written.stderr)
    );
    assert_eq!(written.stdout, b"3 rule(s): 2 sticky, 2 monitor\n");
    assert_eq!(
        fs::read_to_string(&file).unwrap(),
        include_str!("fixtures/app_rules_write.json")
    );
    let doc: serde_json::Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
    assert_eq!(doc["rules"][0]["sticky"], true);
    assert_eq!(doc["rules"][0]["monitor"], 2);
    assert_eq!(doc["rules"][0]["monitorConnector"], "HDMI-0");
    assert_eq!(doc["rules"][0]["monitorGeometry"]["x"], 3840);
    for _ in 0..2 {
        assert_eq!(
            run(&file, &["list-sticky"]).stdout,
            "spotify.desktop\nspotify_spotify.desktop\néditeur.desktop\n".as_bytes()
        );
        assert_eq!(
            run(&file, &["list-monitors"]).stdout,
            b"spotify.desktop|spotify_spotify.desktop\t2\ndiscord.desktop\t1\n"
        );
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
/// Preserve the unmanaged dimension and remember explicit monitor clearing.
/// Parameters: none.
/// Returns: None.
fn independent_dimension_edits_and_explicit_clearing() {
    let root = fixture("dimensions");
    let file = root.join("rules.json");
    fs::write(&file, r#"{"rules":[{"appIds":["code.desktop"],"sticky":true},{"appIds":["spotify.desktop"],"monitor":1,"monitorConnector":"DP-4","monitorGeometry":{"x":0}}]}"#).unwrap();
    assert_eq!(
        run(
            &file,
            &["write", "--managed-sticky", "--sticky", "discord.desktop"]
        )
        .stdout,
        b"2 rule(s): 1 sticky, 1 monitor\n"
    );
    assert_eq!(run(&file, &["list-sticky"]).stdout, b"discord.desktop\n");
    assert_eq!(
        run(&file, &["list-monitors"]).stdout,
        b"spotify.desktop\t1\n"
    );
    let preserved: serde_json::Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
    assert_eq!(preserved["rules"][0]["monitorGeometry"]["x"], 0);
    assert_eq!(
        run(&file, &["write", "--managed-monitors", "--monitors", ""]).stdout,
        b"1 rule(s): 1 sticky, 0 monitor\n"
    );
    assert_eq!(run(&file, &["list-sticky"]).stdout, b"discord.desktop\n");
    assert_eq!(
        run(
            &file,
            &["list-monitors", "--legacy-defaults", "spotify.desktop=1"]
        )
        .stdout,
        b""
    );
    assert_eq!(
        run(
            &file,
            &["write", "--managed-sticky", "--sticky", "code.desktop"]
        )
        .status
        .code(),
        Some(0)
    );
    let doc: serde_json::Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
    assert_eq!(
        doc["managed"],
        serde_json::json!({"sticky":true,"monitors":true})
    );
    assert_eq!(
        run(
            &file,
            &["list-monitors", "--legacy-defaults", "spotify.desktop=1"]
        )
        .stdout,
        b""
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
/// Overlay legacy defaults once while existing case-insensitive groups win.
/// Parameters: none.
/// Returns: None.
fn legacy_defaults_and_invalid_read_documents() {
    let root = fixture("legacy");
    let file = root.join("rules.json");
    for document in [None, Some("not json"), Some("[]"), Some(r#"{"rules":{}}"#)] {
        if let Some(text) = document {
            fs::write(&file, text).unwrap();
        }
        let read = run(&file, &["list-sticky"]);
        assert_eq!(read.status.code(), Some(0));
        assert!(read.stdout.is_empty());
        assert_eq!(
            run(
                &file,
                &["list-monitors", "--legacy-defaults", "spotify.desktop=1"]
            )
            .stdout,
            b"spotify.desktop\t1\n"
        );
    }
    fs::write(&file, r#"{"rules":[null,{"appIds":["SPOTIFY.desktop"],"monitor":2},{"appIds":"invalid","sticky":true}]}"#).unwrap();
    assert_eq!(
        run(
            &file,
            &[
                "list-monitors",
                "--legacy-defaults",
                "spotify.desktop=1;discord.desktop=1"
            ]
        )
        .stdout,
        b"SPOTIFY.desktop\t2\ndiscord.desktop\t1\n"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
/// Skip malformed assignments and layout rows without losing valid selections.
/// Parameters: none.
/// Returns: None.
fn assignment_and_layout_validation_matches_original() {
    let root = fixture("validation");
    let file = root.join("rules.json");
    let write = run(
        &file,
        &[
            "write",
            "--managed-monitors",
            "--monitors",
            "bad;zero=0;negative=-1;text=bad;=2;valid.desktop= +0_2 ;other.desktop=1",
            "--monitor-layout",
            "bad\n2\tDP-2\tname\t0\tinvalid\t0\t100\t100\n",
        ],
    );
    assert_eq!(write.status.code(), Some(0));
    assert_eq!(write.stdout, b"2 rule(s): 0 sticky, 2 monitor\n");
    assert_eq!(
        run(&file, &["list-monitors"]).stdout,
        b"valid.desktop\t2\nother.desktop\t1\n"
    );
    let doc: serde_json::Value = serde_json::from_slice(&fs::read(&file).unwrap()).unwrap();
    assert!(doc["rules"][0].get("monitorConnector").is_none());
    fs::remove_dir_all(root).unwrap();
}

#[test]
/// Reject missing/extra/unknown CLI operands and preserve both seeded dimensions.
/// Parameters: none.
/// Returns: None.
fn rejected_shapes_and_failed_write_preserve_state() {
    let root = fixture("reject");
    let file = root.join("rules.json");
    let original = br#"{"managed":{"monitors":true},"rules":[{"appIds":["code.desktop"],"sticky":true,"monitor":2}]}"#;
    fs::write(&file, original).unwrap();
    for args in [
        vec![],
        vec!["unknown"],
        vec!["list-sticky", "extra"],
        vec!["list-monitors", "--legacy-defaults"],
        vec!["write", "--sticky"],
        vec!["write", "--monitors"],
        vec!["write", "--monitor-layout"],
        vec!["write", "--managed-sticky", "extra"],
        vec!["write", "--sticky", "--managed-monitors"],
    ] {
        assert_eq!(run(&file, &args).status.code(), Some(2));
        observe(&file, original);
    }
    for args in [
        vec![],
        vec!["--file"],
        vec!["write"],
        vec!["--file", "--help", "write"],
    ] {
        let rejected = Command::new(env!("CARGO_BIN_EXE_app-rules-rules"))
            .args(args)
            .output()
            .unwrap();
        assert_eq!(rejected.status.code(), Some(2));
        observe(&file, original);
    }
    let blocked = root.join("blocker");
    fs::write(&blocked, b"unchanged").unwrap();
    assert_eq!(
        run(
            &blocked.join("rules.json"),
            &["write", "--managed-sticky", "--sticky", "other.desktop"]
        )
        .status
        .code(),
        Some(1)
    );
    observe(&file, original);
    assert_eq!(fs::read(blocked).unwrap(), b"unchanged");
    fs::remove_dir_all(root).unwrap();
}
