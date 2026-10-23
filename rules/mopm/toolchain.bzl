"""The pinned mopm: one `toolchains//:mopm_<v>` per version, each an executable.

`mopm_toolchains()` is one call of the repository's toolchains/BUCK. For every version of `MOPM_VERSIONS`
(rules/mopm/pins.bzl) and of the user's `extra` (the generated toolchains/mopm_pins.bzl) it declares the tarball's
`pinned_file` and `mopm_<v>`, which unpacks it with the pinned `unpack` (rules/core/unpack.bzl); `:mopm` is the default's alias. The tarball is
the only thing downloaded; the binary is an input of every unit action, so it is part of every Mojo action key.
"""

load("//rules/core:pinned_file.bzl", "pinned_file")
load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/core:unpack.bzl", "UNPACK", "unpack_cmd")
load("//rules/core:url_map.bzl", "mapped_url")
load(":pins.bzl", "MOPM_DEFAULT", "all_versions", "vname")

# Perturbs the unpack action key without changing its output (`-c buildrules.nonce=N`), as the other toolchains do.
_NONCE = read_config("buildrules", "nonce", "")

# The most decompressed bytes a mopm release tarball may hold. The release is one executable in one directory (`mopm 0.0.25`: 2,928,575 bytes of tar stream, measured on the
# farm with `unpack --check --max-output`), and a version the user adds states no limit of its own, so one bound serves all: 64 MiB, twenty times the size of that release.
_MAX_OUTPUT = 64 * 1024 * 1024

def _impl(ctx):
    raw = ctx.actions.declare_output(ctx.attrs.dir, dir = True)
    # The tarball holds the one directory `dir`; `raw` is that directory's content.
    ctx.actions.run(
        unpack_cmd(ctx.label, ctx.attrs.unpack, ctx.attrs.archive[DefaultInfo].default_outputs[0], raw, ctx.attrs.sha256, ctx.attrs.size_bytes, ctx.attrs.max_output, 1, "tar.gz"),
        category = "mopm_unpack",
        env = {"BUILDRULES_NONCE": _NONCE},
    )
    out = ctx.actions.copy_dir("mopm_" + ctx.attrs.version, raw)
    exe = out.project("mopm")
    return [DefaultInfo(default_output = exe), RunInfo(args = cmd_args(exe))]

_mopm = rule(
    impl = _impl,
    attrs = {
        "archive": attrs.dep(),
        "dir": attrs.string(),
        "max_output": attrs.int(),
        "sha256": attrs.string(),
        "size_bytes": attrs.int(),
        "unpack": attrs.exec_dep(default = UNPACK, providers = [RunInfo]),
        "version": attrs.string(),
    },
)

def mopm_toolchains(extra = {}):
    rows = all_versions(extra)
    for v, row in sorted(rows.items()):
        pinned_file(
            name = "mopm-{}.tar.gz".format(v),
            url = mapped_url(row["url"]),
            sha256 = row["sha256"],
            size_bytes = row["size"],
            visibility = ["PUBLIC"],
        )
        _mopm(
            name = "mopm_" + vname(v),
            archive = ":mopm-{}.tar.gz".format(v),
            dir = row["dir"],
            max_output = _MAX_OUTPUT,
            sha256 = row["sha256"],
            size_bytes = row["size"],
            version = v,
            exec_compatible_with = LINUX_X86_64,
            visibility = ["PUBLIC"],
        )
    native.alias(name = "mopm", actual = ":mopm_" + vname(MOPM_DEFAULT), visibility = ["PUBLIC"])
