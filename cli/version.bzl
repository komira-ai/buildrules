"""The version `buildrules --version` prints, as a Zig source file the program imports (the module `buildrules_version`).

A release build is stamped with the planned version: `-c buildrules.release_version=0.0.7` (the release workflow passes it, cli/BUCK reads it).
A build that is not (a checkout, a user's farm) reports `<MAJOR.MINOR>-dev` of the `VERSION` file, so a program that was not released never
claims a release number. No tool runs: a dynamic action reads the VERSION file and Starlark writes the source (`version_stamp`).
"""

load("@buildrules//rules/core:platform.bzl", "LINUX_X86_64")

def version_stamp(content, who = "cli_version", refuse = fail):
    """The source `version.zig` holds for a VERSION file with `content`: one `pub const release = "<MAJOR.MINOR>-dev";` line per line of
    the file that is exactly `<digits>.<digits>` (a final newline or none; no spaces, no carriage return). The output always ends in a
    newline. It is identical to what the sed this replaces wrote for a VERSION whose line ends in a newline (the shipped file does); for a
    VERSION without a final newline the sed omitted the trailing newline and this writes it. The file must be valid UTF-8.
    A file with no such line, or with two, is refused; the sed wrote an empty file for the first and two declarations for the second, and
    the program did not compile with either. Returns None after a refusal."""
    found = [line for line in content.split("\n") if regex_match("^[0-9]+\\.[0-9]+$", line)]
    if len(found) != 1:
        refuse("{}: the VERSION file must have exactly one line of the form MAJOR.MINOR (digits, a dot, digits), found {}: {}".format(who, len(found), repr(content)))
        return None
    return 'pub const release = "{}-dev";\n'.format(found[0])

def _write_stamp(actions, version_file, who, out):
    actions.write(out, version_stamp(version_file.read_string(), who = who))
    return []

_stamp = dynamic_actions(
    impl = _write_stamp,
    attrs = {
        "out": dynattrs.output(),
        "version_file": dynattrs.artifact_value(),
        "who": dynattrs.value(str),
    },
)

def _cli_version_impl(ctx):
    out = ctx.actions.declare_output("version.zig")
    if ctx.attrs.release:
        if not regex_match("^[0-9]+\\.[0-9]+\\.[0-9]+$", ctx.attrs.release):
            fail("{}: the release version {} is not MAJOR.MINOR.PATCH".format(ctx.label, repr(ctx.attrs.release)))
        ctx.actions.write(out, 'pub const release = "{}";\n'.format(ctx.attrs.release))
        return [DefaultInfo(default_output = out)]
    ctx.actions.dynamic_output_new(_stamp(
        version_file = ctx.attrs.file,
        who = str(ctx.label.raw_target()),
        out = out.as_output(),
    ))
    return [DefaultInfo(default_output = out)]

_cli_version = rule(
    impl = _cli_version_impl,
    attrs = {
        # The VERSION file (MAJOR.MINOR), used when `release` is empty.
        "file": attrs.source(),
        # MAJOR.MINOR.PATCH of the release being built; empty for a build that is not one.
        "release": attrs.string(default = ""),
    },
)

def cli_version(**kwargs):
    _cli_version(exec_compatible_with = LINUX_X86_64, **kwargs)
