"""`:check` of a Mojo package: is the committed table still what its inputs say? (docs/contract.md, section 12)

`buildrules mojo sync` made the table (`buildrules.mojo.lock.bzl`: mopm's unit graph, verbatim) from files the graph does not hash itself
(`MANIFEST_SHA256`: mopm.toml, mopm.lock, mopm-toolchain.toml, the mopm.toml of every member) and copied the graph's toolchain section into
toolchains/mojo_pins.bzl. A change to any of them without a sync leaves a table that describes another build. Every step of the package
(`:lib`, `:test`, `:build`, `:coverage`, the binaries, `:ci`) carries this target as a validation, so such a build is red:

    the files     an action (rules/mojo/tools/files_check.zig) hashes each file and compares it with the table's value
    the graph     `:table`, a target of its own (in `:ci`, and in //ci:all for every example): an action (rules/mojo/tools/table_check.zig) runs the pinned mopm's
                  `plan --unit-graph --locked` over the package and its members and requires the table's graph to be that output, byte for byte (the keys,
                  the order of units, natives and dependencies, every sha256), so a table that was edited, or left behind by a change, is red
    the pins      at analysis: the toolchain the package builds with (`toolchains//:mojo_<v>`, declared from mojo_pins.bzl) must hold exactly
                  the toolchain section of the table's graph (version, cc_target, closure hash, the zig, every component)

The fix is always `buildrules mojo sync`.
"""

load(":providers.bzl", "MojoToolchainInfo")

def _differs(have, want):
    keys = {}
    for k in have:
        keys[k] = True
    for k in want:
        keys[k] = True
    return [k for k in sorted(keys.keys()) if have.get(k) != want.get(k)]

def _impl(ctx):
    tc = ctx.attrs.toolchain[MojoToolchainInfo]
    who = str(ctx.label.raw_target())
    if tc.version != ctx.attrs.mojo:
        fail("{}: the table is for Mojo {} but {} is Mojo {}: run `buildrules mojo sync`".format(who, ctx.attrs.mojo, ctx.attrs.toolchain.label, tc.version))
    bad = _differs(tc.facts, ctx.attrs.expect_toolchain)
    if bad:
        fail(("{}: toolchains/mojo_pins.bzl and the table's unit graph disagree about the Mojo {} toolchain ({}): the pins file or the table was " +
              "edited without a sync. Run `buildrules mojo sync`").format(who, ctx.attrs.mojo, ", ".join(bad)))
    out = ctx.actions.declare_output("table_in_sync")
    args = cmd_args(ctx.attrs._tool[RunInfo], out.as_output())
    for h, f, n in zip(ctx.attrs.hashes, ctx.attrs.files, ctx.attrs.names):
        args.add(h, f[DefaultInfo].default_outputs[0], n)
    ctx.actions.run(args, category = "mojo_table_check", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out)]

mojo_check_rule = rule(
    impl = _impl,
    doc = "Fails unless every file the table was made from hashes to what the table recorded and the toolchain the package builds with is the one the table's graph names.",
    attrs = {
        # The toolchain section of the table's graph, without its `mojo` key: what toolchains/mojo_pins.bzl must hold for this version.
        "expect_toolchain": attrs.dict(attrs.string(), attrs.any()),
        "files": attrs.list(attrs.dep()),
        "hashes": attrs.list(attrs.string()),
        "mojo": attrs.string(),
        "names": attrs.list(attrs.string()),
        "toolchain": attrs.exec_dep(providers = [MojoToolchainInfo]),
        "_tool": attrs.exec_dep(default = "buildrules//rules/mojo:files_check", providers = [RunInfo]),
    },
)

def _workspace_impl(ctx):
    # The workspace as the repository has it, in one directory: this package's files (paths relative to the package, less the project directory) and
    # each member's workspace (under the member's directory). mopm reads mopm.toml, mopm.lock and every source of it.
    tree = {}
    for f in ctx.attrs.files:
        rel = f.short_path
        if ctx.attrs.project:
            if not rel.startswith(ctx.attrs.project + "/"):
                continue
            rel = rel[len(ctx.attrs.project) + 1:]
        tree[rel] = f
    for member, dep in ctx.attrs.members.items():
        tree[member] = dep[DefaultInfo].default_outputs[0]
    return [DefaultInfo(default_output = ctx.actions.copied_dir("workspace", tree))]

mojo_workspace_rule = rule(
    impl = _workspace_impl,
    doc = "The files of a Mojo package and of its workspace members, laid out as the repository has them (the input of `:table`).",
    attrs = {
        "files": attrs.list(attrs.source()),
        # `{"<directory below this one>": "<that package's :workspace>"}`, the outermost members only (a member's own members are in its workspace).
        "members": attrs.dict(attrs.string(), attrs.dep()),
        "project": attrs.string(default = ""),
    },
)

def _table_impl(ctx):
    out = ctx.actions.declare_output("table_is_mopms")
    ctx.actions.run(
        cmd_args(ctx.attrs._tool[RunInfo], ctx.attrs.mopm[RunInfo], ctx.attrs.workspace[DefaultInfo].default_outputs[0], ctx.attrs.mojo, ctx.attrs.table, out.as_output()),
        category = "mojo_table",
        identifier = ctx.label.name,
    )
    return [DefaultInfo(default_output = out)]

mojo_table_rule = rule(
    impl = _table_impl,
    doc = "Fails unless the committed graph (buildrules.mojo.lock.bzl) is, byte for byte, what the pinned mopm's `plan --unit-graph --locked` prints for the package and its members now.",
    attrs = {
        "mojo": attrs.string(),
        "mopm": attrs.exec_dep(providers = [RunInfo]),
        "table": attrs.source(),
        "workspace": attrs.dep(),
        "_tool": attrs.exec_dep(default = "buildrules//rules/mojo:table_check", providers = [RunInfo]),
    },
)
