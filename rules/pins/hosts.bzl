"""Downloads of the hosts other than linux x86_64: URL, sha256, size in bytes. Read by BUCK in this directory.

buildrules v0 runs its actions on linux x86_64 (`pins.bzl`, `rules/rust/pins.bzl`, `rules/node/pins.bzl`). The rows below are what the other
hosts need from the same upstream releases, so that a runner of that kind (GitHub's `ubuntu-24.04-arm`, `macos-15`) can fetch them. A host is a
key of `HOST_PINS`: `<os>-<cpu>`, the spelling `host_info()` and tools/buck2 use.

Where each value comes from (the same rule as docs/pins.md): zig and node from the release index of the vendor (ziglang.org/download/index.json,
nodejs.org/dist/v24.21.0/SHASUMS256.txt), rustc and its components from the `.sha256` beside each tarball on static.rust-lang.org. The size is the
`content-length` of the file. `buck2 build //rules/pins:host_downloads` downloads every row and compares the bytes with the sha256 and the size, so a
row that is wrong fails there (on the farm and on a runner), not at the first compile.

What is NOT here, and what stops a host from compiling (docs/pins.md):
  - linux-aarch64 and macos-aarch64 have no pinned `busybox`. busybox.net publishes no static aarch64 1.35.0 binary and none for macOS, and every
    unpack action runs under it. Until that is settled the downloads are pinned and checked but nothing unpacks them.
  - conda-forge runtime libraries (libgcc, libstdcxx) and the Mojo packages of these hosts: `buildrules mojo sync` writes them from mopm's unit graph.
"""

_RUST_DIST = "https://static.rust-lang.org/dist/"
_ZIG = "https://ziglang.org/download/"

def _rust(triple, version, role, dir, sha256, size):
    f = "{}-{}-{}.tar.gz".format(dir, version, triple)
    return {"name": f, "url": _RUST_DIST + f, "sha256": sha256, "size": size, "role": role}

HOST_PINS = {
    "linux-aarch64": {
        # zig 0.12.0: the default `zig` of the zig rules, and the C link driver of rustc.
        "zig": {
            "name": "zig_linux_aarch64.tar.xz",
            "url": _ZIG + "0.12.0/zig-linux-aarch64-0.12.0.tar.xz",
            "sha256": "754f1029484079b7e0ca3b913a0a2f2a6afd5a28990cb224fe8845e72f09de63",
            "size": 41849060,
        },
        # zig 0.15.2: builds the gate, kpin and the node tools.
        "zig_next": {
            "name": "zig_next_linux_aarch64.tar.xz",
            "url": _ZIG + "0.15.2/zig-aarch64-linux-0.15.2.tar.xz",
            "sha256": "958ed7d1e00d0ea76590d27666efbf7a932281b3d7ba0c6b01b0ff26498f667f",
            "size": 49471996,
        },
        "node": {
            "name": "node-v24.21.0-linux-arm64.tar.gz",
            "url": "https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-arm64.tar.gz",
            "sha256": "724282c3b43aec998aa9527380465b45d229e021b58035f5f4f63095eabfe5d5",
            "size": 57824078,
        },
        "rust": {
            "triple": "aarch64-unknown-linux-gnu",
            "zig_target": "aarch64-linux-gnu.2.34",
            "versions": {
                "1.95.0": [
                    _rust("aarch64-unknown-linux-gnu", "1.95.0", "rustc", "rustc", "f488f7eced24d2fed2e4745f3dbccf1ffe24bfe02720e5415406195ceaf45f7a", 102041932),
                    _rust("aarch64-unknown-linux-gnu", "1.95.0", "rust_std", "rust-std", "a68e71b09f4e09f7071c650ec38ee1845ddfe66c46917c0ccf0b1636994b01c6", 46976152),
                    _rust("aarch64-unknown-linux-gnu", "1.95.0", "cargo", "cargo", "f37440984c4c06d38487138adae2c5c80ec4ddfbdfe57ae387357995bfa502e9", 15348987),
                    _rust("aarch64-unknown-linux-gnu", "1.95.0", "clippy", "clippy", "84480abfbfed89616b1e0b35acb9db84766f0353b671766638084f4e9b1d1143", 5834918),
                    _rust("aarch64-unknown-linux-gnu", "1.95.0", "llvm_tools", "llvm-tools", "9616f41ef72ca4dc217d6a8f5511c18e254db397632d5ffcb69ffce55c88b587", 50746254),
                ],
                "1.85.0": [
                    _rust("aarch64-unknown-linux-gnu", "1.85.0", "rustc", "rustc", "e54c03bc6c8d00f400e56137086f62a73dac1c531113c7824ceccef3e6fdc198", 170062623),
                    _rust("aarch64-unknown-linux-gnu", "1.85.0", "rust_std", "rust-std", "63f8c57c2433e5ac970a9512660b8ca86002699bad4de5a2287fc591a7091e49", 58948563),
                    _rust("aarch64-unknown-linux-gnu", "1.85.0", "cargo", "cargo", "08fd45dd98dc1f60084e1156c0982e5f3d564a6da0d738f4a4a528c8f8dc8299", 14053406),
                    _rust("aarch64-unknown-linux-gnu", "1.85.0", "clippy", "clippy", "2f161d6bbb146766d00ea96b1e3143a3f50b28c3c7e1c99f4e5b11e2ff60c236", 5307274),
                ],
            },
        },
    },
    "macos-aarch64": {
        "zig": {
            "name": "zig_macos_aarch64.tar.xz",
            "url": _ZIG + "0.12.0/zig-macos-aarch64-0.12.0.tar.xz",
            "sha256": "294e224c14fd0822cfb15a35cf39aa14bd9967867999bf8bdfe3db7ddec2a27f",
            "size": 43447724,
        },
        "zig_next": {
            "name": "zig_next_macos_aarch64.tar.xz",
            "url": _ZIG + "0.15.2/zig-aarch64-macos-0.15.2.tar.xz",
            "sha256": "3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b",
            "size": 50635984,
        },
        "node": {
            "name": "node-v24.21.0-darwin-arm64.tar.gz",
            "url": "https://nodejs.org/dist/v24.21.0/node-v24.21.0-darwin-arm64.tar.gz",
            "sha256": "bed7eea5325e1108f32ce5228ddd6a5f0f08a499ee42aa7442aea583702f6057",
            "size": 52909993,
        },
        "rust": {
            "triple": "aarch64-apple-darwin",
            "zig_target": "aarch64-macos",
            "versions": {
                "1.95.0": [
                    _rust("aarch64-apple-darwin", "1.95.0", "rustc", "rustc", "64f20ce6864040b822b8fbdb7dbfd892e5b04828ca8cbd1e6accef9694da3ebb", 115710488),
                    _rust("aarch64-apple-darwin", "1.95.0", "rust_std", "rust-std", "c64f139c2a4f973b3d8b26482673909043545db14f0b1255ed743844e9f9ce99", 42858710),
                    _rust("aarch64-apple-darwin", "1.95.0", "cargo", "cargo", "0421d71bd676f0d38e318bf3eb7cd1a9ca33cf5ccf70f49644950a91fa046de7", 12758395),
                    _rust("aarch64-apple-darwin", "1.95.0", "clippy", "clippy", "ff1fd77e514985dda551b050f762fb3e54e4b8f49a56bc69788a571d310b8d36", 4700287),
                    _rust("aarch64-apple-darwin", "1.95.0", "llvm_tools", "llvm-tools", "c8b7851f83d232c2abf5dbca31af43701deca0973ac7eb7cd1741c180396b7db", 117088111),
                ],
                "1.85.0": [
                    _rust("aarch64-apple-darwin", "1.85.0", "rustc", "rustc", "458d9ccfab76f4d98ab363bd8575d6ba7cb2b2e4e88ec247334962d416657b31", 94300473),
                    _rust("aarch64-apple-darwin", "1.85.0", "rust_std", "rust-std", "b7ff9bc2cabc6277e2ec6d73ca5b3e5ea5e2a0582e5e5302ef9e354f348dab68", 42738512),
                    _rust("aarch64-apple-darwin", "1.85.0", "cargo", "cargo", "b280ffddaefd6ce6979390ccdadfbb222eebcb85d070286bff56c8fb016ada30", 10092345),
                    _rust("aarch64-apple-darwin", "1.85.0", "clippy", "clippy", "668cb7689ac1b0f0b79d11c282e554e2706d9a4ba0455208064467ea956cbeec", 4083547),
                ],
            },
        },
    },
}

def host_downloads(host):
    """Every download of `host` as a list of {name, url, sha256, size} (the `name` is the target name of its `pinned_file`)."""
    row = HOST_PINS[host]
    out = []
    for role in ["zig", "zig_next", "node"]:
        out.append(dict(row[role]))
    for version, comps in row["rust"]["versions"].items():
        for c in comps:
            d = dict(c)
            d["name"] = "rust_{}_{}".format(version.replace(".", "_"), c["name"])
            out.append(d)
    return out
