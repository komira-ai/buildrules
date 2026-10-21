"""Downloads of the zig/node/kpin families (linux x86_64): URL, sha256, size in bytes.

The values are the pinned `linux-x86_64` rows,
so a hash here is the hash the builds use.
`name` is the target name of the `pinned_file` that fetches it,.
"""

PINS = {
    "busybox": {
        "name": "busybox",
        # The upstream file is https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox (static, musl); buck2 `download_file` takes one URL and has no fallback, so the pin
        # fetches the byte-identical copy held as an asset of the release `mirror-busybox-1.35.0` of this repository (tools/held/mirror-busybox.sh
        # downloads the upstream file, checks the sha256 and size below, and uploads it). The beta stage maps the prefix back to the upstream on a retry (docs/pins.md).
        "url": "https://github.com/komira-ai/buildrules/releases/download/mirror-busybox-1.35.0/busybox",
        "sha256": "6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348",
        "size": 1131168,
        "executable": True,
    },
    # zig 0.12.0: the default `zig` of the zig rules, and the C link driver of rustc.
    "zig": {
        "name": "zig_linux_x86_64.tar.xz",
        "url": "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz",
        "sha256": "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad",
        "size": 45480516,
    },
    # zig 0.15.2: builds the gate, kpin and the node tools (std.http of 0.12 cannot do TLS 1.3).
    "zig_next": {
        "name": "zig_next_linux_x86_64.tar.xz",
        "url": "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz",
        "sha256": "02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239",
        "size": 53733924,
    },
    # actionlint: the workflow linter (ci/workflow_lint.bzl).
    "actionlint": {
        "name": "actionlint_linux_amd64.tar.gz",
        "url": "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_linux_amd64.tar.gz",
        "sha256": "8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8",
        "size": 2353908,
    },
    # OSV-Scanner: the daily advisory scan (.github/workflows/advisories.yml). The workflow downloads this url on a runner and checks this sha256;
    # ci/advisories_check.zig compares both with this row and hashes the file the farm fetched.
    "osv_scanner": {
        "name": "osv-scanner_linux_amd64",
        "url": "https://github.com/google/osv-scanner/releases/download/v2.7.0/osv-scanner_linux_amd64",
        "sha256": "160c6253e2922e9e0a6a9771c5c4c40a4b3c6090b34a3cdd5e80c96cc2e4218b",
        "size": 57725088,
        "executable": True,
    },
    # conda-forge: libgcc_s.so.1 (rustc, node), libstdc++.so.6 (node).
    "libgcc": {
        "name": "libgcc_15.3.0_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/libgcc-15.3.0-h3363355_7.conda",
        "sha256": "0bb57ee8557aad33317eeb881e3957b6fab776dd75473311c25789fa3a29f792",
        "size": 1042438,
    },
    "libstdcxx": {
        "name": "libstdcxx_15.3.0_linux-64.conda",
        "url": "https://conda.anaconda.org/conda-forge/linux-64/libstdcxx-15.3.0-h934c35e_7.conda",
        "sha256": "0c3dc08bf43357a77297b4449abd0ce1d40a140989f004071e69c04ed13e36bb",
        "size": 5836322,
    },
}

def strip_prefix(role):
    """The directory a zig archive unpacks into: its URL's file name without `.tar.xz`."""
    return PINS[role]["url"].split("/")[-1][:-len(".tar.xz")]
