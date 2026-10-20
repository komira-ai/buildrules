# A FIXTURE, not the output of `buildrules sync` (which refuses a Rust it does not pin): the table a buildrules that pinned 1.50.0 wrote,
# as a repository still has it after that pin was dropped. Only RUSTC and TOOLCHAIN are read before cargo_package refuses.

SCHEMA = 2
RUSTC = "1.50.0"
TARGET = "x86_64-unknown-linux-gnu"
CARGO_LOCK_SHA256 = "0000000000000000000000000000000000000000000000000000000000000000"
MANIFEST_SHA256 = {
}

TOOLCHAIN = {
    "version": "1.50.0",
    "origin": "builtin",
    "default": False,
    "sha256": {
        "cargo": "1111111111111111111111111111111111111111111111111111111111111111",
        "clippy": "2222222222222222222222222222222222222222222222222222222222222222",
        "rust_std": "3333333333333333333333333333333333333333333333333333333333333333",
        "rustc": "4444444444444444444444444444444444444444444444444444444444444444",
    },
}

WORKSPACE = {
    "actions": {},
    "default_action": None,
    "clippy_conf": None,
}

PACKAGES = {}

GRAPHS = {}

MEMBERS = {}

UNITS = {
}
