# Fixture (examples/mojo/versions/README.md): what `buildrules mojo sync` writes for a mopm.toml that lists three Mojo versions. GRAPH is the pinned mopm's
# own output for Mojo 1.0.0; no released mopm pins 1.1.0 or 1.2.0, so their blocks are that graph with the version, the compiler package, the closure
# hash and the registry package's .conda (another file for each version, and version 0.2.0 of it for 1.2.0) replaced by hand, and MOJOS names the three.
SCHEMA = 1
MOPM = {"version": "0.0.113", "origin": "builtin", "workspace_root": True}
MOJO = "1.0.0"
CLOSURE_SHA256 = "3ed75e01401544e0d660ee48dc387dacce437e3833ac296d4a0601f28abd4aec"
MANIFEST_SHA256 = {
    "mopm-toolchain.toml": "28caecebbd467308200bf8254ead6d279a9263d7fb4c31cb10841a972174acd3",
    "mopm.lock": "a8508d0ebdf652e7611ace8b2066d758f6d91cafe6f301807ce8ec476f09fccc",
    "mopm.toml": "4290d6f4a61c0672d0c1030586f56ea20104f42ed3b03c932a16df90843b1473",
}
GRAPH_JSON = r'''{
  "unit_graph": 6,
  "package": "example/versions_reg@0.1.0",
  "mojo": "1.0.0",
  "toolchain": {
    "mojo": "1.0.0",
    "subdir": "linux-64",
    "cc_target": "x86_64-linux-gnu.2.34",
    "closure_sha256": "3ed75e01401544e0d660ee48dc387dacce437e3833ac296d4a0601f28abd4aec",
    "zig": {"version": "0.12.0", "url": "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz", "sha256": "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad", "size": 45480516},
    "components": [
      {"name": "libgcc", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libgcc-16.2.0-ha9f2e26_7.conda", "sha256": "e031634c3a928f9594eba868bc46ef5230d6571a364a0c63215b06c4563bfcea", "size": 1058444},
      {"name": "libstdcxx", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libstdcxx-16.2.0-h934c35e_7.conda", "sha256": "fa7018298629fc429971fffd6ecba3d27a7b02e4e890d6a93ea01ffebe8cb745", "size": 6615436},
      {"name": "mojo-compiler", "version": "1.0.0", "url": "https://conda.modular.com/max/linux-64/mojo-compiler-1.0.0-release.conda", "sha256": "4394c6146d47ec7794a9a3ed5775ae158f59f83f8e1aed59408b17c4909821b3", "size": 68511359}
    ]
  },
  "units": [
    {
      "id": "example/nsshim@0.1.0#mojo1.0.0/lib",
      "package": "example/nsshim",
      "import": "nsshim",
      "version": "0.1.0",
      "kind": "prebuilt",
      "artifact": {"url": "https://conda.mopm.dev/example/linux-64/mojo-example.nsshim-0.1.0-mojo1.0.0_0.conda", "sha256": "f24c096910516f27e29a194e61b082cf53299b5397d62966fe2f36af6a01f968", "size": 42521},
      "mojoc": "lib/mojo/nsshim.mojoc",
      "deps": [],
      "natives": [
        {"id": "nsshim", "soname": "libnsshim.a", "sha256": "50909f5da9e22fd69a84215328b774559eccf03c5239543ca6be022ae4948655", "package": "example/nsshim", "kind": "static"}
      ],
      "key": "79910b74da04fc4c42f49f83f26785f1c38d43cd85ac390c29d76c361108daae"
    },
    {
      "id": "example/versions_reg@0.1.0#mojo1.0.0/lib",
      "package": "example/versions_reg",
      "import": "versions_reg",
      "version": "0.1.0",
      "kind": "lib",
      "root": "examples/mojo/versions/reg/src/versions_reg",
      "srcs": [
        {"path": "examples/mojo/versions/reg/src/versions_reg/__init__.mojo", "sha256": "716a9398f28214da8b70e33de55d2daed1924d12f24961edbce406aaf0a252f5"}
      ],
      "deps": ["example/nsshim@0.1.0#mojo1.0.0/lib"],
      "natives": [
        {"id": "nsshim", "soname": "libnsshim.a", "sha256": "50909f5da9e22fd69a84215328b774559eccf03c5239543ca6be022ae4948655", "package": "example/nsshim", "kind": "static"}
      ],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["versions_reg.mojoc"],
      "key": "0f501d05b1617085e951f516b157bcbc48b9265daf6af5a4f9c0615a35f019bf"
    },
    {
      "id": "example/versions_reg@0.1.0#mojo1.0.0/test:examples/mojo/versions/reg/tests/test_versions_reg.mojo",
      "package": "example/versions_reg",
      "import": "versions_reg",
      "version": "0.1.0",
      "kind": "test",
      "srcs": [
        {"path": "examples/mojo/versions/reg/tests/test_versions_reg.mojo", "sha256": "87c73a23e18a3c9f48213cd81ea007b178dc31245115fcf726a0d4f65743508a"}
      ],
      "deps": ["example/versions_reg@0.1.0#mojo1.0.0/lib"],
      "natives": [
        {"id": "nsshim", "soname": "libnsshim.a", "sha256": "50909f5da9e22fd69a84215328b774559eccf03c5239543ca6be022ae4948655", "package": "example/nsshim", "kind": "static"}
      ],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["test_versions_reg.pass"],
      "key": "9aae55c045bc89c993bf123d6f5c50dd9ce02e839a656b8a548860ac637b6610"
    }
  ]
}
'''
GRAPH = json.decode(GRAPH_JSON)
GRAPH_JSON_MOJO_1_1_0 = r'''{
  "unit_graph": 6,
  "package": "example/versions_reg@0.1.0",
  "mojo": "1.1.0",
  "toolchain": {
    "mojo": "1.1.0",
    "subdir": "linux-64",
    "cc_target": "x86_64-linux-gnu.2.34",
    "closure_sha256": "291873e432f256930c957d2e816a0e8bf8b750ff745e26469fc8ae6f92b7547f",
    "zig": {"version": "0.12.0", "url": "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz", "sha256": "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad", "size": 45480516},
    "components": [
      {"name": "libgcc", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libgcc-16.2.0-ha9f2e26_7.conda", "sha256": "e031634c3a928f9594eba868bc46ef5230d6571a364a0c63215b06c4563bfcea", "size": 1058444},
      {"name": "libstdcxx", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libstdcxx-16.2.0-h934c35e_7.conda", "sha256": "fa7018298629fc429971fffd6ecba3d27a7b02e4e890d6a93ea01ffebe8cb745", "size": 6615436},
      {"name": "mojo-compiler", "version": "1.1.0", "url": "https://conda.modular.com/max/linux-64/mojo-compiler-1.1.0-release.conda", "sha256": "1ff52b39a0d2a1bedb8c4705aadc460205ca62fc19f63426bc545e4b60a31aa0", "size": 69781261}
    ]
  },
  "units": [
    {
      "id": "example/nsshim@0.1.0#mojo1.1.0/lib",
      "package": "example/nsshim",
      "import": "nsshim",
      "version": "0.1.0",
      "kind": "prebuilt",
      "artifact": {"url": "https://conda.mopm.dev/example/linux-64/mojo-example.nsshim-0.1.0-mojo1.1.0_0.conda", "sha256": "213bc019ef3da1dbd14753cb010650bf7ba7a709d992fdbf8ab249c918f26910", "size": 43117},
      "mojoc": "lib/mojo/nsshim.mojoc",
      "deps": [],
      "natives": [
        {"id": "nsshim", "soname": "libnsshim.a", "sha256": "7b07e34cd389f11fae525977dc11d5c1f0ab45dfaf43b59fc47b958846e8f1f6", "package": "example/nsshim", "kind": "static"}
      ],
      "key": "191b8d3a09bab4efef430a75f1a1d48aab52f76362f2c2adcdc493bf85ca10d1"
    },
    {
      "id": "example/versions_reg@0.1.0#mojo1.1.0/lib",
      "package": "example/versions_reg",
      "import": "versions_reg",
      "version": "0.1.0",
      "kind": "lib",
      "root": "examples/mojo/versions/reg/src/versions_reg",
      "srcs": [
        {"path": "examples/mojo/versions/reg/src/versions_reg/__init__.mojo", "sha256": "716a9398f28214da8b70e33de55d2daed1924d12f24961edbce406aaf0a252f5"}
      ],
      "deps": ["example/nsshim@0.1.0#mojo1.1.0/lib"],
      "natives": [
        {"id": "nsshim", "soname": "libnsshim.a", "sha256": "7b07e34cd389f11fae525977dc11d5c1f0ab45dfaf43b59fc47b958846e8f1f6", "package": "example/nsshim", "kind": "static"}
      ],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["versions_reg.mojoc"],
      "key": "51976d3319ea09f516b5d758771644d4f6d2f25c5d03fb4026c0f43fa84cbe42"
    },
    {
      "id": "example/versions_reg@0.1.0#mojo1.1.0/test:examples/mojo/versions/reg/tests/test_versions_reg.mojo",
      "package": "example/versions_reg",
      "import": "versions_reg",
      "version": "0.1.0",
      "kind": "test",
      "srcs": [
        {"path": "examples/mojo/versions/reg/tests/test_versions_reg.mojo", "sha256": "87c73a23e18a3c9f48213cd81ea007b178dc31245115fcf726a0d4f65743508a"}
      ],
      "deps": ["example/versions_reg@0.1.0#mojo1.1.0/lib"],
      "natives": [
        {"id": "nsshim", "soname": "libnsshim.a", "sha256": "7b07e34cd389f11fae525977dc11d5c1f0ab45dfaf43b59fc47b958846e8f1f6", "package": "example/nsshim", "kind": "static"}
      ],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["test_versions_reg.pass"],
      "key": "b0b0e3e492970d89ffdb332c14ab2a34133ad98167091b686a751493bec36fb2"
    }
  ]
}
'''
GRAPH_JSON_MOJO_1_2_0 = r'''{
  "unit_graph": 6,
  "package": "example/versions_reg@0.1.0",
  "mojo": "1.2.0",
  "toolchain": {
    "mojo": "1.2.0",
    "subdir": "linux-64",
    "cc_target": "x86_64-linux-gnu.2.34",
    "closure_sha256": "dcff0208cf6e6e2217e863a311f72b8d3363aa1db21a0d6a964b29e4b8a87d49",
    "zig": {"version": "0.12.0", "url": "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz", "sha256": "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad", "size": 45480516},
    "components": [
      {"name": "libgcc", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libgcc-16.2.0-ha9f2e26_7.conda", "sha256": "e031634c3a928f9594eba868bc46ef5230d6571a364a0c63215b06c4563bfcea", "size": 1058444},
      {"name": "libstdcxx", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libstdcxx-16.2.0-h934c35e_7.conda", "sha256": "fa7018298629fc429971fffd6ecba3d27a7b02e4e890d6a93ea01ffebe8cb745", "size": 6615436},
      {"name": "mojo-compiler", "version": "1.2.0", "url": "https://conda.modular.com/max/linux-64/mojo-compiler-1.2.0-release.conda", "sha256": "a746d7db173a9882e7073ae6d905acfe383a754faecb4a53710b7b90db377e6b", "size": 71258238}
    ]
  },
  "units": [
    {
      "id": "example/nsshim@0.2.0#mojo1.2.0/lib",
      "package": "example/nsshim",
      "import": "nsshim",
      "version": "0.2.0",
      "kind": "prebuilt",
      "artifact": {"url": "https://conda.mopm.dev/example/linux-64/mojo-example.nsshim-0.2.0-mojo1.2.0_0.conda", "sha256": "3eb9a64e5ce7cbf11978f502bba1c0f99e688a279e58799f5cee84392050f190", "size": 44203},
      "mojoc": "lib/mojo/nsshim.mojoc",
      "deps": [],
      "natives": [
        {"id": "nsshim", "soname": "libnsshim.a", "sha256": "2bd03cdb1a8fdc1ac277d681dc530319b143fd61fe223d04be95b01cd97b21dd", "package": "example/nsshim", "kind": "static"}
      ],
      "key": "115b78063cf4d2824693c0012e64e72b805447290d8144996686d3df5a5a6787"
    },
    {
      "id": "example/versions_reg@0.1.0#mojo1.2.0/lib",
      "package": "example/versions_reg",
      "import": "versions_reg",
      "version": "0.1.0",
      "kind": "lib",
      "root": "examples/mojo/versions/reg/src/versions_reg",
      "srcs": [
        {"path": "examples/mojo/versions/reg/src/versions_reg/__init__.mojo", "sha256": "716a9398f28214da8b70e33de55d2daed1924d12f24961edbce406aaf0a252f5"}
      ],
      "deps": ["example/nsshim@0.2.0#mojo1.2.0/lib"],
      "natives": [
        {"id": "nsshim", "soname": "libnsshim.a", "sha256": "2bd03cdb1a8fdc1ac277d681dc530319b143fd61fe223d04be95b01cd97b21dd", "package": "example/nsshim", "kind": "static"}
      ],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["versions_reg.mojoc"],
      "key": "9809285c91136f9e69485e3384cc3e9c465200243b0ff696889d98e7eb4741ea"
    },
    {
      "id": "example/versions_reg@0.1.0#mojo1.2.0/test:examples/mojo/versions/reg/tests/test_versions_reg.mojo",
      "package": "example/versions_reg",
      "import": "versions_reg",
      "version": "0.1.0",
      "kind": "test",
      "srcs": [
        {"path": "examples/mojo/versions/reg/tests/test_versions_reg.mojo", "sha256": "87c73a23e18a3c9f48213cd81ea007b178dc31245115fcf726a0d4f65743508a"}
      ],
      "deps": ["example/versions_reg@0.1.0#mojo1.2.0/lib"],
      "natives": [
        {"id": "nsshim", "soname": "libnsshim.a", "sha256": "2bd03cdb1a8fdc1ac277d681dc530319b143fd61fe223d04be95b01cd97b21dd", "package": "example/nsshim", "kind": "static"}
      ],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["test_versions_reg.pass"],
      "key": "52101aeaad6d00b997e9195a0297f8b7eb73af5ec8393b10af771d8554ed40e6"
    }
  ]
}
'''
MOJOS = {
    "1.0.0": {"CLOSURE_SHA256": CLOSURE_SHA256, "GRAPHS": {"linux-64": GRAPH}},
    "1.1.0": {"CLOSURE_SHA256": "291873e432f256930c957d2e816a0e8bf8b750ff745e26469fc8ae6f92b7547f", "GRAPHS": {"linux-64": json.decode(GRAPH_JSON_MOJO_1_1_0)}},
    "1.2.0": {"CLOSURE_SHA256": "dcff0208cf6e6e2217e863a311f72b8d3363aa1db21a0d6a964b29e4b8a87d49", "GRAPHS": {"linux-64": json.decode(GRAPH_JSON_MOJO_1_2_0)}},
}
