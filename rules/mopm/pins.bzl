"""The mopm binary buildrules runs: version, URL, sha256 and size of its release tarball (linux x86_64).

buildrules never builds mopm from source (docs/contract.md, section 12). It pins a released mopm exactly as it pins cargo, and
a mopm change reaches this repository by a pin bump after a release. `MOPM_DEFAULT` is the version a repository
that has no `mopm-toolchain.toml` of its own gets.

`0.0.1` is a stand-in, marked `release_pending`: the tarball was built on the farm from a development tree of mopm
(commit 5221610 of its `mopm-unit` branch) by `//:mopm-tarball`, and holds a `RELEASE-PENDING` file saying so. Its URL
is where the release job will publish it; until then nothing answers there, and a machine that has the tarball
points the download at its copy with `-c buildrules.url_map=<from-prefix>=<to-prefix>` in its `.buckconfig.local`
(the sha256 is still checked, so a mirror cannot change the bytes). When the release exists, this row gets the
release job's tarball and loses `release_pending`.

A version not in this table is refused unless the user supplies its URL, sha256 and size in `buildrules-pins.toml`
(`[mopm."0.0.2"]`); `buildrules mojo sync` copies them into `toolchains/mopm_pins.bzl`, which has the same shape as
`MOPM_VERSIONS`, and `mopm_toolchains()` declares one `toolchains//:mopm_<v>` for each.
"""

MOPM_DEFAULT = "0.0.1"

MOPM_VERSIONS = {
    "0.0.1": {
        "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.1/mopm-0.0.1-linux-x86_64.tar.gz",
        "sha256": "7609a462ddb64bdb0307dba9f96a4adb75dfe92145efb702befc467d2ed45e4c",
        "size": 977850,
        # The directory the tarball unpacks into; `mopm` is the executable in it.
        "dir": "mopm-0.0.1-linux-x86_64",
        "release_pending": True,
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
