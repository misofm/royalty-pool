//! `royalty-sim` CLI (TASKS-SONNET §3). See README.md for usage.

use std::path::PathBuf;
use std::process::Command;

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};

use royalty_sim::fuzz::{self, ProfileName};
use royalty_sim::movegen;
use royalty_sim::scenario::{self, ScenarioFile};

#[derive(Parser)]
#[command(name = "royalty-sim", about = "Bit-exact simulator + differential oracle for the misofm royalty math")]
struct Cli {
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run scenarios, checking invariants after every op; print a JSON
    /// result per scenario.
    Run { scenarios: Vec<PathBuf> },
    /// Random-walk fuzzing under a named profile.
    Fuzz {
        #[arg(long)]
        seed: u64,
        #[arg(long)]
        ops: usize,
        #[arg(long)]
        profile: String,
        #[arg(long)]
        count: usize,
        /// Skip the first `skip` cases of this seed's sequence. Lets one
        /// seed's `--count` be sharded across processes: shard `i` of `n`
        /// runs `--skip i*count`. Case `i` always uses the same derived
        /// seed regardless of sharding, so results are reproducible.
        #[arg(long, default_value_t = 0)]
        skip: usize,
        #[arg(long)]
        out: Option<PathBuf>,
    },
    /// Dump `count` fuzz-generated scenarios as JSON, whether or not they
    /// violate anything, for a `diff` run against the real Move VM.
    Sample {
        #[arg(long)]
        seed: u64,
        #[arg(long)]
        ops: usize,
        #[arg(long)]
        profile: String,
        #[arg(long)]
        count: usize,
        #[arg(long)]
        out: PathBuf,
    },
    /// Generate Move tests for each scenario and run them with `sui move
    /// test`, reporting AGREE/DISAGREE per scenario.
    Diff {
        scenarios: Vec<PathBuf>,
        #[arg(long = "move-root")]
        move_root: PathBuf,
        #[arg(long)]
        out: Option<PathBuf>,
        /// Path to the `sui` binary (default: `sui` on PATH).
        #[arg(long, default_value = "sui")]
        sui: String,
    },
    /// Emit the generated Move test for one scenario without running it.
    GenMove {
        scenario: PathBuf,
        #[arg(long)]
        out: PathBuf,
    },
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Cmd::Run { scenarios } => cmd_run(&scenarios),
        Cmd::Fuzz { seed, ops, profile, count, skip, out } => cmd_fuzz(seed, ops, &profile, count, skip, out.as_deref()),
        Cmd::Sample { seed, ops, profile, count, out } => {
            let profile_name: ProfileName = profile.parse()?;
            let paths = fuzz::sample_scenarios(profile_name, &profile, seed, ops, count, &out)?;
            println!("wrote {} scenarios to {}", paths.len(), out.display());
            Ok(())
        }
        Cmd::Diff { scenarios, move_root, out, sui } => cmd_diff(&scenarios, &move_root, out.as_deref(), &sui),
        Cmd::GenMove { scenario, out } => cmd_gen_move(&scenario, &out),
    }
}

fn cmd_run(paths: &[PathBuf]) -> Result<()> {
    let mut any_failed = false;
    for path in paths {
        let file = scenario::load_scenario(path)?;
        let report = scenario::run_scenario(&file)?;
        if !report.passed {
            any_failed = true;
        }
        println!("{}", serde_json::to_string_pretty(&report)?);
    }
    if any_failed {
        bail!("one or more scenarios failed");
    }
    Ok(())
}

fn cmd_fuzz(seed: u64, ops: usize, profile: &str, count: usize, skip: usize, out: Option<&std::path::Path>) -> Result<()> {
    let profile_name: ProfileName = profile.parse()?;
    let report = fuzz::run_fuzz(profile_name, profile, seed, ops, count, skip);
    println!(
        "profile={} seed={} runs={} ops_per_run={} failures={} max_ic4_error={} (<= {} units)",
        report.profile, report.seed, report.runs, ops, report.failures, report.max_ic4_error, report.max_ic4_error_units
    );
    let t = &report.telemetry;
    println!(
        "  telemetry: ops_applied={} aborts={} max_carry={} max_index_bits={} max_amount_index_bits={} max_forfeited_units={} max_carry_drift_abs={} max_staked_shares={} max_balance={}",
        t.ops_applied,
        t.aborts,
        t.max_carry,
        t.max_index_bits,
        t.max_amount_index_bits,
        t.max_forfeited_units,
        t.max_carry_drift_abs,
        t.max_staked_shares,
        t.max_balance,
    );
    if let Some((mseed, mops, violation)) = report.minimized {
        println!("minimized failure (seed {mseed}, {} ops): {violation}", mops.len());
        if let Some(dir) = out {
            let path = fuzz::dump_scenario(dir, profile, mseed, mops)?;
            println!("wrote minimized scenario to {}", path.display());
        }
        bail!("fuzz found {} violation(s) out of {} runs", report.failures, report.runs);
    }
    Ok(())
}

fn cmd_gen_move(scenario_path: &std::path::Path, out: &std::path::Path) -> Result<()> {
    let file = scenario::load_scenario(scenario_path)?;
    let module = movegen::generate(&file)?;
    if let Some(parent) = out.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(out, module.source)?;
    println!("wrote {} test(s) to {}", module.tests.len(), out.display());
    Ok(())
}

fn cmd_diff(paths: &[PathBuf], move_root: &std::path::Path, out: Option<&std::path::Path>, sui: &str) -> Result<()> {
    let gen_dir = move_root.join("routed-stake").join("tests").join("gen");
    std::fs::create_dir_all(&gen_dir)?;

    struct Planned {
        scenario_name: String,
        module_name: String,
        tests: Vec<movegen::GeneratedTest>,
        error: Option<String>,
    }

    let mut planned = Vec::new();
    for path in paths {
        let file: ScenarioFile = scenario::load_scenario(path)?;
        let file_path = gen_dir.join(format!("{}.move", movegen::ident(&file.name)));
        match movegen::generate(&file) {
            Ok(module) => {
                std::fs::write(&file_path, &module.source)
                    .with_context(|| format!("writing {}", file_path.display()))?;
                planned.push(Planned {
                    scenario_name: file.name.clone(),
                    module_name: module.module_name,
                    tests: module.tests,
                    error: None,
                });
            }
            Err(e) => {
                planned.push(Planned {
                    scenario_name: file.name.clone(),
                    module_name: String::new(),
                    tests: vec![],
                    error: Some(e.to_string()),
                });
            }
        }
    }

    let routed_dir = move_root.join("routed-stake");
    let output = Command::new(sui)
        .arg("move")
        .arg("test")
        // Positional filter (this `sui` build rejects `--filter`): matches
        // by substring against the fully-qualified test name.
        .arg("royalty_sim_gen")
        .current_dir(&routed_dir)
        .output()
        .with_context(|| format!("running `{sui} move test` in {}", routed_dir.display()))?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let combined = format!("{stdout}\n{stderr}");

    // A generated function that overruns Move's 255-locals-per-function
    // budget (`LOCAL_INDEX_MAX`) makes `move-compiler` *panic* rather than
    // emit a diagnostic, and that kills the whole package build -- so every
    // *other* scenario in the same batch would otherwise be reported as a
    // bogus `DISAGREE ... not found in output`. Detect it and say so.
    if combined.contains("cannot exceed (255)") || combined.contains("compiled_unit.rs") {
        let n = combined
            .split("value (")
            .nth(1)
            .and_then(|t| t.split(')').next())
            .unwrap_or("?")
            .to_string();
        bail!(
            "the Move package failed to BUILD, so no scenario in this batch was actually run: \
             a generated test function needs {n} local slots but Move allows 255 \
             (`LOCAL_INDEX_MAX`). This is a size limit of the generator, not a \
             disagreement. Split the offending scenario (empirically ~85 ops is the \
             ceiling for a take_shared/op/return_shared scenario) and re-run."
        );
    }

    let mut any_disagree = false;
    for p in &planned {
        if let Some(err) = &p.error {
            println!("SKIP  {} (movegen: {err})", p.scenario_name);
            continue;
        }
        let mut agree = true;
        let mut detail = String::new();
        for t in &p.tests {
            let passed_line = format!("[ PASS    ] routed_stake::{}::{}", p.module_name, t.fn_name);
            let fail_marker = format!("::{}", t.fn_name);
            if combined.contains(&passed_line) {
                continue;
            }
            // Search any line mentioning this test function for a
            // pass/fail marker, since sui's exact module path formatting
            // can vary by version.
            let mut found = false;
            for line in combined.lines() {
                if line.contains(&fail_marker) && (line.contains("PASS") || line.contains("FAIL")) {
                    found = true;
                    if line.contains("FAIL") {
                        agree = false;
                        detail.push_str(line);
                        detail.push('\n');
                    }
                }
            }
            if !found {
                agree = false;
                detail.push_str(&format!("test `{}` not found in `sui move test` output\n", t.fn_name));
            }
        }
        if agree {
            println!("AGREE {}", p.scenario_name);
        } else {
            any_disagree = true;
            println!("DISAGREE {} -- {}", p.scenario_name, detail.trim());
        }
    }

    if let Some(dir) = out {
        std::fs::create_dir_all(dir)?;
        std::fs::write(dir.join("sui-move-test.stdout.txt"), stdout.as_bytes())?;
        std::fs::write(dir.join("sui-move-test.stderr.txt"), stderr.as_bytes())?;
    }

    if !output.status.success() && any_disagree {
        bail!("sui move test reported failures; see DISAGREE lines above");
    }
    if any_disagree {
        bail!("one or more scenarios disagreed with Move");
    }
    Ok(())
}

