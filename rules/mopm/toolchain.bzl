"""The pinned mopm: one `toolchains//:mopm_<v>` per version, each an executable.

`mopm_toolchains()` is one call of the repository's toolchains/BUCK. For every version of `MOPM_VERSIONS`
(rules/mopm/pins.bzl) and of the user's `extra` (the generated toolchains/mopm_pins.bzl) it declares the tarball's
`pinned_file` and `mopm_<v>`, which unpacks it with the pinned busybox; `:mopm` is the default's alias. The tarball is
the only thing downloaded; the binary is an input of every unit action, so it is part of every Mojo action key.
"""

load("//rules/core:pinned_file.bzl", "pinned_file")
load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/core:url_map.bzl", "mapped_url")
load(":pins.bzl", "MOPM_DEFAULT", "all_versions", "vname")

# Perturbs the unpack action key without changing its output (`-c buildrules.nonce=N`), as the other toolchains do.
_NONCE = read_config("buildrules", "nonce", "")

def _impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    raw = ctx.actions.declare_output(ctx.attrs.dir, dir = True)
    ctx.actions.run(
        cmd_args(bb, "tar", "-xzf", ctx.attrs.archive[DefaultInfo].default_outputs[0], "-C", cmd_args(raw.as_output(), parent = 1)),
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
        "busybox": attrs.exec_dep(),
        "dir": attrs.string(),
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
        )
        _mopm(
            name = "mopm_" + vname(v),
            archive = ":mopm-{}.tar.gz".format(v),
            busybox = "buildrules//rules/pins:busybox",
            dir = row["dir"],
            version = v,
            exec_compatible_with = LINUX_X86_64,
            visibility = ["PUBLIC"],
        )
    native.alias(name = "mopm", actual = ":mopm_" + vname(MOPM_DEFAULT), visibility = ["PUBLIC"])
