"""The public surface of the Rust rules: load this from a BUCK file.

    load("@buildrules//rules/rust:defs.bzl", "rust_library", "rust_binary", "rust_test")

and, for a repository that already builds with cargo, the two macros of docs/contract.md (a consumer's BUCK files load them
through the `buildrules.bzl` that `buildrules sync` writes, which binds the generated table):

    load("@buildrules//rules/rust:defs.bzl", "cargo_workspace", "cargo_package")
"""

load(":cargo.bzl", _cargo_package = "cargo_package", _cargo_workspace = "cargo_workspace")
load(":rust.bzl", _rust_binary = "rust_binary", _rust_library = "rust_library", _rust_test = "rust_test")

rust_library = _rust_library
rust_binary = _rust_binary
rust_test = _rust_test
cargo_workspace = _cargo_workspace
cargo_package = _cargo_package
