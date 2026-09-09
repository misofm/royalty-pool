//! Runs every JSON scenario under `scenarios/ported/` and
//! `scenarios/handwritten/` through the model, asserting every `expect`
//! block is met and no invariant is violated (TASKS-SONNET §5, §6 gate 2).
//!
//! This is model-only (no `sui move test`): see `README.md` for the `diff`
//! command that cross-checks the same corpus against real Move.

use std::path::{Path, PathBuf};

use royalty_sim::scenario;

fn manifest_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn run_all_in(dir: &Path) -> Vec<(String, bool, Vec<String>)> {
    let mut results = Vec::new();
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .unwrap_or_else(|e| panic!("reading {}: {e}", dir.display()))
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().map(|e| e == "json").unwrap_or(false))
        .collect();
    entries.sort();
    assert!(!entries.is_empty(), "no scenario files found in {}", dir.display());

    for path in entries {
        let file = scenario::load_scenario(&path)
            .unwrap_or_else(|e| panic!("loading {}: {e}", path.display()));
        let report = scenario::run_scenario(&file)
            .unwrap_or_else(|e| panic!("running {}: {e}", path.display()));
        let mismatches: Vec<String> = report
            .ops
            .iter()
            .filter(|o| !o.expect_ok)
            .map(|o| {
                format!(
                    "op #{} ({}): {}",
                    o.index,
                    o.op.op,
                    o.expect_message.clone().unwrap_or_default()
                )
            })
            .collect();
        results.push((report.name.clone(), report.passed, report.violations.clone().into_iter().chain(mismatches).collect()));
    }
    results
}

#[test]
fn ported_scenarios_pass() {
    let dir = manifest_dir().join("scenarios/ported");
    let results = run_all_in(&dir);
    let mut failed = Vec::new();
    for (name, passed, details) in &results {
        if !passed {
            failed.push(format!("{name}: {details:?}"));
        }
    }
    assert!(failed.is_empty(), "ported scenarios failed:\n{}", failed.join("\n"));
}

#[test]
fn handwritten_scenarios_pass() {
    let dir = manifest_dir().join("scenarios/handwritten");
    let results = run_all_in(&dir);
    let mut failed = Vec::new();
    for (name, passed, details) in &results {
        if !passed {
            failed.push(format!("{name}: {details:?}"));
        }
    }
    assert!(failed.is_empty(), "handwritten scenarios failed:\n{}", failed.join("\n"));
    // §6 gate 3 requires at least 12 handwritten scenarios.
    assert!(results.len() >= 12, "expected at least 12 handwritten scenarios, found {}", results.len());
}
