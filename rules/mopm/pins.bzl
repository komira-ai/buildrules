"""The mopm binary buildrules runs: version, URL, sha256 and size of its release tarball (linux x86_64).

buildrules never builds mopm from source (docs/contract.md, section 12). It pins a released mopm exactly as it pins cargo, and
a mopm change reaches this repository by a pin bump after a release. `MOPM_DEFAULT` is the version a repository
that has no `mopm-toolchain.toml` of its own gets.

`0.0.48` is the published mopm release (https://github.com/komira-ai/mopm/releases/tag/v0.0.48), its linux-x86_64 tarball: the sha256 and size are
those of the asset and of the release's `SHA256SUMS`, and the tarball unpacks into `mopm-0.0.48-linux-x86_64/{mopm,LICENSE}`. A machine that
mirrors the download points it at its copy with `-c buildrules.url_map=<from-prefix>=<to-prefix>` (the sha256 is still checked, so a mirror
cannot change the bytes).

A version not in this table is refused unless the user supplies its URL, sha256 and size in `buildrules-pins.toml`
(`[mopm."0.0.2"]`); `buildrules mojo sync` copies them into `toolchains/mopm_pins.bzl`, which has the same shape as
`MOPM_VERSIONS`, and `mopm_toolchains()` declares one `toolchains//:mopm_<v>` for each.
"""

MOPM_DEFAULT = "0.0.48"

MOPM_VERSIONS = {
    "0.0.48": {
        "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.48/mopm-0.0.48-linux-x86_64.tar.gz",
        "sha256": "fac4cb0156bb649f7149cb94962adb81470d9a92bcc4ab3b45e2943c3f11c2b4",
        "size": 1193212,
        # The directory the tarball unpacks into; `mopm` is the executable in it.
        "dir": "mopm-0.0.48-linux-x86_64",
    },
    "0.0.73": {
        "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.73/mopm-0.0.73-linux-x86_64.tar.gz",
        "sha256": "02d4d8d8328f3a996cef137596bab2421575312fc84e22491f2d813e24ff728b",
        "size": 1225546,
        "dir": "mopm-0.0.73-linux-x86_64",
    },
    "0.0.81": {
        "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.81/mopm-0.0.81-linux-x86_64.tar.gz",
        "sha256": "7113f0526235e6aa301308da05c3fe1223ae068ae4627d83b0849e465f5a185c",
        "size": 1232538,
        "dir": "mopm-0.0.81-linux-x86_64",
    },
    "0.0.83": {
        "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.83/mopm-0.0.83-linux-x86_64.tar.gz",
        "sha256": "fe87be9054cdde4ae78f2249760b3ee5b9d480a28e2524efdc7a77b15f016730",
        "size": 1285404,
        "dir": "mopm-0.0.83-linux-x86_64",
    },
    "0.0.85": {
        "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.85/mopm-0.0.85-linux-x86_64.tar.gz",
        "sha256": "e0f9da8a9a5be4cb6a0260517911aa44da727bbd27c2f7a2a96458b4f0779c03",
        "size": 1286097,
        "dir": "mopm-0.0.85-linux-x86_64",
    },
    "0.0.86": {
        "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.86/mopm-0.0.86-linux-x86_64.tar.gz",
        "sha256": "7386a1aadb704fb38e8cf6c0e5defc90cc5c5aed49f089633f4f18b8a5065792",
        "size": 1285004,
        "dir": "mopm-0.0.86-linux-x86_64",
    },
    "0.0.101": {
        "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.101/mopm-0.0.101-linux-x86_64.tar.gz",
        "sha256": "07a591f22f52f52f90599f7ac5de356ceface4ec4271d264de972cfc80e276f9",
        "size": 1299129,
        "dir": "mopm-0.0.101-linux-x86_64",
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
