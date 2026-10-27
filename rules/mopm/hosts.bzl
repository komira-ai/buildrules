"""The mopm release tarballs of the hosts other than linux x86_64: URL, sha256, size and the directory each unpacks into.

A Mojo package built for linux aarch64 or macOS arm64 is planned, packed and compiled by a mopm that runs on that host (rules/mojo/exec.bzl), so
`toolchains//:mopm_<v>` is a `select` on the host that runs it. The rows below are those of the same release as the linux x86_64 row of
`MOPM_VERSIONS` (rules/mopm/pins.bzl): the sha256 is the one in the release's `SHA256SUMS` and the size the asset's, and each tarball unpacks into
`mopm-<version>-<platform>/{mopm,LICENSE}`. The spelling of the key is the one of `host_name()` (rules/platforms.bzl) and rules/pins/hosts.bzl.

A version with no row here has no pin for that host: a Mojo package that needs its mopm there fails analysis and says which version and host (rules/mopm/toolchain.bzl),
and a version the user pins in `buildrules-pins.toml` has linux x86_64 only. Never copy a hash from another release.
"""

MOPM_HOST_ASSETS = {
    "0.0.73": {
        "linux-aarch64": {
            "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.73/mopm-0.0.73-linux-aarch64.tar.gz",
            "sha256": "ef8ee9457d792c8fc4155ea04fcd0699d44834cb08d54fe0e72c7e9cbd5327c2",
            "size": 1253487,
            "dir": "mopm-0.0.73-linux-aarch64",
        },
        "macos-aarch64": {
            "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.73/mopm-0.0.73-macos-arm64.tar.gz",
            "sha256": "2cf41ad9368186b30e40d2d690910eb9c3e33b167c22f730a779b16b8ff85ddb",
            "size": 1290580,
            "dir": "mopm-0.0.73-macos-arm64",
        },
    },
    "0.0.81": {
        "linux-aarch64": {
            "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.81/mopm-0.0.81-linux-aarch64.tar.gz",
            "sha256": "7cba13c4f348ae862d95a1bbe07167210de10ca8ac1abbebcd2bb7954cc54cfe",
            "size": 1260526,
            "dir": "mopm-0.0.81-linux-aarch64",
        },
        "macos-aarch64": {
            "url": "https://github.com/komira-ai/mopm/releases/download/v0.0.81/mopm-0.0.81-macos-arm64.tar.gz",
            "sha256": "26955e36948fa10ee38baf5d3ce2873058c4e33201e9eb8cff1709bbfce58985",
            "size": 1297577,
            "dir": "mopm-0.0.81-macos-arm64",
        },
    },
}
