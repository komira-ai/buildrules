"""`:check` of a Mojo package: is the committed table still what its inputs say? (docs/contract.md, section 12)

`buildrules mojo sync` made the table (`buildrules.mojo.lock.bzl`: mopm's unit graph, verbatim) from files the graph does not hash itself
(`MANIFEST_SHA256`: mopm.toml, mopm.lock, mopm-toolchain.toml, the mopm.toml of every member) and copied the graph's toolchain section into
toolchains/mojo_pins.bzl. A change to any of them without a sync leaves a table that describes another build. Every step of the package
(`:lib`, `:test`, `:build`, `:coverage`, the binaries, `:ci`) carries this target as a validation, so such a build is red:

    the files     an action (rules/mojo/tools/files_check.zig) hashes each file and compares it with the table's value
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
