# examples/mojo

    ws/                    app -> util -> base: three workspace members, each a package of its own (mopm.toml, mopm.lock, BUCK)
      util/base/           the leaf; util/ imports it; ws/ (app) imports util and the registry package cnative
    registry/cnative/      the publisher's side of cnative: a Mojo package over a C library
    registry/probe_sys/    the publisher's side of probe_sys: a `-sys` package (an empty Mojo module over a static C library) that needs base_sys's
      base_sys/            the other `-sys` package, a workspace member of probe_sys
    sys_app/               imports probe_sys from the registry stand-in: both static archives come out of the `.conda` files, with no `natives` in its BUCK file; its test takes both arms of a decision in the library, so the package has branch records of its own through the native link and a `coverage_floor.txt` of `lines 100.00` and `branches 100.00`
    sibfake/chain/         a -> b -> c: every dependency is a sibling directory (`{ path = "../b" }`), not a directory below its user. `a` names only `b`; its `mopm.lock` records `c` too, and its table holds `b` and `c` by identity
    sibfake/diamond/       top -> (left, right) -> bottom: `bottom` is one unit of `top`'s graph with two dependents
                           Every package of both has a `:conda` (`mojo_package(conda = True)`: `mopm pack` with the sibling manifests staged at their repository paths) and a `:conda_holds`, which requires the `.conda` to hold the package alone and to record each sibling as a versioned dependency (`{ path = "../b", version = "0.1" }` in the manifest)
                           Each table is mopm's own output for `plan --unit-graph --locked --workspace-root <the repository root>` (`"workspace_root": True`; the paths of the graph start at the repository root, and a
                           test unit's id names its file from there), held to it by `:table`, which is in //ci:mojo_tables. The path dependencies are held by identity only; a leaf's table also holds the `key` of its units
    sibfake/stale/         RED BY DESIGN: `chain_stale` synced when `chain/c` was 0.2.0; its library is built from 0.1.0, so analysis of `:lib_ungated` must stay red (ci/negative.bzl, CASES)
    copy_of_base/          base's sources at another path; `:same_bytes` fails unless the two `.mojoc` files are equal
    member_native/         cshim_user -> cshim: two members; cshim has a C shim of its own (`[native.shim]`), built by `mojo_package` (`:native_shim`), linked into both members' tests and packed into `cshim:conda`
    copy_of_cshim/         cshim's C at another path; `:same_bytes` fails unless the two archives are equal
    installed/             a package whose tests run in the installed layout (`test_layout = "installed"`; docs/contract.md, section 12.9): each test from a fresh root, its binary at `<root>/bin/<exe>`, its data under `<root>/share`, `<root>` as the working directory, and a private `TMPDIR`, `TEST_TMPDIR` and `HOME`; the library finds its own files from `/proc/self/exe`; in `:ci` and `:coverage`, with a `coverage_floor.txt` of `lines` alone (no branch run in the installed layout)
    reexport/              a package whose `__init__.mojo` only re-exports (a docstring and `from .ops import ...`): the Mojo coverage report omits it and `:coverage` lists it `0/0`, and so it does `aliases.mojo`, a file of `comptime` aliases only; `ops.mojo` has two decisions (an `if` and a `for`, 4 of 4 branch arms), so its `coverage_floor.txt` has a `branches` figure
    branch_shapes/         three valid constructs the branch classifier once refused (a Bool converted to an Int, a per-lane `if` in an unrolled `comptime for` in two widths, an `and` of target queries), one test each; every line and branch arm is covered, so its `coverage_floor.txt` is `lines 100.00` and `branches 100.00` (rules/coverage/branch/README.md, "Bool to Int", "Unrolled loops", "Folded conditions")
    partial/               a package whose test runs one arm of a function (60.00% of its lines, one of the two arms of its `if`: 50.00% of its branches), with a `coverage_floor.txt` of exactly that: its `:coverage_floor` is green
    testdata/              a package whose tests read files and variables the build gives them (`test_data`, `test_env`; docs/contract.md, section 12.9): a golden file, a third-party `.thrift`, a library source, and a program another target built, staged with its executable bit; in `:ci` and `:coverage`, and its branch run is given the same files and variables. No decision in its code, so no branches figure: its `coverage_floor.txt` is `lines 100.00` alone
    coverage_floors/       the same `:coverage` held to a line floor and a branch floor above it (each fails, "coverage fell"), to a floor with no `branches` figure, and `testdata`'s to a floor with a `branches` line it has nothing to hold (each fails, saying why; ci/negative.bzl, COVERAGE_REDS), and to a line floor and a branch floor below it (each passes, with a hint that the floor may be raised; built by //ci:mojo). That every example is instrumented for branches (`ws` and `sys_app` link native libraries, which the instrumented link is given) is held there too (`BRANCH_PACKAGES`)
    coverage_records_test.zig  `:coverage`, `:coverage[reports]` and `:coverage[branches]` of `reexport` and `partial` held to each other, file by file, and the branch records and rows of `testdata`, `sys_app` and `ws` (`:coverage_records`)
    reexport_unused/       PLANTED DEFECT: the same plus a function nothing calls; `:coverage` must stay red with "is in no report" (ci/negative.bzl, COVERAGE_REDS)
    mopm-toolchain.toml    the versions every package here is built with (found by walking up)

    buildrules mojo sync               # after a change to a mopm.toml, mopm.lock, mopm-toolchain.toml or any source
    buck2 build //examples/mojo/ws:ci //examples/mojo/ws:coverage
    buildrules mojo check              # offline

`member_native/` and `member_native/cshim/` hold graphs (`buildrules.mojo.lock.bzl`) in the shape of unit graph format 2 (a `native:<package>/<id>` unit and `built` entries,
spec/unit-graph.md of mopm), which the pinned mopm prints (`:table` holds each to its output). Their tests, coverage and `cshim:conda_holds` are built by `//ci:mojo`.

`mopm.lock` files are written by hand here: `mopm lock` needs a registry even for path dependencies, and the lock of `ws/` names a registry package.
`ws/mopm.lock` records the `cnative` package as it would come from a registry: the URL, sha256 and size of the `.conda` that
`buck2 build //examples/mojo/registry/cnative:conda` makes with `mopm pack`, and the sha256 of `libcnative.so.1` (`:libcnative`, built by rules/cxx).
When `cnative`'s sources change, rebuild both, put the new sha256 and size in `ws/mopm.lock` and run `buildrules mojo sync`.

`sys_app/mopm.lock` records `base_sys` and `probe_sys` the same way, and also what `mopm lock` writes for a package with a static native library: the sha256 of the archive
(`lib/libbase_sys.a` and `lib/libprobe_sys.a` of the `.conda`, which are the archives `:native_base_sys` and `:native_probe_sys` that `mojo_package` builds from each package's `[native.<id>]`), its `kind`, and probe_sys's `needs`.
Build the two `:conda` targets (`registry/probe_sys:conda`, `registry/probe_sys/base_sys:conda`) and the two archives, put the four sha256 and the two sizes in the lock, and run `buildrules mojo sync`:
a lock that disagrees with a `.conda` fails the download's check, and one that disagrees with an archive fails `prebuilt_unpack` (a hash that differs) before anything is linked.

The URL in the lock is a placeholder channel; a machine that has the file points the download at it in the `.buckconfig.local` of the cell that declares it, for example
`[buildrules] url_map = https://conda.mopm.dev/=http://mirror.invalid/channel/` in the root `.buckconfig.local` (the sha256 is still checked). The mopm tarball
(`rules/mopm/pins.bzl`, the published mopm 0.0.42) is a download of the `toolchains` cell from its release URL and needs no mirror.
