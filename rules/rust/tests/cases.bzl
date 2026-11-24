"""Tables and the recorder the toolchain-refusal targets of BUCK are made from, the inputs of the `:fmt` plan cases, of the dependency-edge cases and of
the source-glob cases (a BUCK file may not define functions)."""

load("//rules/rust:cargo.bzl", "check_coverage_toolchain", "check_toolchain", "globs_for", "unit_deps")
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

def coverage_refused(rustc):
    """What `check_coverage_toolchain` says about a table of rustc `rustc`: a list of reasons, empty if it accepts."""
    got, refuse = recording()
    check_coverage_toolchain(rustc, refuse)
    return got

def same(what, got, want):
    """[] when `got == want`, else the one mismatch: a list `refusal_test(none = True)` is green on only when it is empty."""
    return [] if got == want else ["{}: got {}, want {}".format(what, got, want)]

# Rust editions by name, for the `:fmt` plan cases (a year-like literal on a line that does not say "edition" is a date to tools/scrub).
OLD_EDITION = "2018"
MID_EDITION = "2021"
NEW_EDITION = "2024"

def unit(root, edition = MID_EDITION):
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

# ---- the dependency edges of a unit (cargo.bzl, `unit_deps`) ----------------------------------------------------------------------------------------------

def edge_unit(mode, deps = [], kind = "lib", name = "pkg", links = None):
    """The part of a table unit `unit_deps` reads: `deps` as [extern name, unit id], in the table's order."""
    u = {"crate": "pkg", "mode": mode, "target_kind": [kind], "target_name": name, "deps": deps}
    if links:
        u["links"] = links
    return u

def edges_of(u, units):
    """(edges, refusals): what `unit_deps` makes of `u`, a unit's label being ":" and its id."""
    got, refuse = recording()
    e = unit_deps(u, units, lambda did: ":" + did, refuse = refuse)
    return e, got

def edges_mismatch(u, units, want):
    """[] when `unit_deps` accepts `u` and makes `want`, else what differs (a refusal counts as a difference)."""
    e, got = edges_of(u, units)
    return got + same("unit_deps", e, want)

def edge_refusals(u, units):
    return edges_of(u, units)[1]

# ---- the sources of a member's unit (cargo.bzl, `globs_for`) ----------------------------------------------------------------------------------------------

def globs_mismatch(cases):
    """[] when `globs_for` gives each unit of `cases` (target kind, crate root, wanted globs) the wanted globs, in order, else every difference."""
    out = []
    for kind, root, want in cases:
        out += same("globs_for({} {})".format(kind, root), globs_for({"target_kind": [kind], "crate_root": root}), want)
    return out
