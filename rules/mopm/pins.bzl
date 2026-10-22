"""The mopm binary buildrules runs: version, URL, sha256 and size of its release tarball (linux x86_64).

buildrules never builds mopm from source (docs/contract.md, section 12). It pins a released mopm exactly as it pins cargo, and
a mopm change reaches this repository by a pin bump after a release. `MOPM_DEFAULT` is the version a repository
that has no `mopm-toolchain.toml` of its own gets.

`0.0.25` is the published mopm release (https://github.com/komira-ai/mopm/releases/tag/v0.0.25), its linux-x86_64 tarball: the sha256 and size are
those of the asset and of the release's `SHA256SUMS`, and the tarball unpacks into `mopm-0.0.25-linux-x86_64/{mopm,LICENSE}`. A machine that
mirrors the download points it at its copy with `-c buildrules.url_map=<from-prefix>=<to-prefix>` (the sha256 is still checked, so a mirror
cannot change the bytes).

A version not in this table is refused unless the user supplies its URL, sha256 and size in `buildrules-pins.toml`
(`[mopm."0.0.2"]`); `buildrules mojo sync` copies them into `toolchains/mopm_pins.bzl`, which has the same shape as
`MOPM_VERSIONS`, and `mopm_toolchains()` declares one `toolchains//:mopm_<v>` for each.
"""

MOPM_DEFAULT = "0.0.25"

MOPM_VERSIONS = {
    "0.0.25": {
        "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.25/mopm-0.0.25-linux-x86_64.tar.gz",
        "sha256": "1848ffbb6c3f3522e95c36d3d5f7d4260abb8dde2cb3c415b17ca94dc48edeac",
        "size": 1074723,
        # The directory the tarball unpacks into; `mopm` is the executable in it.
        "dir": "mopm-0.0.25-linux-x86_64",
    },
}

def vname(version):
    """The suffix of a version's targets: `0.0.1` -> `0_0_1`."""
    return version.replace(".", "_")

def all_versions(extra):
    """The built-in rows plus the user's (`extra`, the generated toolchains/mopm_pins.bzl); a clash is an error."""
    rows = dict(MOPM_VERSIONS)
    for v, row in extra.items():
        if v in rows:
            fail("mopm {} is pinned by buildrules itself (rules/mopm/pins.bzl); remove it from buildrules-pins.toml".format(v))
        rows[v] = dict(row)
    return rows
