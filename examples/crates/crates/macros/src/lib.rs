//! macros: one use of each of three widely used proc-macro crates.
//!
//! `Host` derives serde's traits (serde_derive), `Args` derives clap's parser (clap_derive), and `sum_on_tasks` is made a blocking function
//! by `#[tokio::main]` (tokio-macros). The tests (`tests/macros.rs`) also use `#[tokio::test]`.

use clap::Parser;
use serde::{Deserialize, Serialize};

/// A host as a configuration file writes it: `os` is the field's name in the file, `slots` may be left out.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Host {
    pub name: String,
    #[serde(rename = "os")]
    pub family: Family,
    #[serde(default = "one_slot")]
    pub slots: u32,
}

fn one_slot() -> u32 {
    1
}

/// The operating system of a host, written in lower case.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Family {
    Linux,
    Macos,
}

/// A command line: a required option, an option with a default, and a flag.
#[derive(Debug, PartialEq, Eq, Parser)]
#[command(name = "fixture")]
pub struct Args {
    /// The host to act on.
    #[arg(long)]
    pub host: String,
    /// How many jobs run at once.
    #[arg(long, default_value_t = 4)]
    pub jobs: u32,
    /// Say what would run, and run nothing.
    #[arg(long)]
    pub dry_run: bool,
}

/// The sum of `values`, each returned by a task of its own on a current-thread runtime that `#[tokio::main]` makes for the call.
#[tokio::main(flavor = "current_thread")]
pub async fn sum_on_tasks(values: Vec<u64>) -> u64 {
    let tasks: Vec<_> = values.into_iter().map(|v| tokio::spawn(async move { v })).collect();
    let mut total = 0;
    for task in tasks {
        total += task.await.expect("a task that returns its value does not panic");
    }
    total
}
