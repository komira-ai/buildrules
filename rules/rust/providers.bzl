"""Providers of the Rust rules.

Everything a provider carries is a list or a dict, never a transitive set: a tset's
type is per loading cell, and crates are used across cells (facebook/buck2#683).
"""

RustToolchainInfo = provider(fields = {
    "busybox": provider_field(typing.Any),
    # Directory: bin/rustc, lib/ (rustc's own libraries), lib/rustlib/<triple>/lib (std).
    "sysroot": provider_field(typing.Any),
    # Directory: the unpacked zig distribution, the link driver.
    "zig": provider_field(typing.Any),
    # zig -target for link steps.
    "cc_target": provider_field(str),
    # rustc_launch: runs rustc, and is the linker shim.
    "launcher": provider_field(typing.Any),
    # bs_runner: runs a build script (decision.md 6.1).
    "bs_runner": provider_field(typing.Any),
    # A file that exists only if the sysroot's `rustc --version` is the pinned line.
    "version_ok": provider_field(typing.Any),
    "version": provider_field(str),
    # Directory: bin/clippy-driver. It runs against `sysroot` (the launcher points LD_LIBRARY_PATH at its lib/).
    "clippy": provider_field(typing.Any),
})

RustCrateInfo = provider(fields = {
    "crate_name": provider_field(str),
    "lib": provider_field(typing.Any),
    # label string -> libC.rlib, this crate and everything it depends on, in order.
    "closure": provider_field(dict),
    # A proc-macro is loaded by rustc, not linked: dependents take `--extern` and none of its closure.
    "is_proc_macro": provider_field(bool, default = False),
    # Native archives (`native_deps` of this crate and of everything it depends on, each once): a binary or a test links them
    # after its rlibs. A list of artifacts, never a tset (see the header).
    "natives": provider_field(list, default = []),
})

# A run of a build script: one directory holding OUT_DIR/, rustc_args (an argument file, one
# argument per line), rustc_env (KEY=VALUE lines), metadata (KEY=VALUE lines, what dependents
# read as DEP_<LINKS>_<KEY>), rerun_if and directives. `links` is the package's `links` key ("" if none);
# `manifest` is the package directory the script ran in (a dependent's DEP_ paths may point into it).
BuildScriptInfo = provider(fields = {
    "dir": provider_field(typing.Any),
    "links": provider_field(str, default = ""),
    "manifest": provider_field(typing.Any, default = None),
    # The package files the run read (a dependent's DEP_* paths may point into them).
    "files": provider_field(list, default = []),
})

# A rust_test: the `.passed` marker its run writes. Only a passing run writes it.
RustTestInfo = provider(fields = {
    "marker": provider_field(typing.Any),
})

# What a compiled test binary hands to the target that runs it (test_run.bzl). The compile and the run are two targets so
# the run alone can ask for an execution platform with an ISA level (rules/isa.bzl).
TestUnitInfo = provider(fields = {
    "exe": provider_field(typing.Any),
    # Everything the run reads besides the binary: sources, data, the package's other binaries.
    "hidden": provider_field(list),
    "env": provider_field(dict),
    # How the binary is started, as the options of `check run`, `check marker` (rules/check) before the `--`: the environment made absolute, the
    # working directory, the scratch directory. The same for the build action and for `buck2 test`.
    "start": provider_field(list, default = []),
    # The options only the build action's `check marker` takes: how the marker is made (`--capture`, `--stamp-log`).
    "marker": provider_field(list, default = []),
    # True when the unit is a `buck2 test` target as well (a `check run` of the same binary, no marker).
    "cli": provider_field(bool, default = False),
    "labels": provider_field(list, default = []),
})

# The ISA level the execution platform of a rule reports (rules/rust/exec_isa.bzl): "x86-64" when it has none.
ExecIsaInfo = provider(fields = {"level": provider_field(str)})
