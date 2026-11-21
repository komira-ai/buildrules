//! Reads what two dependencies with `links` published (DEP_<LINKS>_<KEY>) and hands it to the library as rustc-env values.

use std::env;
use std::fs;
use std::path::Path;

/// The value of `name`, which cargo sets from the metadata of a dependency with `links`; the run fails without it.
fn dep(name: &str) -> String {
    env::var(name).unwrap_or_else(|_| panic!("{name} is not set: the metadata of a dependency with `links` did not reach this build script"))
}

/// `MAJOR.MINOR.RELEASE` from the `#define ZSTD_VERSION_*` lines of zstd.h.
fn header_version(header: &str) -> String {
    let part = |key: &str| {
        header
            .lines()
            .find_map(|l| l.strip_prefix("#define ").and_then(|l| l.strip_prefix(key)).map(str::trim))
            .unwrap_or_else(|| panic!("zstd.h has no #define {key}"))
            .to_owned()
    };
    format!("{}.{}.{}", part("ZSTD_VERSION_MAJOR "), part("ZSTD_VERSION_MINOR "), part("ZSTD_VERSION_RELEASE "))
}

fn main() {
    println!("cargo::rustc-env=LINKUSER_GREETING={}", dep("DEP_FIXTURE_LINKED_GREETING"));
    let include = dep("DEP_ZSTD_INCLUDE");
    let header = fs::read_to_string(Path::new(&include).join("zstd.h")).unwrap_or_else(|e| panic!("{include}/zstd.h: {e}"));
    println!("cargo::rustc-env=LINKUSER_ZSTD_HEADER_VERSION={}", header_version(&header));
}
