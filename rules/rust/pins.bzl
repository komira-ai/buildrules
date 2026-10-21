"""Every download buildrules makes: URL, sha256, size in bytes. linux-x86_64 only.

Rust: `RUST_VERSIONS` maps an exact release to the sha256 and size of its component tarballs. They are fetched from the
versioned URLs (https://static.rust-lang.org/dist/rustc-<version>-<triple>.tar.gz, and the same for the other components),
which carry no date; each tarball was downloaded and its sha256 and size computed independently (docs/pins.md). The toolchain
checks `rustc --version` and `cargo --version` against the prefix `rustc <version> (` and `cargo <version> (` only.
`RUST_DEFAULT` is the version `toolchains//:rust` is; `RUST_OLDEST`
is the oldest buildrules supports. The dict is pure literals: `buildrules sync` (cli/src/unitgen.zig) reads it as a literal.
The release tarballs are the `.tar.gz` variants: the pinned busybox unpacks gzip with no
dictionary limit (the 1.99 `.tar.xz` of rustc has a 128 MiB xz dictionary it cannot read).

A version not in this table is refused unless the user supplies its hashes in `buildrules-pins.toml`
(docs/contract.md, section 6); `buildrules sync` copies them into `toolchains/rust_pins.bzl`, which has the same shape as one
value of this table, and `rust_toolchains()` declares one toolchain for each.
"""

RUST_TRIPLE = "x86_64-unknown-linux-gnu"
RUST_DEFAULT = "1.95.0"
RUST_OLDEST = "1.85.0"

RUST_VERSIONS = {
    "1.95.0": {
        "rustc": {"sha256": "fef749c4abb4b4bde5ebf773bec550003ce5b4410579cecd69a365e5c0c5106a", "size": 135179262},
        "rust_std": {"sha256": "edbd20f8fc0a617f85ffb79fa6c22aa6def0e570de3f94be1a6e5ab1f77f763c", "size": 49435219},
        "cargo": {"sha256": "47ebc468721a6ff3fb27dff33e632a4cb6246d0ea061814bcd4fe601d18c69a8", "size": 15405121},
        # clippy-driver (the `clippy-preview` component): lints run through it, linked against the sysroot's libraries.
        "clippy": {"sha256": "5230c92fb0ae1346ee30a1b4e01413cc3e1ead8ded20391fb2826619775f1ccb", "size": 7042718},
        # Optional (the `llvm-tools-preview` component): llvm-objdump for rules/rust/isa_audit.bzl. A version without it has no `:llvm_tools_<v>`.
        "llvm_tools": {"sha256": "55b57b2aff59cff2acffa1319513e7c74b0a09ef5a58e1d5f4beba4c8d911f7a", "size": 66089964},
    },
    # The oldest supported: edition 2024 needs 1.85.
    "1.85.0": {
        "rustc": {"sha256": "bddacba2c4008d27d6beb486dc701f8e39d7ce073053749c4d2c56013b6d2999", "size": 118068031},
        "rust_std": {"sha256": "b3ad21966023d24fac039385201dc4109a2f25e6f7a0a5b2a0910eccfdc0c4a9", "size": 49657114},
        "cargo": {"sha256": "e27ffcafa0c7a8eee305085155530974ba62edf5278548ba6de4e0674f55c372", "size": 12817517},
        "clippy": {"sha256": "fe8fd47014b7c240e84d658057d1296c75f75717e00c58990871bb0fa8c1122c", "size": 4573789},
    },
}

_COMPONENT_DIR = {"rustc": "rustc", "rust_std": "rust-std", "cargo": "cargo", "clippy": "clippy", "llvm_tools": "llvm-tools"}

def vname(version):
    """The suffix of a version's targets: `1.85.0` -> `1_85_0`."""
    return version.replace(".", "_")

def component(version, row, role):
    """One component of a version row as the `pinned_file` arguments: name, url, sha256, size."""
    f = "{}-{}-{}.tar.gz".format(_COMPONENT_DIR[role], version, RUST_TRIPLE)
    return {
        "name": f,
        "url": "https://static.rust-lang.org/dist/{}".format(f),
        "sha256": row[role]["sha256"],
        "size": row[role]["size"],
    }

PINS = {
    # zig 0.15.2: the C compiler and linker (`zig cc`).
    "zig": {
        "name": "zig_0.15.2_linux_x86_64.tar.xz",
        "url": "https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz",
        "sha256": "02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239",
        "size": 53733924,
    },
    # busybox 1.35.0, static musl: `sh` and the file utilities every unpack action uses.
    "busybox": {
        "name": "busybox",
        # The upstream file is https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox (static, musl); buck2 `download_file` takes one URL and has no fallback, so the pin
        # fetches the byte-identical copy held as an asset of the release `mirror-busybox-1.35.0` of this repository (tools/held/mirror-busybox.sh
        # downloads the upstream file, checks the sha256 and size below, and uploads it). The beta stage maps the prefix back to the upstream on a retry (docs/pins.md).
        "url": "https://github.com/komira-ai/buildrules/releases/download/mirror-busybox-1.35.0/busybox",
        "sha256": "6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348",
        "size": 1131168,
    },
}

# What the link steps target: glibc 2.34 or newer on the worker is all a built binary needs.
ZIG_CC_TARGET = "x86_64-linux-gnu.2.34"
ZIG_STRIP_PREFIX = "zig-x86_64-linux-0.15.2"
