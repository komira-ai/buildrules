# examples/mojo

    ws/                    app -> util -> base: three workspace members, each a package of its own (mopm.toml, mopm.lock, BUCK)
      util/base/           the leaf; util/ imports it; ws/ (app) imports util and the registry package cnative
    registry/cnative/      the publisher's side of cnative: a Mojo package over a C library
    copy_of_base/          base's sources at another path; `:same_bytes` fails unless the two `.mojoc` files are equal
    mopm-toolchain.toml    the versions every package here is built with (found by walking up)

    buildrules mojo sync               # after a change to a mopm.toml, mopm.lock, mopm-toolchain.toml or any source
    buck2 build //examples/mojo/ws:ci //examples/mojo/ws:coverage
    buildrules mojo check              # offline

`mopm.lock` files are written by hand here: `mopm lock` needs a registry even for path dependencies, and the lock of `ws/` names a registry package.
`ws/mopm.lock` records the `cnative` package as it would come from a registry: the URL, sha256 and size of the `.conda` that
`buck2 build //examples/mojo/registry/cnative:conda` makes with `mopm pack`, and the sha256 of `libcnative.so.1` (`:libcnative`, built by rules/cxx).
When `cnative`'s sources change, rebuild both, put the new sha256 and size in `ws/mopm.lock` and run `buildrules mojo sync`.

The URL in the lock is a placeholder channel; a machine that has the file points the download at it in the `.buckconfig.local` of the cell that declares it, for example
`[buildrules] url_map = https://conda.mopm.dev/=http://mirror.invalid/channel/` in the root `.buckconfig.local` (the sha256 is still checked). The mopm tarball
(`rules/mopm/pins.bzl`, the published mopm 0.0.20) is a download of the `toolchains` cell from its release URL and needs no mirror.
