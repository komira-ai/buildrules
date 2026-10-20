"""`mojo_conda`: a library as the `.conda` a registry serves (the publisher's side, for fixtures).

`mopm pack` writes one `.conda` per subdir holding `lib/mojo/<name>.mojoc` and its metadata. The registry stand-ins of the
examples use it so that a consumer's lock can name a real package, its sha256 and its size. `mopm pack` is mopm's: this rule
only runs it on the `.mojoc` a `mojo_package` built. (Publishing, which uploads, is not a build action.)
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load(":providers.bzl", "MojoLibInfo")

def _impl(ctx):
    lib = ctx.attrs.lib[MojoLibInfo]
    out = ctx.actions.declare_output("channel", dir = True)
    ctx.actions.run(
        cmd_args(
            ctx.attrs.mopm[RunInfo],
            "pack",
            "--compiler",
            ctx.attrs.mojo,
            "--mojoc",
            cmd_args("linux-64=", lib.mojoc, delimiter = ""),
            "--manifest",
            ctx.attrs.manifest,
            "-o",
            out.as_output(),
        ),
        category = "mopm_pack",
        identifier = ctx.attrs.package,
    )
    conda = out.project("linux-64/mojo-{}-{}-mojo{}_0.conda".format(ctx.attrs.package, ctx.attrs.version, ctx.attrs.mojo))
    return [DefaultInfo(default_output = conda, sub_targets = {"channel": [DefaultInfo(default_output = out)]})]

_mojo_conda = rule(
    impl = _impl,
    attrs = {
        "lib": attrs.dep(providers = [MojoLibInfo]),
        "manifest": attrs.source(),
        "mojo": attrs.string(),
        "mopm": attrs.exec_dep(),
        "package": attrs.string(),
        "version": attrs.string(),
    },
)

def mojo_conda(**kwargs):
    _mojo_conda(exec_compatible_with = LINUX_X86_64, **kwargs)
