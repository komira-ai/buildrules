"""Which Rust toolchain a target compiles with.

The version comes from the generated table (`RUSTC`, read from rust-toolchain.toml by `buildrules sync`); the default of
`rust_library` and friends, which have no table, is `RUST_DEFAULT`. A TARGET PLATFORM can override it for a whole build,
which is how the CI matrix builds the same sources with the oldest compiler:

    buck2 test --target-platforms buildrules//platforms:linux_x86_64_rust_1_85_0 //examples/...

The override is a `select` on the `rust_version` constraint of `buildrules//platforms`, so it is part of the configuration:
every output path and every action key of the other compiler differs from the default's.
"""

load(":pins.bzl", "RUST_DEFAULT", "RUST_VERSIONS", "vname")

def toolchain_for(version = None):
    """The `toolchain` attribute value for a target whose table says `version` (None = RUST_DEFAULT)."""
    v = version or RUST_DEFAULT
    m = {"buildrules//platforms:rust_is_" + vname(k): "toolchains//:rust_" + vname(k) for k in RUST_VERSIONS}
    m["DEFAULT"] = "toolchains//:rust_" + vname(v)
    return select(m)

def has_llvm_tools(version = None):
    """True when buildrules pins the llvm-tools component of `version` (None = RUST_DEFAULT): a cargo member's `:coverage` needs it."""
    return "llvm_tools" in RUST_VERSIONS.get(version or RUST_DEFAULT, {})

def llvm_tools_for(version = None):
    """The llvm-tools of the toolchain `toolchain_for(version)` selects (llvm-profdata and llvm-cov read the profiles of that rustc only), or None
    for a version that pins none: `rust_coverage` refuses it by name (coverage.bzl)."""
    v = version or RUST_DEFAULT
    m = {"buildrules//platforms:rust_is_" + vname(k): ("toolchains//:llvm_tools_" + vname(k)) if has_llvm_tools(k) else None for k in RUST_VERSIONS}
    m["DEFAULT"] = ("toolchains//:llvm_tools_" + vname(v)) if has_llvm_tools(v) else None
    return select(m)

def rust_version_for(version = None):
    """The Rust release `toolchain_for(version)` selects, as its version string: what a refusal names."""
    m = {"buildrules//platforms:rust_is_" + vname(k): k for k in RUST_VERSIONS}
    m["DEFAULT"] = version or RUST_DEFAULT
    return select(m)
