//! Embeds the commit this crate is built from, in the usual way of a stamp script.
//!
//! `FIXTURE_BUILD_COMMIT` is `git rev-parse --short=12 HEAD` in the checkout, or `unknown` where that fails (a source archive, no `git`).
//! `FIXTURE_GIVEN_COMMIT` is the variable `FIXTURE_BUILD_COMMIT_OVERRIDE` when it is set, or `unknown`. Under buildrules both come from the
//! stamp the BUCK file gives (`stamp_rustc_env` replaces the first value, `stamp_env` sets the variable): the run has no `git`.

#[path = "../../shared/stamp.rs"]
mod stamp;

use std::process::Command;

/// `git` with `args` in this crate's directory: its trimmed stdout, if it succeeded.
fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    let text = String::from_utf8(out.stdout).ok()?;
    out.status.success().then(|| text.trim().to_owned())
}

fn main() {
    let commit = git(&["rev-parse", "--short=12", "HEAD"]).filter(|c| !c.is_empty());
    println!("cargo:rustc-env=FIXTURE_BUILD_COMMIT={}", commit.as_deref().unwrap_or(stamp::UNKNOWN));
    println!("cargo:rerun-if-env-changed={}", stamp::OVERRIDE);
    let given = std::env::var(stamp::OVERRIDE).ok().filter(|c| !c.is_empty());
    println!("cargo:rustc-env=FIXTURE_GIVEN_COMMIT={}", given.as_deref().unwrap_or(stamp::UNKNOWN));
}
