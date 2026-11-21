# The toolchains of the fixture Mojo versions of examples/mojo/versions (its README.md), which toolchains/BUCK declares beside MOJO_TOOLCHAINS. No released mopm
# pins Mojo 1.1.0 or 1.2.0, so `buildrules mojo sync` cannot write these rows: they are the toolchain sections of the fixture's graphs, written by hand. The compiler
# package of each is the channel's own (url, sha256 and size of mojo-compiler 1.1.0 and 1.2.0 for linux-64); the closure hash is the fixture's, and the runtime
# packages and the zig are those of 1.0.0. Only the analysis of the fixture reads them (ci/mojo_versions.bzl); nothing builds them.
FIXTURE_MOJO_TOOLCHAINS = {
    "1.1.0": {
        "subdir": "linux-64",
        "cc_target": "x86_64-linux-gnu.2.34",
        "closure_sha256": "291873e432f256930c957d2e816a0e8bf8b750ff745e26469fc8ae6f92b7547f",
        "zig": {"version": "0.12.0", "url": "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz", "sha256": "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad", "size": 45480516},
        "components": [
            {"name": "libgcc", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libgcc-16.2.0-ha9f2e26_7.conda", "sha256": "e031634c3a928f9594eba868bc46ef5230d6571a364a0c63215b06c4563bfcea", "size": 1058444},
            {"name": "libstdcxx", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libstdcxx-16.2.0-h934c35e_7.conda", "sha256": "fa7018298629fc429971fffd6ecba3d27a7b02e4e890d6a93ea01ffebe8cb745", "size": 6615436},
            {"name": "mojo-compiler", "version": "1.1.0", "url": "https://conda.modular.com/max/linux-64/mojo-compiler-1.1.0-release.conda", "sha256": "1ff52b39a0d2a1bedb8c4705aadc460205ca62fc19f63426bc545e4b60a31aa0", "size": 69781261},
        ],
    },
    "1.2.0": {
        "subdir": "linux-64",
        "cc_target": "x86_64-linux-gnu.2.34",
        "closure_sha256": "dcff0208cf6e6e2217e863a311f72b8d3363aa1db21a0d6a964b29e4b8a87d49",
        "zig": {"version": "0.12.0", "url": "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz", "sha256": "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad", "size": 45480516},
        "components": [
            {"name": "libgcc", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libgcc-16.2.0-ha9f2e26_7.conda", "sha256": "e031634c3a928f9594eba868bc46ef5230d6571a364a0c63215b06c4563bfcea", "size": 1058444},
            {"name": "libstdcxx", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libstdcxx-16.2.0-h934c35e_7.conda", "sha256": "fa7018298629fc429971fffd6ecba3d27a7b02e4e890d6a93ea01ffebe8cb745", "size": 6615436},
            {"name": "mojo-compiler", "version": "1.2.0", "url": "https://conda.modular.com/max/linux-64/mojo-compiler-1.2.0-release.conda", "sha256": "a746d7db173a9882e7073ae6d905acfe383a754faecb4a53710b7b90db377e6b", "size": 71258238},
        ],
    },
}
