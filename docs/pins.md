# Pins (linux-x86_64)

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
