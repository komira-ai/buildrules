# examples/mojo/versions: one package, several Mojo versions

`app` imports its sibling `util`; `reg` imports the registry package `example/nsshim` (the one examples/mojo/nsreg imports). Both `mopm.toml` files list `mojo = ["1.0.0", "1.1.0", "1.2.0"]`; `examples/mojo/mopm-toolchain.toml` names the default, 1.0.0.
Their tables (`buildrules.mojo.lock.bzl`) hold one unit graph per version, in the form `buildrules mojo sync` writes for such a manifest
(docs/contract.md, section 12.3, "One graph per Mojo version"): `GRAPH` for 1.0.0, a `GRAPH_JSON_MOJO_<v>` block for each other version, and `MOJOS` naming the three.

This is fixture data. No released mopm pins a toolchain for Mojo 1.1.0 or 1.2.0, so no sync can make these tables:

- `GRAPH` (1.0.0) and `mopm.lock` are what the pinned mopm 0.0.48 printed and wrote for `mojo = ["1.0.0"]`.
- The 1.1.0 and 1.2.0 blocks are that graph with, written by hand, the version in every unit id and in `mojo`, the `mojo-compiler` package of that version
  (the channel's own url, sha256 and size for linux-64), a closure hash of the fixture's (the sha256 of a sentence that says so) and the unit keys changed.
- In `reg`'s blocks the registry package is another `.conda` for each version (its url, sha256, size and native-library sha256, written by hand: no such file
  exists), and for 1.2.0 another version of it (0.2.0), as mopm may resolve one per Mojo. Those two pins are never downloaded (ci/all.bzl, EXCLUDED).
- `MANIFEST_SHA256` records the `mopm.toml` that lists the three versions.
- The two toolchains are `toolchains/mojo_fixture_pins.bzl`, beside the synced `toolchains/mojo_pins.bzl`.

What is built: //ci:all builds both packages at 1.0.0, from mopm's graph, as any example. The other versions are analysed and not built: ci/mojo_versions.bzl
(part of `buck2 bxl //ci:completeness.bxl:check`) configures `app` for each version (with `--target-platforms buildrules//platforms:linux_x86_64_mojo_<v>` and
with `mojo_at`, the targets of BUCK here) and requires its toolchain, its file names, its output directory and the version of `util` it imports to be that
version's, and `reg`'s registry package to be unpacked from that version's `.conda`. `:table` of each package is excluded (ci/all.bzl): it would ask mopm for the 1.1.0 and 1.2.0 graphs.

The BUCK files call `mojo_package` by another name, so `buildrules mojo sync` and `buildrules mojo check` at the repository root, which find packages by that call, do
not try to plan the fixture. When a mopm that pins 1.1.0 and 1.2.0 is pinned here, the fixture can be synced for real: call `mojo_package`, add `mojo_sync`
targets and remove `toolchains/mojo_fixture_pins.bzl` and the exclusions.
