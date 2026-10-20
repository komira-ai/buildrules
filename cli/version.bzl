"""The version `buildrules --version` prints, as a Zig source file the program imports (the module `buildrules_version`).

A release build is stamped with the planned version: `-c buildrules.release_version=0.0.7` (the release workflow passes it, cli/BUCK reads it).
A build that is not (a checkout, a user's farm) reports `<MAJOR.MINOR>-dev` of the `VERSION` file, so a program that was not released never
claims a release number. No shell: busybox's own `sed` writes the file.
"""

load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")

def _cli_version_impl(ctx):
    out = ctx.actions.declare_output("version.zig")
    if ctx.attrs.release:
        if not regex_match("^[0-9]+\\.[0-9]+\\.[0-9]+$", ctx.attrs.release):
            fail("{}: the release version {} is not MAJOR.MINOR.PATCH".format(ctx.label, repr(ctx.attrs.release)))
        ctx.actions.write(out, 'pub const release = "{}";\n'.format(ctx.attrs.release))
        return [DefaultInfo(default_output = out)]
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    # `s///w FILE` writes the line only when the VERSION file is `<MAJOR>.<MINOR>`; any other content writes nothing and the action fails.
    script = cmd_args("s|^\\([0-9][0-9]*\\.[0-9][0-9]*\\)$|pub const release = \"\\1-dev\";|w ", out.as_output(), delimiter = "")
    ctx.actions.run(cmd_args(bb, "sed", "-n", script, ctx.attrs.file), category = "cli_version")
    return [DefaultInfo(default_output = out)]

_cli_version = rule(
    impl = _cli_version_impl,
    attrs = {
        "busybox": attrs.dep(default = "buildrules//rules/pins:busybox"),
        # The VERSION file (MAJOR.MINOR), used when `release` is empty.
        "file": attrs.source(),
        # MAJOR.MINOR.PATCH of the release being built; empty for a build that is not one.
        "release": attrs.string(default = ""),
    },
)

def cli_version(**kwargs):
    _cli_version(exec_compatible_with = LINUX_X86_64, **kwargs)
