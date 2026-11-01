"""The pinned mopm: one `toolchains//:mopm_<v>` per version, each an executable.

`mopm_toolchains()` is one call of the repository's toolchains/BUCK. For every version of `MOPM_VERSIONS`
(rules/mopm/pins.bzl) and of the user's `extra` (the generated toolchains/mopm_pins.bzl) it declares the tarball's
`pinned_file` and `mopm_<v>`, which unpacks it with the pinned `unpack` (rules/core/unpack.bzl); `:mopm` is the default's alias. The tarball is
the only thing downloaded; the binary is an input of every unit action, so it is part of every Mojo action key.

mopm runs where the Mojo compile runs (rules/mojo/exec.bzl), so `mopm_<v>` chooses its tarball by the host that runs it: the configuration it is built in
is the one of that execution platform. Linux x86_64 (and any platform with no host of its own) gets the row of `MOPM_VERSIONS`; linux aarch64 and macOS
arm64 get the rows of rules/mopm/hosts.bzl. A version with no row for a host fails analysis there and names the version and the host. The unpack runs
on linux x86_64 whatever the tarball is for: it only writes files.
"""

load("//rules/core:pinned_file.bzl", "pinned_file")
load("//rules/core:platform.bzl", "TOOL_EXEC", "by_host")
load("//rules/core:unpack.bzl", "UNPACK", "unpack_cmd")
load("//rules/core:url_map.bzl", "mapped_url")
load(":hosts.bzl", "MOPM_HOST_ASSETS")
load(":pins.bzl", "MOPM_DEFAULT", "all_versions", "vname")

# Perturbs the unpack action key without changing its output (`-c buildrules.nonce=N`), as the other toolchains do.
_NONCE = read_config("buildrules", "nonce", "")

# The most decompressed bytes a mopm release tarball may hold. A release is one executable and a licence in one directory (about a megabyte compressed, rules/mopm/pins.bzl), and a
# version the user adds states no limit of its own, so one bound serves all: 64 MiB, far above any release of that shape. A release that outgrows it makes its unpacking action fail.
_MAX_OUTPUT = 64 * 1024 * 1024

def _impl(ctx):
    if ctx.attrs.missing:
        fail(ctx.attrs.missing)
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
        # Empty when the version has a tarball for the host that runs it; else the refusal.
        "missing": attrs.string(default = ""),
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
        base = ":mopm-{}.tar.gz".format(v)
        host_rows = MOPM_HOST_ASSETS.get(v, {})
        archive = {}
        dirs = {}
        shas = {}
        sizes = {}
        missing = {}
        for host in ["linux-aarch64", "macos-aarch64"]:
            h = host_rows.get(host)
            if h:
                name = "mopm-{}-{}.tar.gz".format(v, host)
                pinned_file(name = name, url = mapped_url(h["url"]), sha256 = h["sha256"], size_bytes = h["size"])
                archive[host], dirs[host], shas[host], sizes[host], missing[host] = ":" + name, h["dir"], h["sha256"], h["size"], ""
            else:
                # The x86 tarball stands in so that the attribute resolves; `missing` is what the rule fails with.
                archive[host], dirs[host], shas[host], sizes[host] = base, row["dir"], row["sha256"], row["size"]
                missing[host] = ("mopm {} has no tarball pinned for {}: rules/mopm/hosts.bzl holds the release assets of the hosts other than linux-x86_64 " +
                                 "(a version pinned in buildrules-pins.toml has linux-x86_64 only). Pin a mopm release that has one for this host.").format(v, host)
        _mopm(
            name = "mopm_" + vname(v),
            archive = by_host(base, archive["linux-aarch64"], archive["macos-aarch64"]),
            dir = by_host(row["dir"], dirs["linux-aarch64"], dirs["macos-aarch64"]),
            max_output = _MAX_OUTPUT,
            missing = by_host("", missing["linux-aarch64"], missing["macos-aarch64"]),
            sha256 = by_host(row["sha256"], shas["linux-aarch64"], shas["macos-aarch64"]),
            size_bytes = by_host(row["size"], sizes["linux-aarch64"], sizes["macos-aarch64"]),
            version = v,
            exec_compatible_with = TOOL_EXEC,
            visibility = ["PUBLIC"],
        )
    native.alias(name = "mopm", actual = ":mopm_" + vname(MOPM_DEFAULT), visibility = ["PUBLIC"])
