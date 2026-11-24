//! A program the package's integration test runs (tests/hook.rs), kept with that test: its `[[bin]] path` is under tests/.
//! It prints the reply to the event named by its one argument, or says how to call it (status 2).

use std::process::ExitCode;

fn main() -> ExitCode {
    match std::env::args().nth(1).as_deref().and_then(hook::reply) {
        Some(line) => {
            println!("{line}");
            ExitCode::SUCCESS
        }
        None => {
            eprint!("{}", hook::USAGE);
            ExitCode::from(2)
        }
    }
}
