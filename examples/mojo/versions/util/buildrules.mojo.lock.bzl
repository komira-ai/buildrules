# Fixture (examples/mojo/versions/README.md): what `buildrules mojo sync` writes for a mopm.toml that lists three Mojo versions. GRAPH is the pinned mopm's
# own output for Mojo 1.0.0; no released mopm pins 1.1.0 or 1.2.0, so their blocks are that graph with the version, the compiler package and the closure
# hash replaced by hand, and MOJOS names the three.
SCHEMA = 1
MOPM = {"version": "0.0.48", "origin": "builtin", "workspace_root": True}
MOJO = "1.0.0"
CLOSURE_SHA256 = "fd654c4192487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d"
MANIFEST_SHA256 = {
    "../../mopm-toolchain.toml": "9448a09a1f7bd0e205c1044dd369f6143163628a3ebb027034fe0272d2065750",
    "mopm.lock": "751f5d668f2483078b4260e8cf447516edce9d17ae8fe41dc5687fd0e151b6ad",
    "mopm.toml": "109050e0666090ae49f7f0acd0bea094fdcc6c1c8dbeb040a5e517f3e850e4e1",
}
GRAPH_JSON = r'''{
  "unit_graph": 2,
  "package": "versions_util@0.1.0",
  "mojo": "1.0.0",
  "toolchain": {
    "mojo": "1.0.0",
    "subdir": "linux-64",
    "cc_target": "x86_64-linux-gnu.2.34",
    "closure_sha256": "fd654c4192487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d",
    "zig": {"version": "0.12.0", "url": "https://ziglang.org/download/0.12.0/zig-linux-x86_64-0.12.0.tar.xz", "sha256": "c7ae866b8a76a568e2d5cfd31fe89cdb629bdd161fdd5018b29a4a0a17045cad", "size": 45480516},
    "components": [
      {"name": "libgcc", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libgcc-16.2.0-ha9f2e26_7.conda", "sha256": "e031634c3a928f9594eba868bc46ef5230d6571a364a0c63215b06c4563bfcea", "size": 1058444},
      {"name": "libstdcxx", "version": "16.2.0", "url": "https://conda.anaconda.org/conda-forge/linux-64/libstdcxx-16.2.0-h934c35e_7.conda", "sha256": "fa7018298629fc429971fffd6ecba3d27a7b02e4e890d6a93ea01ffebe8cb745", "size": 6615436},
      {"name": "mojo-compiler", "version": "1.0.0", "url": "https://conda.modular.com/max/linux-64/mojo-compiler-1.0.0-release.conda", "sha256": "4394c6146d47ec7794a9a3ed5775ae158f59f83f8e1aed59408b17c4909821b3", "size": 68511359}
    ]
  },
  "units": [
    {
      "id": "versions_util@0.1.0#mojo1.0.0/lib",
      "package": "versions_util",
      "version": "0.1.0",
      "kind": "lib",
      "root": "examples/mojo/versions/util/src/versions_util",
      "srcs": [
        {"path": "examples/mojo/versions/util/src/versions_util/__init__.mojo", "sha256": "2ce9c435c8bc0b4987ec1044dbc7d7673245633ba94debefd96df2c4e53c97ed"}
      ],
      "deps": [],
      "natives": [],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["versions_util.mojoc"],
      "key": "6b13cb7598e4e58bedc95d2299a787015b06a9bf522cac48e49f70366af506f2"
    },
    {
      "id": "versions_util@0.1.0#mojo1.0.0/test:examples/mojo/versions/util/tests/test_versions_util.mojo",
      "package": "versions_util",
      "version": "0.1.0",
      "kind": "test",
      "srcs": [
        {"path": "examples/mojo/versions/util/tests/test_versions_util.mojo", "sha256": "6ee20a7b3f3c34cc02ccdf5d3272274b3427f0cddaa3dac626976426d9941b4c"}
      ],
      "deps": ["versions_util@0.1.0#mojo1.0.0/lib"],
      "natives": [],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["test_versions_util.pass"],
      "key": "50b43d861d741235c60dd02c54da8ff04a3e0e4ea2ef851ce3b5792c56a9ad85"
    }
  ]
}
'''
GRAPH = json.decode(GRAPH_JSON)
GRAPH_JSON_MOJO_1_1_0 = r'''{
  "unit_graph": 2,
  "package": "versions_util@0.1.0",
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
      "id": "versions_util@0.1.0#mojo1.1.0/lib",
      "package": "versions_util",
      "version": "0.1.0",
      "kind": "lib",
      "root": "examples/mojo/versions/util/src/versions_util",
      "srcs": [
        {"path": "examples/mojo/versions/util/src/versions_util/__init__.mojo", "sha256": "2ce9c435c8bc0b4987ec1044dbc7d7673245633ba94debefd96df2c4e53c97ed"}
      ],
      "deps": [],
      "natives": [],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["versions_util.mojoc"],
      "key": "238195b977fe13d83e09d06dcb3db6d6325662988cbebe7c715d572431eb563d"
    },
    {
      "id": "versions_util@0.1.0#mojo1.1.0/test:examples/mojo/versions/util/tests/test_versions_util.mojo",
      "package": "versions_util",
      "version": "0.1.0",
      "kind": "test",
      "srcs": [
        {"path": "examples/mojo/versions/util/tests/test_versions_util.mojo", "sha256": "6ee20a7b3f3c34cc02ccdf5d3272274b3427f0cddaa3dac626976426d9941b4c"}
      ],
      "deps": ["versions_util@0.1.0#mojo1.1.0/lib"],
      "natives": [],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["test_versions_util.pass"],
      "key": "e29d3e70c0fcee88d9be97488bd834a4781f375dfe86ee1ed784eeefbc8c1336"
    }
  ]
}
'''
GRAPH_JSON_MOJO_1_2_0 = r'''{
  "unit_graph": 2,
  "package": "versions_util@0.1.0",
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
      "id": "versions_util@0.1.0#mojo1.2.0/lib",
      "package": "versions_util",
      "version": "0.1.0",
      "kind": "lib",
      "root": "examples/mojo/versions/util/src/versions_util",
      "srcs": [
        {"path": "examples/mojo/versions/util/src/versions_util/__init__.mojo", "sha256": "2ce9c435c8bc0b4987ec1044dbc7d7673245633ba94debefd96df2c4e53c97ed"}
      ],
      "deps": [],
      "natives": [],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["versions_util.mojoc"],
      "key": "3111353630458895f5ae4979b1ef604fa424fed1ae2f29a72321ef57e6206ffa"
    },
    {
      "id": "versions_util@0.1.0#mojo1.2.0/test:examples/mojo/versions/util/tests/test_versions_util.mojo",
      "package": "versions_util",
      "version": "0.1.0",
      "kind": "test",
      "srcs": [
        {"path": "examples/mojo/versions/util/tests/test_versions_util.mojo", "sha256": "6ee20a7b3f3c34cc02ccdf5d3272274b3427f0cddaa3dac626976426d9941b4c"}
      ],
      "deps": ["versions_util@0.1.0#mojo1.2.0/lib"],
      "natives": [],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["test_versions_util.pass"],
      "key": "e0a0a5dc00f1e802b666af9665139d7d6357b0cda75a43cdd2e3e8092c885236"
    }
  ]
}
'''
MOJOS = {
    "1.0.0": {"CLOSURE_SHA256": CLOSURE_SHA256, "GRAPHS": {"linux-64": GRAPH}},
    "1.1.0": {"CLOSURE_SHA256": "291873e432f256930c957d2e816a0e8bf8b750ff745e26469fc8ae6f92b7547f", "GRAPHS": {"linux-64": json.decode(GRAPH_JSON_MOJO_1_1_0)}},
    "1.2.0": {"CLOSURE_SHA256": "dcff0208cf6e6e2217e863a311f72b8d3363aa1db21a0d6a964b29e4b8a87d49", "GRAPHS": {"linux-64": json.decode(GRAPH_JSON_MOJO_1_2_0)}},
}
