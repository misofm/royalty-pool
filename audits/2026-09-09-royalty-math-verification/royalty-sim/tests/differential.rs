//! TASKS-SONNET §4: "make one handwritten scenario's differential run part
//! of `cargo test` only if it finishes in under a minute, otherwise expose
//! it through the CLI and document the command."
//!
//! It does finish well under a minute (~10s for the whole 16-scenario
//! corpus once the Move framework deps are cached locally in `~/.move`) --
//! see README.md for the full `diff` command over every scenario. This test
//! runs just the single smallest one (`single-staker`) so `cargo test`
//! itself stays fast; it locates `sui` by (1) `$ROYALTY_SIM_SUI`, (2) the
//! path this scratchpad environment's task description pinned
//! (`../bin/sui` relative to this crate), (3) `sui` on `$PATH`. If none of
//! those exist (e.g. a CI image without the framework deps cached), the test
//! prints why and passes trivially rather than failing on missing
//! infrastructure -- the full command is documented in README.md for anyone
//! who wants to run it explicitly.

use std::path::PathBuf;
use std::process::Command;

fn manifest_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn find_sui() -> Option<PathBuf> {
    if let Ok(p) = std::env::var("ROYALTY_SIM_SUI") {
        let p = PathBuf::from(p);
        if p.exists() {
            return Some(p);
        }
    }
    let scratchpad_sui = manifest_dir().join("../../bin/sui");
    if scratchpad_sui.exists() {
        return Some(scratchpad_sui);
    }
    if let Ok(path_var) = std::env::var("PATH") {
        for dir in std::env::split_paths(&path_var) {
            let candidate = dir.join("sui");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }
    None
}

#[test]
fn single_staker_agrees_with_move() {
    let Some(sui) = find_sui() else {
        eprintln!("skipping: no `sui` binary found (set $ROYALTY_SIM_SUI, or see README.md)");
        return;
    };

    let dir = manifest_dir();
    let scenario = dir.join("scenarios/handwritten/01-single-staker.json");
    let move_root = dir.join("move");

    let output = Command::new(env!("CARGO_BIN_EXE_royalty-sim"))
        .arg("diff")
        .arg(&scenario)
        .arg("--move-root")
        .arg(&move_root)
        .arg("--sui")
        .arg(&sui)
        .output()
        .expect("running royalty-sim diff");

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stdout.contains("AGREE single-staker"),
        "expected AGREE single-staker in output.\nstdout:\n{stdout}\nstderr:\n{stderr}"
    );
}
