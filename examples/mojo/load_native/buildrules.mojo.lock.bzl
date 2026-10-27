# Written BY HAND, not by `buildrules mojo sync`: the pinned mopm does not print unit graph format 3 (system_libs, loads) yet. The shape is the one of the
# design: a top-level `system_libs` array per subdir and a `loads` list on each test unit. The `key` of a unit is a placeholder (the sha256 of a sentence naming the
# subdir and the unit); no action reads it (a unit's slice for `mopm unit build` leaves it out). Everything else is as mopm prints it for this package, and the
# sha256 and size of each pin are those of the file conda-forge serves. `:table` therefore cannot be green here and is listed in EXCLUDED (ci/all.bzl); when the
# pinned mopm prints this format, `buildrules mojo sync` replaces this file and that entry goes.
SCHEMA = 1
MOPM = {"version": "0.0.73", "origin": "builtin", "workspace_root": True}
MOJO = "1.0.0"
CLOSURE_SHA256 = "fd654c4192487587d8f8d9402d060e45e218b79da7b8964503a703710e49b15d"
MANIFEST_SHA256 = {
    "mopm-toolchain.toml": "64dd09d9912bc4be02bfbeaf1e3319e5d52cf8a075ae6d49eec0e32d7e4f38fc",
    "mopm.lock": "7f4f35c22bf38597c0688630cbc857ef8b71b9ebcced62dab4dea0c31274af98",
    "mopm.toml": "8790a668d16934972699cfc33073edf92fd760b9dec03a96c93bb291779d7faa",
}
GRAPH_JSON = r'''{
  "unit_graph": 3,
  "package": "load_native@0.1.0",
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
  "system_libs": [
    {
      "name": "libbrotlicommon",
      "version": "1.2.1",
      "build": "h39a168f_0",
      "url": "https://conda.anaconda.org/conda-forge/linux-64/libbrotlicommon-1.2.1-h39a168f_0.conda",
      "sha256": "8eccfbfdb8ecba32eabfb6ee92f70e818e5f3a35a01c507f7b6bd56e00e4c617",
      "size": 80370
    },
    {
      "name": "libbrotlidec",
      "version": "1.2.1",
      "build": "ha411449_0",
      "url": "https://conda.anaconda.org/conda-forge/linux-64/libbrotlidec-1.2.1-ha411449_0.conda",
      "sha256": "4b4bda6f70ad511bdff95fdd958dca74b6e0534ae335ddcb1d8c6569774d2429",
      "size": 34703
    },
    {
      "name": "libsqlite",
      "version": "3.54.1",
      "build": "h0737f62_101",
      "url": "https://conda.anaconda.org/conda-forge/linux-64/libsqlite-3.54.1-h0737f62_101.conda",
      "sha256": "c294029f893d05286f1061bbab85b820f1eea73dd859af4bcc619197bcc34810",
      "size": 980491
    },
    {
      "name": "libzlib",
      "version": "1.3.2",
      "build": "h25fd6f3_3",
      "url": "https://conda.anaconda.org/conda-forge/linux-64/libzlib-1.3.2-h25fd6f3_3.conda",
      "sha256": "eb8a0db0aa570124f7d2a93d7c7f596e3390df5e047818d873baad32985fc736",
      "size": 63713
    }
  ],
  "units": [
    {
      "id": "load_native@0.1.0#mojo1.0.0/lib",
      "package": "load_native",
      "version": "0.1.0",
      "kind": "lib",
      "root": "examples/mojo/load_native/src/load_native",
      "srcs": [
        {"path": "examples/mojo/load_native/src/load_native/__init__.mojo", "sha256": "15d06fc92dfbf1d7ec6fe9ab0b3b38e7b4c251d18f78848de67f680c726fbe68"}
      ],
      "deps": [],
      "natives": [],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["load_native.mojoc"],
      "key": "7412f548f00a9ebfdaa4677f62cecae838d3b22cd394dbb22ec89ceb8e728969"
    },
    {
      "id": "load_native@0.1.0#mojo1.0.0/test:examples/mojo/load_native/tests/test_load_brotli.mojo",
      "package": "load_native",
      "version": "0.1.0",
      "kind": "test",
      "srcs": [
        {"path": "examples/mojo/load_native/tests/test_load_brotli.mojo", "sha256": "031993fab54d545f4953134e48aae4f0d94ec0886b0d64d3b6fd1926e4bd21e0"}
      ],
      "deps": ["load_native@0.1.0#mojo1.0.0/lib"],
      "natives": [],
      "loads": ["libbrotlicommon", "libbrotlidec"],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["test_load_brotli.pass"],
      "key": "e62b6355a648bd89b3e69af31b1cc161ead6c36baf43298b2bf9d2b86554a203"
    },
    {
      "id": "load_native@0.1.0#mojo1.0.0/test:examples/mojo/load_native/tests/test_load_sqlite.mojo",
      "package": "load_native",
      "version": "0.1.0",
      "kind": "test",
      "srcs": [
        {"path": "examples/mojo/load_native/tests/test_load_sqlite.mojo", "sha256": "bd6ca1ef36ad947669cb84ced2edb168ebad277cb109b65c29177d662f399308"}
      ],
      "deps": ["load_native@0.1.0#mojo1.0.0/lib"],
      "natives": [],
      "loads": ["libsqlite", "libzlib"],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["test_load_sqlite.pass"],
      "key": "1090c402de1e4a1ad1dffeffeccb599ab2f71588c9bc333b999d6662cecfe67e"
    }
  ]
}
'''
GRAPH = json.decode(GRAPH_JSON)
GRAPH_JSON_OSX_ARM64 = r'''{
  "unit_graph": 3,
  "package": "load_native@0.1.0",
  "mojo": "1.0.0",
  "toolchain": {
    "mojo": "1.0.0",
    "subdir": "osx-arm64",
    "cc_target": "aarch64-macos.11.0",
    "closure_sha256": "dfb1ddbe32564e406967054fbccd4ad643bf01e72532a3eb3add28253908ac5f",
    "zig": {"version": "0.12.0", "url": "https://ziglang.org/download/0.12.0/zig-macos-aarch64-0.12.0.tar.xz", "sha256": "294e224c14fd0822cfb15a35cf39aa14bd9967867999bf8bdfe3db7ddec2a27f", "size": 43447724},
    "components": [
      {"name": "mojo-compiler", "version": "1.0.0", "url": "https://conda.modular.com/max/osx-arm64/mojo-compiler-1.0.0-release.conda", "sha256": "c52054bc444d851e5c38cc33e790fb011a1080470244aaa59351ac5056d08c59", "size": 61221085}
    ]
  },
  "system_libs": [
    {
      "name": "libbrotlicommon",
      "version": "1.2.1",
      "build": "h1dcdb26_0",
      "url": "https://conda.anaconda.org/conda-forge/osx-arm64/libbrotlicommon-1.2.1-h1dcdb26_0.conda",
      "sha256": "4ee2413810c5ef07e29a4c2a39d11f08f27d17ecee3577541e4dad06f635b375",
      "size": 80086
    },
    {
      "name": "libbrotlidec",
      "version": "1.2.1",
      "build": "h5295a6a_0",
      "url": "https://conda.anaconda.org/conda-forge/osx-arm64/libbrotlidec-1.2.1-h5295a6a_0.conda",
      "sha256": "d77356267bf34639265ec79b217efe0b32fc2e91f4ca7a04263a5169cb156458",
      "size": 30090
    },
    {
      "name": "libsqlite",
      "version": "3.54.1",
      "build": "h34a968b_101",
      "url": "https://conda.anaconda.org/conda-forge/osx-arm64/libsqlite-3.54.1-h34a968b_101.conda",
      "sha256": "c49adf700ad17332b938ac627845a3fdc70a0810660d3ec3814de25b156fbf60",
      "size": 949450
    },
    {
      "name": "libzlib",
      "version": "1.3.2",
      "build": "h8088a28_3",
      "url": "https://conda.anaconda.org/conda-forge/osx-arm64/libzlib-1.3.2-h8088a28_3.conda",
      "sha256": "a18fa5d5bac452401459f966cf0d872224e8080c4ff93c77e168d43ab42ef9d7",
      "size": 47822
    }
  ],
  "units": [
    {
      "id": "load_native@0.1.0#mojo1.0.0/lib",
      "package": "load_native",
      "version": "0.1.0",
      "kind": "lib",
      "root": "examples/mojo/load_native/src/load_native",
      "srcs": [
        {"path": "examples/mojo/load_native/src/load_native/__init__.mojo", "sha256": "15d06fc92dfbf1d7ec6fe9ab0b3b38e7b4c251d18f78848de67f680c726fbe68"}
      ],
      "deps": [],
      "natives": [],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["load_native.mojoc"],
      "key": "388ad0a73a39af77d1ce5f5d02486b635166fe70bfc2d2b7fb7f72a466da467b"
    },
    {
      "id": "load_native@0.1.0#mojo1.0.0/test:examples/mojo/load_native/tests/test_load_brotli.mojo",
      "package": "load_native",
      "version": "0.1.0",
      "kind": "test",
      "srcs": [
        {"path": "examples/mojo/load_native/tests/test_load_brotli.mojo", "sha256": "031993fab54d545f4953134e48aae4f0d94ec0886b0d64d3b6fd1926e4bd21e0"}
      ],
      "deps": ["load_native@0.1.0#mojo1.0.0/lib"],
      "natives": [],
      "loads": ["libbrotlicommon", "libbrotlidec"],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["test_load_brotli.pass"],
      "key": "9edbacc79aaa978f68e7b2e14a387cdd292b08baf6246713a8d547792e398012"
    },
    {
      "id": "load_native@0.1.0#mojo1.0.0/test:examples/mojo/load_native/tests/test_load_sqlite.mojo",
      "package": "load_native",
      "version": "0.1.0",
      "kind": "test",
      "srcs": [
        {"path": "examples/mojo/load_native/tests/test_load_sqlite.mojo", "sha256": "bd6ca1ef36ad947669cb84ced2edb168ebad277cb109b65c29177d662f399308"}
      ],
      "deps": ["load_native@0.1.0#mojo1.0.0/lib"],
      "natives": [],
      "loads": ["libsqlite", "libzlib"],
      "profile": {"opt": 1, "assert": "all", "debug": false},
      "outputs": ["test_load_sqlite.pass"],
      "key": "41ee5936163fbcc3d7470dc331236f656203d489dad0f6f599ed8d5ca4c19244"
    }
  ]
}
'''
GRAPHS = {
    "linux-64": GRAPH,
    "osx-arm64": json.decode(GRAPH_JSON_OSX_ARM64),
}
