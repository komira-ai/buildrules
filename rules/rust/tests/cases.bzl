"""Tables and the recorder the toolchain-refusal targets of BUCK are made from, and the inputs of the `:fmt` plan cases (a BUCK file may not define functions)."""

load("//rules/rust:cargo.bzl", "check_toolchain")
load("//rules/rust:fmt.bzl", "fmt_plan", "workspace_fmt_config")
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

def same(what, got, want):
    """[] when `got == want`, else the one mismatch: a list `refusal_test(none = True)` is green on only when it is empty."""
    return [] if got == want else ["{}: got {}, want {}".format(what, got, want)]

def unit(root, edition = "2021"):
    """The part of a table unit `fmt_plan` reads."""
    return {"crate_root": root, "edition": edition}

def fmt_plan_of(units, discovered = [], configs = []):
    """(plan, refusals): what `fmt_plan` makes of a member with these units, discovered roots and configs."""
    got, refuse = recording()
    plan = fmt_plan(units, discovered, configs, refuse = refuse)
    return plan, got

def fmt_refusals(units, discovered = [], configs = []):
    return fmt_plan_of(units, discovered, configs)[1]

def fmt_plan_mismatch(units, discovered, configs, want):
    """[] when `fmt_plan` accepts and makes `want`, else what differs (a refusal counts as a difference)."""
    plan, got = fmt_plan_of(units, discovered, configs)
    return got + same("fmt_plan", plan, want)

def ws_config_of(members, configs):
    """(config, refusals): what `workspace_fmt_config` makes of a workspace with these member directories and found configs."""
    got, refuse = recording()
    conf = workspace_fmt_config(members, configs, refuse = refuse)
    return conf, got
