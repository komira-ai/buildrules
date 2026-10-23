# examples/mojo

    ws/                    app -> util -> base: three workspace members, each a package of its own (mopm.toml, mopm.lock, BUCK)
      util/base/           the leaf; util/ imports it; ws/ (app) imports util and the registry package cnative
    registry/cnative/      the publisher's side of cnative: a Mojo package over a C library
    registry/probe_sys/    the publisher's side of probe_sys: a `-sys` package (an empty Mojo module over a static C library) that needs base_sys's
      base_sys/            the other `-sys` package, a workspace member of probe_sys
    sys_app/               imports probe_sys from the registry stand-in: both static archives come out of the `.conda` files, with no `natives` in its BUCK file
    sibfake/base, app/     `app` imports `../base`, a sibling rather than a directory below it. Their tables are written by hand with `"workspace_root": True` (the record of a mopm that
                           takes --workspace-root, 0.0.26 and later) and hold the member by identity only; the pinned mopm rejects the flag, so `:table` is not built for them
    sibfake/stale/         PLANTED DEFECT: `app` synced when `base` was 0.2.0; its library is built from 0.1.0, so analysis of `:lib_ungated` must stay red (ci/negative.bzl, CASES)
    copy_of_base/          base's sources at another path; `:same_bytes` fails unless the two `.mojoc` files are equal
    reexport/              a package whose `__init__.mojo` only re-exports (a docstring and `from .ops import ...`): the Mojo coverage report omits it and `:coverage` lists it `0/0`
    partial/               a package whose test runs one arm of a function (60.00% of its lines), with a `coverage_floor.txt` of exactly that: its `:coverage_floor` is green
    coverage_floors/       the same `:coverage` held to a floor above it and to one below it: each fails, saying "coverage fell" or "raise the floor to 60.00" (ci/negative.bzl, COVERAGE_REDS)
    coverage_records_test.zig  `:coverage` and `:coverage[reports]` of `reexport` and `partial` held to each other, file by file (`:coverage_records`)
    reexport_unused/       PLANTED DEFECT: the same plus a function nothing calls; `:coverage` must stay red with "is in no report" (ci/negative.bzl, COVERAGE_REDS)
    mopm-toolchain.toml    the versions every package here is built with (found by walking up)

    buildrules mojo sync               # after a change to a mopm.toml, mopm.lock, mopm-toolchain.toml or any source
    buck2 build //examples/mojo/ws:ci //examples/mojo/ws:coverage
    buildrules mojo check              # offline

`mopm.lock` files are written by hand here: `mopm lock` needs a registry even for path dependencies, and the lock of `ws/` names a registry package.
`ws/mopm.lock` records the `cnative` package as it would come from a registry: the URL, sha256 and size of the `.conda` that
`buck2 build //examples/mojo/registry/cnative:conda` makes with `mopm pack`, and the sha256 of `libcnative.so.1` (`:libcnative`, built by rules/cxx).
When `cnative`'s sources change, rebuild both, put the new sha256 and size in `ws/mopm.lock` and run `buildrules mojo sync`.

`sys_app/mopm.lock` records `base_sys` and `probe_sys` the same way, and also what `mopm lock` writes for a package with a static native library: the sha256 of the archive
(`lib/libbase_sys.a` and `lib/libprobe_sys.a` of the `.conda`, which are the `cxx_library` archives `:base_c[static-pic]` and `:probe_c[static-pic]`), its `kind`, and probe_sys's `needs`.
Build the two `:conda` targets (`registry/probe_sys:conda`, `registry/probe_sys/base_sys:conda`) and the two archives, put the four sha256 and the two sizes in the lock, and run `buildrules mojo sync`:
a lock that disagrees with a `.conda` fails the download's check, and one that disagrees with an archive fails `prebuilt_unpack` (a hash that differs) before anything is linked.

The URL in the lock is a placeholder channel; a machine that has the file points the download at it in the `.buckconfig.local` of the cell that declares it, for example
`[buildrules] url_map = https://conda.mopm.dev/=http://mirror.invalid/channel/` in the root `.buckconfig.local` (the sha256 is still checked). The mopm tarball
(`rules/mopm/pins.bzl`, the published mopm 0.0.25) is a download of the `toolchains` cell from its release URL and needs no mirror.
