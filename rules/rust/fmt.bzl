"""`:fmt`: the pinned `rustfmt --check` over the files of a cargo member, the files `cargo fmt --check -p <member>` reads, red on any difference.

`cargo fmt` hands rustfmt the root file of every target of the package (lib, bins, tests, examples, benches, build script) with the package's edition, and
rustfmt follows the `mod` declarations from each. `:fmt` hands it the same roots: those of the member's units in the generated table, and every file at one of
cargo's conventional target paths (`AUTO_ROOTS`), which also covers the examples and benches the table has no unit for. One action per edition runs

    check marker --out <marker> --capture --stamp formatted --clear-env --ld-library-path <sysroot>/lib -- <rustfmt>/bin/rustfmt --check --edition <E> --config-path <config> <roots>...

with every `.rs` file of the package (and its `extra_srcs`) as inputs. rustfmt prints the difference and exits 1 when a file is not formatted; `check marker`
(rules/check) then writes no marker and shows that output, so the build is red. A file that does not parse is red the same way.

The config: rustfmt reads, for each root, the first `.rustfmt.toml` or `rustfmt.toml` it finds in the root's directory or a directory above it. `:fmt` passes
one file with `--config-path`, so nothing outside the action's inputs (a file above the checkout, the worker's home) is ever read: the member directory's own
config if it has one, else the workspace root's (`//<workspace>:rustfmt_config`), else an empty file (rustfmt's defaults). A config `cargo fmt` would read for
a root and `:fmt` would not (one in a directory between the member and a root, or between the workspace root and the member) is refused by name, so the two
never give different verdicts silently.

The toolchain of the table's Rust version supplies rustfmt (`toolchains//:rustfmt_<v>`, rules/rust/toolchain.bzl). A version pinned in buildrules-pins.toml
has none, and its `:fmt` is refused by name.
"""

load(":providers.bzl", "RustToolchainInfo")

_NONCE = read_config("buildrules", "unit_nonce", "")

# cargo's conventional target roots (target auto-discovery): the default library and binary, `src/bin`, `examples`, `tests`, `benches`, and the build script.
AUTO_ROOTS = [
    "src/lib.rs",
    "src/main.rs",
    "src/bin/*.rs",
    "src/bin/*/main.rs",
    "examples/*.rs",
    "examples/*/main.rs",
    "tests/*.rs",
    "tests/*/main.rs",
    "benches/*.rs",
    "benches/*/main.rs",
    "build.rs",
]

# The names rustfmt looks for in a directory, in its order: the first that exists is the one it reads.
CONFIG_NAMES = [".rustfmt.toml", "rustfmt.toml"]

def _dir(p):
    return p.rsplit("/", 1)[0] if "/" in p else ""

def _join(d, n):
    return (d + "/" + n) if d else n

def _above(d):
    """`d` and every directory above it, nearest first, ending before "" (the directory everything is relative to)."""
    out = []
    for _ in range(1000):
        if not d:
            break
        out.append(d)
        d = _dir(d)
    return out

def config_in(configs, d):
    """The config rustfmt reads in directory `d` (relative, "" for the top) among the paths `configs`, or None."""
    for n in CONFIG_NAMES:
        if _join(d, n) in configs:
            return _join(d, n)
    return None

def _outside(p):
    return p.startswith("/") or p == ".." or p.startswith("../") or "/../" in p or p.endswith("/..")

def fmt_plan(units, discovered, configs, refuse = fail):
    """What the `:fmt` of one member checks, or None after a refusal (`refuse` is called with the reason; `fail` stops the load).

    Args:
        units: the member's own units of the table (each a dict with `crate_root`, relative to the member directory, and `edition`).
        discovered: the files of the member at one of `AUTO_ROOTS`, relative to the member directory.
        configs: every `.rustfmt.toml` and `rustfmt.toml` of the member, relative to the member directory.

    Returns:
        {"roots": edition -> sorted roots, "config": the member directory's own config, or None for the workspace's}. A root of the table keeps the
        edition of its unit; a discovered root that is not in the table takes the package's edition, the one most of its units have.
    """
    roots = {}
    counts = {}
    for u in units:
        r = u["crate_root"]
        if _outside(r):
            refuse("the target root {} is outside the member's directory; `:fmt` checks the member's own files".format(r))
            return None
        roots[r] = u["edition"]
        counts[u["edition"]] = counts.get(u["edition"], 0) + 1
    if not counts:
        refuse("the member has no units in the table, so its edition is not known; run `buildrules sync`")
        return None
    edition = sorted(counts.items(), key = lambda kv: (-kv[1], kv[0]))[0][0]
    for r in discovered:
        if r not in roots:
            roots[r] = edition
    for r in sorted(roots):
        for d in _above(_dir(r)):
            c = config_in(configs, d)
            if c:
                refuse(("{} is the rustfmt config of {} under `cargo fmt`, and `:fmt` reads one config per member, the member directory's or the " +
                        "workspace root's: move its settings to one of those").format(c, r))
                return None
    by = {}
    for r in sorted(roots):
        by.setdefault(roots[r], []).append(r)
    return {"config": config_in(configs, ""), "roots": by}

def workspace_fmt_config(members, configs, refuse = fail):
    """The workspace root's rustfmt config (relative to the workspace directory), or None for none; None after a refusal too.

    Args:
        members: the member directories, relative to the workspace directory.
        configs: the configs found in the workspace directory and in every directory between it and a member, relative to the workspace directory.
    """
    for m in sorted(members):
        for d in _above(_dir(m)):
            c = config_in(configs, d)
            if c:
                refuse(("{} is the rustfmt config of the member {} under `cargo fmt`, and `:fmt` reads the member directory's or the workspace root's: " +
                        "move its settings to one of those").format(c, m))
                return None
    return config_in(configs, "")

def workspace_config_candidates(members):
    """Every path (relative to the workspace directory) `workspace_fmt_config` needs to know about: the config names in the workspace directory and in
    each directory between it and a member."""
    out = {}
    for m in members:
        for d in [""] + _above(_dir(m)):
            for n in CONFIG_NAMES:
                out[_join(d, n)] = True
    return sorted(out)

# ---- rules -----------------------------------------------------------------------

def _refused(ctx):
    fail("{}: {}".format(ctx.label.raw_target(), ctx.attrs.why))

def _config_impl(ctx):
    if ctx.attrs.why:
        _refused(ctx)
    if ctx.attrs.src:
        return [DefaultInfo(default_output = ctx.attrs.src)]
    return [DefaultInfo(default_output = ctx.actions.write("defaults/rustfmt.toml", ""))]

# The workspace root's rustfmt config, or an empty file (rustfmt's defaults) when it has none. With `why`, analysis fails with that reason, so every `:fmt`
# that reads it is red by name.
rustfmt_config = rule(
    impl = _config_impl,
    attrs = {
        "src": attrs.option(attrs.source(), default = None),
        "why": attrs.option(attrs.string(), default = None),
    },
)

def _check_impl(ctx):
    if ctx.attrs.why:
        _refused(ctx)
    tc = ctx.attrs.toolchain[RustToolchainInfo]
    if tc.rustfmt == None:
        fail(("{}: rustc {} has no pinned rustfmt (a version pinned in buildrules-pins.toml pins none), so the member's formatting cannot be checked; " +
              "use a version of rules/rust/pins.bzl").format(ctx.label.raw_target(), tc.version))
    if not ctx.attrs.roots:
        fail("{}: no root file to check".format(ctx.label.raw_target()))
    outs = []
    for edition in sorted(ctx.attrs.roots):
        out = ctx.actions.declare_output("edition_{}.formatted".format(edition))
        cmd = cmd_args(
            ctx.attrs._check_exe[RunInfo],
            "marker",
            "--out",
            out.as_output(),
            "--capture",
            "--stamp",
            "formatted",
            "--clear-env",
            "--ld-library-path",
            cmd_args(tc.sysroot, "/lib", delimiter = ""),
            "--",
            cmd_args(tc.rustfmt, "/bin/rustfmt", delimiter = ""),
            "--check",
            "--edition",
            edition,
            "--config-path",
            ctx.attrs.config,
            ctx.attrs.roots[edition],
        )
        cmd.add(cmd_args(hidden = list(ctx.attrs.srcs)))
        ctx.actions.run(cmd, category = "rustfmt", identifier = "edition_" + edition, env = {"BUILDRULES_NONCE": _NONCE})
        outs.append(out)
    return [DefaultInfo(default_outputs = outs)]

# `rustfmt --check` over `roots` (edition -> root files) with `config`; every file rustfmt may reach from them is in `srcs`. One marker per edition, written
# only when rustfmt found nothing to change. With `why`, analysis fails with that reason (a member whose `:fmt` would not read what `cargo fmt` reads).
rustfmt_check = rule(
    impl = _check_impl,
    attrs = {
        "config": attrs.source(),
        "roots": attrs.dict(attrs.string(), attrs.list(attrs.source()), default = {}),
        "srcs": attrs.list(attrs.source(allow_directory = True), default = []),
        "toolchain": attrs.exec_dep(providers = [RustToolchainInfo]),
        "why": attrs.option(attrs.string(), default = None),
        "_check_exe": attrs.exec_dep(default = "buildrules//rules/check:check", providers = [RunInfo]),
    },
)
