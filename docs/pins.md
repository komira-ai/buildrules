# Pins (linux-x86_64; the other hosts are the last section)

`rules/rust/pins.bzl` `RUST_VERSIONS` holds one row per Rust version; the table below is the default, 1.95.0. The oldest
supported, 1.85.0: rustc 118068031 `bddacba2...2999`, rust-std 49657114 `b3ad2196...c4a9`, cargo 12817517 `e27ffcaf...c372`, clippy 4573789
`fe8fd470...122c`, every tarball downloaded from its versioned URL and sha256/size computed independently; `rustc --version` must start with
`rustc 1.85.0 (` and `cargo --version` with `cargo 1.85.0 (`. llvm-tools-preview 1.95.0 (for `isa_audit`):
66089964 bytes, `55b57b2a...1f7a`.

Rust 1.95.0. The URLs are the versioned ones, `https://static.rust-lang.org/dist/<component>-1.95.0-x86_64-unknown-linux-gnu.tar.gz`, which carry no date; every tarball was downloaded and
`sha256sum`/`stat` computed independently. buck2 re-checks the
sha256 of every pin on download (a wrong hash fails: `Invalid sha256 digest. Expected ..., got ...`).

| pin | file | size (bytes) | sha256 |
|---|---|---|---|
| rustc | rustc-1.95.0-x86_64-unknown-linux-gnu.tar.gz | 135179262 | fef749c4abb4b4bde5ebf773bec550003ce5b4410579cecd69a365e5c0c5106a |
| rust-std | rust-std-1.95.0-x86_64-unknown-linux-gnu.tar.gz | 49435219 | edbd20f8fc0a617f85ffb79fa6c22aa6def0e570de3f94be1a6e5ab1f77f763c |
| cargo | cargo-1.95.0-x86_64-unknown-linux-gnu.tar.gz | 15405121 | 47ebc468721a6ff3fb27dff33e632a4cb6246d0ea061814bcd4fe601d18c69a8 |
| zig 0.15.2 | zig-x86_64-linux-0.15.2.tar.xz | 53733924 | 02aa270f183da276e5b5920b1dac44a63f1a49e55050ebde3aecc9eb82f93239 |
| busybox 1.35.0 | busybox (static musl) | 1131168 | 6e123e7f3202a8c1e9b1f94d8941580a25135382b99e8d3e34fb858bba311348 |

xz variants (not used): rustc 80351960 / 8426a3d1...dfc15; rust-std 29573972 / 047ea709...aa382; cargo 10984780 / e74edd2c...07425.
`rustc --version` must start with `rustc 1.95.0 (` and `cargo --version` with `cargo 1.95.0 (`; an action refuses the toolchain otherwise.
Host floor: a Linux x86_64 kernel, glibc >= 2.34, and `libgcc_s.so.1` (rustc's driver needs it; it is not pinned yet).

## mopm 0.0.1

mopm 0.0.1 is the published release, https://github.com/komira-ai/mopm/releases/tag/v0.0.1, pinned in `rules/mopm/pins.bzl`. Its linux-x86_64 asset
`mopm-0.0.1-linux-x86_64.tar.gz` is 980653 bytes with sha256 `80ac2ed492f0a9ab809d763fc9cf39cbb97d507dd69bd7a61be248a85d5b23dc`, the digest in the release's
`SHA256SUMS` (downloaded and compared, 2026-10-20); it unpacks into `mopm-0.0.1-linux-x86_64/` holding `mopm` and `LICENSE`.

## Mirrors

`buildrules.url_map` (rules/core/url_map.bzl) replaces the leading part of a download's URL and nothing else: the sha256 and size are still checked, so a mirror
cannot change the bytes. buck2's `http_file` and `download_file` take one URL and have no fallback, so a mirror is not a second URL on a pin; it is a map a machine
(or the beta stage's retry, `mirror_map` in tools/stage/beta.zig) sets when the primary host fails. Each row below was downloaded from both hosts and the sha256 compared
with the pin's (2026-10-20):

| primary prefix | mirror prefix | pins | identical |
|---|---|---|---|
| `https://busybox.net/` | `https://web.archive.org/web/2024id_/https://busybox.net/` | busybox 1.35.0 | yes, 1131168 bytes, `6e123e7f...1348` |
| `https://ziglang.org/download/` | `https://zig.linus.dev/zig/` (listed in ziglang.org's community-mirrors.txt) | zig 0.12.0, zig 0.15.2 | yes, both |
| `https://conda.anaconda.org/conda-forge/` | `https://repo.prefix.dev/conda-forge/` | libgcc, libstdcxx | yes, both |
| `https://nodejs.org/dist/` | `https://registry.npmmirror.com/-/binary/node/` | node 24 | yes |

busybox.net has no mirror of its own that serves this binary: the byte-identical copy is the Internet Archive's capture of busybox.net, which is a fallback and not a
host to depend on (no SLA; it can be slow). No mirror was found or checked for `static.rust-lang.org` (CloudFront), `github.com` releases, `registry.npmjs.org`
or `static.crates.io`; those are fetched from their own hosts. A pin that must not depend on any of these hosts is the repository owner's decision: host the pins as assets of a
dedicated, immutable buildrules release (the upload is a step only the repository owner can do).

## Other hosts (linux-aarch64, macos-aarch64)

`rules/pins/hosts.bzl` holds the downloads the two other hosts need from the same upstream releases: zig 0.12.0 and 0.15.2, node 24.21.0 and rustc 1.95.0 and 1.85.0 with
rust-std, cargo, clippy (and llvm-tools for 1.95.0), for `aarch64-unknown-linux-gnu` and `aarch64-apple-darwin`. Sources: ziglang.org's `download/index.json` (zig), nodejs.org's `SHASUMS256.txt`
(node), the `.sha256` file beside each tarball on static.rust-lang.org (rust); the size is the file's `content-length`. `buck2 build //rules/pins:host_downloads`
downloads every row and fails on a sha256 or size that is not the file's; the `host_arm` job of `ci.yml` runs it on GitHub's `ubuntu-24.04-arm` runner, with the buck2 release that
`tools/buck2` pins for `linux-aarch64`.

What the pins do not do yet: nothing unpacks them. Every unpack action runs under the pinned busybox, and busybox.net publishes no static 1.35.0 for aarch64 (its multi-arch
1.31.0 build has only a 32-bit `armv8l`, which 64-bit-only Arm cores do not execute; not tried on a runner) and none for macOS. A first-party static build of the same source is the way out, and it is the
next step of the host work, not a pin that exists today.
