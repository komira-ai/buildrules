"""The command-line binaries of a release in one directory.

`release_binaries` copies the executable built for each release target to `<release target>/buildrules` of one output, so that the release workflow builds all three
with one command (`buck2 build --out DIR //cli:release_binaries`), `release package-all` finds each at the path its target names, and the second build that
`verify` makes is the same command. It builds nothing: each executable is its own target, behind its own unit tests (zig_exe), and the directory is a copy of
their outputs. The names are the release targets (`linux-x86_64`, `linux-aarch64`, `macos-arm64`), which the release tool and the file-header
test (cli/header_test.zig) hold each file to.
"""

def _release_binaries_impl(ctx):
    files = {}
    for target, exe in ctx.attrs.binaries.items():
        files[target + "/buildrules"] = exe[DefaultInfo].default_outputs[0]
    return [DefaultInfo(default_output = ctx.actions.copied_dir("release_binaries", files))]

release_binaries = rule(
    impl = _release_binaries_impl,
    attrs = {
        # release target -> the zig_exe built for it
        "binaries": attrs.dict(attrs.string(), attrs.dep()),
    },
)
