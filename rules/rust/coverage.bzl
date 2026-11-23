"""`rust_coverage`: a cargo member's `:coverage`, llvm-cov's line and branch figures of the member's own sources under its own tests.

`cargo_package` (cargo.bzl) builds, for each of the member's test targets, the same test again with coverage counters (cargo_unit.bzl,
`coverage = True`: `-C instrument-coverage -Z coverage-options=branch`), and with them every library and binary of the workspace's members the
test links or runs; registry and git crates, build scripts and proc-macros are the plain build's, so they stay shared with it. Each such test is
run by `cov_run` (test_run.bzl): the same command as `:test`'s, the Postgres fixture included, with the profiles its programs write kept.

This rule merges the profiles of every run with the pinned `llvm-profdata` and reads them with the pinned `llvm-cov` (the llvm-tools component of
the same Rust release, rules/rust/pins.bzl) against the instrumented programs, in one action (rust_cov.zig). Its output is `coverage.txt`, the
text cov_summary writes for the Zig and Mojo packages (rules/coverage/README.md): a row per source file of the member (those under its `tests/`,
`benches/` and `examples/` shown and marked `(not counted)`), `total`, and the same rows of branch arms (`branches ...`, `branches total`).
`[lcov]` is llvm-cov's report of the same files. A member with a `coverage_floor.txt` beside its BUCK file also has `:coverage_floor`, which holds
the figures to it with `cov_floor`, the check of every other package (rules/coverage/zig_cover.bzl).

What is counted, and what is not:
  - a member's figures are its own tests' runs over its own sources (its directory, and its `extra_srcs`): code of the member that only
    another member's tests run counts as not run. A member nested in another's directory is the other's to count, not this one's.
  - a line is one llvm-cov line record; a branch is one arm of a decision llvm-cov records (`if`, `match` arms, `&&`, `||`, `?`), hit when taken.
  - code in a `#[cfg(test)]` module of a source is in that source, as in llvm-cov's own report; doctests are not run (as for `:test`).
"""

load(":providers.bzl", "RustCovRunInfo")
load(":pins.bzl", "RUST_TRIPLE")

def _impl(ctx):
    if ctx.attrs.llvm_tools == None:
        fail("{}: coverage needs the llvm-tools component (llvm-profdata, llvm-cov) of the Rust release the member compiles with, and buildrules pins none for {} (rules/rust/pins.bzl)".format(ctx.label.raw_target(), ctx.attrs.rustc))
    out = ctx.actions.declare_output("coverage.txt")
    lcov = ctx.actions.declare_output("coverage.lcov")
    tools = ctx.attrs.llvm_tools[DefaultInfo].default_outputs[0]
    bindir = "/lib/rustlib/" + RUST_TRIPLE + "/bin/"
    package = cmd_args(ctx.attrs.anchor, parent = 1)
    cmd = cmd_args(
        ctx.attrs._tool[RunInfo],
        "--profdata",
        cmd_args(tools, bindir + "llvm-profdata", delimiter = ""),
        "--llvm-cov",
        cmd_args(tools, bindir + "llvm-cov", delimiter = ""),
        "--package",
        package,
        "--out",
        out.as_output(),
        "--lcov",
        lcov.as_output(),
        "--branches",
        "yes" if ctx.attrs.branches else "no",
        hidden = [tools, ctx.attrs.anchor],
    )
    for d in ctx.attrs.exclude:
        cmd.add("--exclude", d)
    for e in ctx.attrs.extra:
        cmd.add("--extra", e)
    for r in ctx.attrs.runs:
        info = r[RustCovRunInfo]
        cmd.add("--profiles", info.profiles)
        for o in info.objects:
            cmd.add("--object", o)
    ctx.actions.run(cmd, category = "rust_coverage", identifier = ctx.label.name)
    info = [DefaultInfo(default_output = out, sub_targets = {"lcov": [DefaultInfo(default_output = lcov)]})]
    if ctx.attrs.check:
        info.append(ValidationInfo(validations = [
            ValidationSpec(name = "cargo_table_in_sync", validation_result = ctx.attrs.check[DefaultInfo].default_outputs[0]),
        ]))
    return info

rust_coverage = rule(
    impl = _impl,
    doc = "`coverage.txt` of a cargo member: llvm-cov's lines and branch arms of its sources under its instrumented test runs (see the file comment).",
    attrs = {
        # A file at the member's directory (its Cargo.toml): the directory, from the project root, whose sources are the member's.
        "anchor": attrs.source(),
        # The tests were built with branch counters (cargo.bzl `coverage_branches`): `coverage.txt` has `branches` rows only then.
        "branches": attrs.bool(default = True),
        # The workspace's `:check`, carried as a validation as by every other step of the member.
        "check": attrs.option(attrs.dep(), default = None),
        # Directories of members nested in this one's, relative to it: their sources are theirs.
        "exclude": attrs.list(attrs.string(), default = []),
        # The member's `extra_srcs`: sources outside its directory that it compiles, counted as its own.
        "extra": attrs.list(attrs.source(allow_directory = True), default = []),
        # The unpacked llvm-tools of the Rust release the member compiles with (its llvm-profdata and llvm-cov read that rustc's profiles).
        "llvm_tools": attrs.option(attrs.exec_dep(), default = None),
        # The Rust release the member compiles with (the table's, or the one a platform selects), for the refusal of one without llvm-tools.
        "rustc": attrs.string(default = ""),
        "runs": attrs.list(attrs.dep(providers = [RustCovRunInfo])),
        "_tool": attrs.exec_dep(default = "buildrules//rules/rust:rust_cov", providers = [RunInfo]),
    },
)
