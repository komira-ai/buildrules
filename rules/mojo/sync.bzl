"""`mojo_sync`: `buildrules mojo sync` as a farm action, for a machine that may not run a built binary.

`buildrules mojo sync` is the only writer of `buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl`, `toolchains/mojo_pins.bzl` and `toolchains/mopm_pins.bzl`. This rule runs
it in a build action (rules/mojo/tools/mojo_sync.zig), the way `cargo_sync` (rules/rust/sync.bzl) runs `buildrules sync`: in a copy of the packages, with the pinned
mopm, offline (mopm plans from `mopm.lock`). The action's output holds the files the sync writes, at their repository paths, and nothing else.

    mojo_sync(
        name = "sync",
        packages = ["examples/mojo/sibfake/chain/a"],  # directories from the repository root; default: this package
        workspaces = [":workspace"],                   # the package's :workspace (mojo_package makes it), and any other package that is staged
        files = ["//examples/mojo:mopm-toolchain.toml"],  # the other files the sync reads: the toolchain file, a buildrules-pins.toml
        mopm = "0.0.48",                               # the version mopm-toolchain.toml names: the sync refuses a file that names another
        committed = ["buildrules.mojo.lock.bzl", "buildrules.mojo.bzl"],
    )

makes two targets:

    buck2 build //pkg:sync_check    red unless the committed files in `committed` are, byte for byte, what a sync writes now (a freshness check; nothing is written)
    buck2 run   //pkg:sync          writes the files into the working tree (run it from the repository root; `-- --to DIR` names another) and prints each file it wrote.
                                    `buck2 build //pkg:sync --show-full-output` shows the directory without writing anything.

After a change to mopm-toolchain.toml (a new mopm), a mopm.toml or mopm.lock, or a source of a package, `buck2 run` the target and commit what it wrote. `workspaces` are
the staged inputs: a package's `:workspace` holds its own files and those of its path dependencies, at their repository paths, without the files the sync writes, so a
stale table is no input of the table that replaces it. A path dependency added to a mopm.toml since the last sync is not in the stale table's `:workspace`: name its
`:workspace` in `workspaces` too. `<toolchains>/mojo_pins.bzl` lists the toolchains of the packages synced together, so a repository with several Mojo versions syncs
all its packages in one target for it to be complete. `<toolchains>/BUCK` and the export of mopm-toolchain.toml that a sync may add to the BUCK file of that file's
directory are not outputs: a repository that lacks the export runs `buildrules mojo sync` where it can.
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/mopm:pins.bzl", "vname")
load("//rules:platforms.bzl", "linux_arm64_gate")
load(":check.bzl", "repo_path")
load(":providers.bzl", "MojoWorkspaceInfo")

def sync_stage_tree(workspaces, files, refuse = fail):
    """The staged repository: `{repository path: file}`. `workspaces` are the maps of the workspaces (a file two hold is one entry), `files` a map of the other
    inputs; a path that two different files claim is refused."""
    tree = {}
    for ws in workspaces:
        for path, f in ws.items():
            if path not in tree:
                tree[path] = f
    for path, f in files.items():
        if path in tree and tree[path] != f:
            refuse("mojo_sync: two different files are staged at {}".format(path))
            continue
        tree[path] = f
    return tree

def sync_packages(packages, refuse = fail):
    """The package directories of a `mojo_sync`, normalized: each a directory below the repository root (`.` is the root itself, written `""`), none twice."""
    if not packages:
        refuse("mojo_sync: `packages` is empty: name the directories (from the repository root) of the Mojo packages to sync")
        return []
    out = []
    for p in packages:
        parts = []
        bad = p.startswith("/")
        for part in p.split("/"):
            if part == "..":
                bad = True
            elif part not in ("", "."):
                parts.append(part)
        if bad:
            refuse("mojo_sync: the package {} is not a directory below the repository root".format(p))
            continue
        dir = "/".join(parts)
        if dir in out:
            refuse("mojo_sync: the package {} is named twice".format(p))
            continue
        out.append(dir)
    return out

def _impl(ctx):
    files = {}
    for f in ctx.attrs.files:
        out = f[DefaultInfo].default_outputs[0]
        files[repo_path(f.label.package, out.short_path)] = out
    tree = sync_stage_tree([w[MojoWorkspaceInfo].files for w in ctx.attrs.workspaces], files)
    src = ctx.actions.copied_dir("workspace", tree)
    synced = ctx.actions.declare_output("synced", dir = True)
    work = ctx.actions.declare_output("work", dir = True)
    cmd = cmd_args(
        ctx.attrs._tool[RunInfo],
        "stage",
        "--src",
        src,
        "--work",
        work.as_output(),
        "--out",
        synced.as_output(),
        "--buildrules",
        ctx.attrs._buildrules[RunInfo],
        "--mopm",
        ctx.attrs.mopm[RunInfo],
        "--mopm-version",
        ctx.attrs.mopm_version,
        "--toolchains",
        ctx.attrs.toolchains,
    )
    if ctx.attrs.committed:
        committed = {}
        for s in ctx.attrs.committed:
            committed[repo_path(ctx.label.package, s.short_path)] = s
        cmd.add("--committed", ctx.actions.copied_dir("committed", committed))
        cmd.add("--hint", "buck2 run //{}:{}".format(ctx.label.package, ctx.attrs.fix))
    cmd.add(ctx.attrs.packages)
    ctx.actions.run(cmd, category = "mojo_sync", identifier = ctx.label.name)
    info = [DefaultInfo(default_output = synced)]
    if not ctx.attrs.committed:
        info.append(RunInfo(args = cmd_args(ctx.attrs._tool[RunInfo], "apply", "--from", synced)))
    return info

_mojo_sync = rule(
    impl = _impl,
    doc = "Runs `buildrules mojo sync` in a copy of the packages' workspaces with the pinned mopm; its output holds the files a sync writes. With `committed`, fails unless they are those; without, `buck2 run` writes them into the working tree.",
    attrs = {
        # The committed copies of generated files of this package (`buildrules.mojo.lock.bzl`), which must be what the sync writes.
        "committed": attrs.list(attrs.source(), default = []),
        # Files of other targets staged at their repository paths: the toolchain file (`//dir:mopm-toolchain.toml`), a buildrules-pins.toml.
        "files": attrs.list(attrs.dep(), default = []),
        # The name of the target to run for the fix, in the message of a stale file.
        "fix": attrs.string(default = ""),
        "mopm": attrs.exec_dep(providers = [RunInfo]),
        "mopm_version": attrs.string(),
        "packages": attrs.list(attrs.string()),
        "toolchains": attrs.string(default = "toolchains"),
        "workspaces": attrs.list(attrs.dep(providers = [MojoWorkspaceInfo])),
        "_buildrules": attrs.exec_dep(default = "buildrules//cli:buildrules", providers = [RunInfo]),
        "_tool": attrs.exec_dep(default = "buildrules//rules/mojo:mojo_sync", providers = [RunInfo]),
    },
)

def mojo_sync(name, workspaces, files, mopm, packages = None, committed = [], toolchains = "toolchains", visibility = ["PUBLIC"]):
    """`name`: `buck2 run` it to write the files a sync writes into the working tree; `name_check` (with `committed`): red unless the committed files are those.
    `mopm`: the mopm version the packages' mopm-toolchain.toml names (`"0.0.48"`); it is built as `toolchains//:mopm_<v>`."""
    common = dict(
        exec_compatible_with = LINUX_X86_64,
        files = files,
        fix = name,
        mopm = "toolchains//:mopm_" + vname(mopm),
        mopm_version = mopm,
        packages = sync_packages(packages if packages != None else [native.package_name()]),
        target_compatible_with = linux_arm64_gate(),
        toolchains = toolchains,
        visibility = visibility,
        workspaces = workspaces,
    )
    _mojo_sync(name = name, **common)
    if committed:
        _mojo_sync(name = name + "_check", committed = committed, **common)
