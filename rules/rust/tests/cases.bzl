"""Tables and the recorder the toolchain-refusal targets of BUCK are made from (a BUCK file may not define functions)."""

load("//rules/rust:cargo.bzl", "check_toolchain")
load("//rules/rust:pins.bzl", "RUST_DEFAULT", "RUST_VERSIONS")
load("//rules/rust:refusal.bzl", "recording")

_COMPONENTS = ["rustc", "rust_std", "cargo", "clippy"]

def table(rustc, origin, sha = None):
    """The part of a generated table `check_toolchain` reads. `sha` defaults to the pinned hashes of `rustc`, or made-up ones."""
    row = RUST_VERSIONS.get(rustc)
    hashes = sha or ({k: row[k]["sha256"] for k in _COMPONENTS} if row else {k: "ab" * 32 for k in _COMPONENTS})
    return {"RUSTC": rustc, "TOOLCHAIN": {"version": rustc, "origin": origin, "default": rustc == RUST_DEFAULT, "sha256": hashes}}

def refused(tbl):
    """What `check_toolchain` says about `tbl`: a list of reasons, empty if it accepts."""
    got, refuse = recording()
    check_toolchain(tbl, refuse)
    return got
