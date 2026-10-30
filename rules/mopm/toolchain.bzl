"""The pinned mopm: one `toolchains//:mopm_<v>` per version, each an executable.

`mopm_toolchains()` is one call of the repository's toolchains/BUCK. For every version of `MOPM_VERSIONS`
(rules/mopm/pins.bzl) and of the user's `extra` (the generated toolchains/mopm_pins.bzl) it declares the tarball's
`pinned_file` and `mopm_<v>`, which unpacks it with the pinned busybox; `:mopm` is the default's alias. The tarball is
the only thing downloaded; the binary is an input of every unit action, so it is part of every Mojo action key.

mopm runs where the Mojo compile runs (rules/mojo/exec.bzl), so `mopm_<v>` chooses its tarball by the host that runs it: the configuration it is built in
is the one of that execution platform. Linux x86_64 (and any platform with no host of its own) gets the row of `MOPM_VERSIONS`; linux aarch64 and macOS
arm64 get the rows of rules/mopm/hosts.bzl. A version with no row for a host fails analysis there and names the version and the host. The unpack runs
on linux x86_64 whatever the tarball is for: it only writes files.
"""

load("//rules/core:pinned_file.bzl", "pinned_file")
load("//rules/core:platform.bzl", "TOOL_EXEC", "by_host")
load("//rules/core:url_map.bzl", "mapped_url")
load(":hosts.bzl", "MOPM_HOST_ASSETS")
load(":pins.bzl", "MOPM_DEFAULT", "all_versions", "vname")

# Perturbs the unpack action key without changing its output (`-c buildrules.nonce=N`), as the other toolchains do.
_NONCE = read_config("buildrules", "nonce", "")

def _impl(ctx):
    if ctx.attrs.missing:
        fail(ctx.attrs.missing)
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
        # Empty when the version has a tarball for the host that runs it; else the refusal.
        "missing": attrs.string(default = ""),
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
        base = ":mopm-{}.tar.gz".format(v)
        host_rows = MOPM_HOST_ASSETS.get(v, {})
        archive = {}
        dirs = {}
        missing = {}
        for host in ["linux-aarch64", "macos-aarch64"]:
            h = host_rows.get(host)
            if h:
                name = "mopm-{}-{}.tar.gz".format(v, host)
                pinned_file(name = name, url = mapped_url(h["url"]), sha256 = h["sha256"], size_bytes = h["size"])
                archive[host], dirs[host], missing[host] = ":" + name, h["dir"], ""
            else:
                # The x86 tarball stands in so that the attribute resolves; `missing` is what the rule fails with.
                archive[host], dirs[host] = base, row["dir"]
                missing[host] = ("mopm {} has no tarball pinned for {}: rules/mopm/hosts.bzl holds the release assets of the hosts other than linux-x86_64 " +
                                 "(a version pinned in buildrules-pins.toml has linux-x86_64 only). Pin a mopm release that has one for this host.").format(v, host)
        _mopm(
            name = "mopm_" + vname(v),
            archive = by_host(base, archive["linux-aarch64"], archive["macos-aarch64"]),
            busybox = "buildrules//rules/pins:busybox",
            dir = by_host(row["dir"], dirs["linux-aarch64"], dirs["macos-aarch64"]),
            missing = by_host("", missing["linux-aarch64"], missing["macos-aarch64"]),
            version = v,
            exec_compatible_with = TOOL_EXEC,
            visibility = ["PUBLIC"],
        )
    native.alias(name = "mopm", actual = ":mopm_" + vname(MOPM_DEFAULT), visibility = ["PUBLIC"])
