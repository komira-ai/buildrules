"""`cargo_sync`: `buildrules sync` as a farm action, for a workspace whose crates cannot be fetched there.

A farm action has no network, so cargo cannot resolve crates.io in it. This rule runs the pinned cargo and the `buildrules` command line in a
copy of the workspace (rules/rust/sync_stage.zig), against a *local registry*: the lines crates.io's index holds for the crates the workspace
uses, and their pinned `.crate` files. Every id cargo prints is still crates.io's (a local registry replaces the source, not the identity), so the
files it makes are the files a sync on a machine with a network makes. Two ways to use the target:

    buck2 build //examples/crates:sync --show-full-output    (check = False)  the directory holds the files a sync writes; copy them into the
                                                              repository. Do this when Cargo.toml / Cargo.lock / the registry change.
    buck2 build //examples/crates:sync_check                  (check = True)    red unless the committed generated files are what a sync writes now.
                                                              A change to a Cargo.toml without a sync, or a generator that no longer writes
                                                              what is committed, fails this build.

The local registry is a fixture of the example, not part of the contract: a repository with a network runs `buildrules sync` itself.
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load(":pins.bzl", "vname")

def _rel(path, root):
    if root and path.startswith(root + "/"):
        return path[len(root) + 1:]
    return path

def _sync_impl(ctx):
    files = {_rel(s.short_path, ctx.attrs.root): s for s in ctx.attrs.srcs}
    # A filegroup's output is one directory holding the package's files at their paths: it goes where the package is.
    for d in ctx.attrs.deps:
        files[_rel(d.label.package, ctx.attrs.root)] = d[DefaultInfo].default_outputs[0]
    workspace = ctx.actions.copied_dir("workspace", files)
    reg = {_rel(s.short_path, ctx.attrs.registry_root): s for s in ctx.attrs.index}
    for name, crate in ctx.attrs.crates.items():
        reg[name] = crate[DefaultInfo].default_outputs[0]
    out = ctx.actions.declare_output("synced", dir = True)
    cmd = cmd_args(
        ctx.attrs._stage[RunInfo],
        "--src",
        workspace,
        "--out",
        out.as_output(),
        "--buildrules",
        ctx.attrs._buildrules[RunInfo],
        "--cargo",
        ctx.attrs.cargo[DefaultInfo].default_outputs[0],
        "--sysroot",
        ctx.attrs.sysroot[DefaultInfo].default_outputs[0],
        "--pins",
        ctx.attrs._pins[DefaultInfo].default_outputs[0],
    )
    if reg:
        cmd.add("--registry", ctx.actions.copied_dir("registry", reg))
    if ctx.attrs.check:
        cmd.add("--check")
    ctx.actions.run(cmd, category = "cargo_sync", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out)]

_cargo_sync = rule(
    impl = _sync_impl,
    doc = "Runs `buildrules sync` (or `sync --check`) in a copy of the workspace `srcs`, against the local registry `index` + `crates`.",
    attrs = {
        "cargo": attrs.exec_dep(),
        "check": attrs.bool(default = False),
        # name -> pinned_file of the `.crate`, and the files of the registry's index (paths relative to `registry_root`).
        "crates": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        # The files of the packages below the workspace root (the members: `:sources` of cargo_package; the registry units: `:files`), which a glob of
        # the root package cannot reach.
        "deps": attrs.list(attrs.dep(), default = []),
        "index": attrs.list(attrs.source(), default = []),
        "registry_root": attrs.string(default = ""),
        # The workspace's files, and the directory (relative to the repository root) they are relative to.
        "root": attrs.string(default = ""),
        "srcs": attrs.list(attrs.source()),
        "sysroot": attrs.exec_dep(),
        "_buildrules": attrs.exec_dep(default = "buildrules//cli:buildrules", providers = [RunInfo]),
        "_pins": attrs.exec_dep(default = "buildrules//rules/rust:pins.bzl"),
        "_stage": attrs.exec_dep(default = "buildrules//rules/rust:sync_stage", providers = [RunInfo]),
    },
)

def cargo_sync(name, rustc, srcs, deps = [], root = "", index = [], crates = {}, registry_root = "", check = False, **kwargs):
    """`rustc`: the Rust version of the workspace's rust-toolchain.toml (its pinned cargo and sysroot run the sync)."""
    _cargo_sync(
        name = name,
        cargo = "toolchains//:cargo_" + vname(rustc),
        check = check,
        crates = crates,
        deps = deps,
        exec_compatible_with = LINUX_X86_64,
        index = index,
        registry_root = registry_root,
        root = root,
        srcs = srcs,
        sysroot = "toolchains//:sysroot_" + vname(rustc),
        **kwargs
    )
