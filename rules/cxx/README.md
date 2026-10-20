# rules/cxx: hermetic C/C++ on the pinned zig

No host compiler, no PATH in actions. `toolchains/BUCK` calls `cxx_toolchains()` ([toolchain.bzl](toolchain.bzl)),
which declares `toolchains//:cxx` for the prelude's `cxx_library` / `cxx_binary`:

- compiler, assembler, archiver: `zig cc | c++ | ar | ranlib` of the pinned zig 0.12.0 (`rules/pins`), through
  `zig_cc_launcher` (expands the nested response files the prelude passes, fixes zig's cache directories);
- target `x86_64-linux-gnu.2.34` (the glibc floor of the Rust rules), CPU baseline `x86_64`, `-fPIC`, `-g0`
  (debug info would record the working directory);
- `nm`, `objcopy`, `strip` and every Python tool of the prelude are refusals that name the tool (exit 2), never a
  search of the worker. Dependency files, header maps and thin LTO are off for the same reason.

| rule (defs.bzl, archive.bzl) | what |
|---|---|
| `archive_files` | named files out of a sha256-pinned source archive (one tree, `[include]` sub-targets) |
| `staged_files` | sources copied under buck-out, so action digests do not depend on where the cell is mounted |
| `c_exe` | one C file to a static musl executable (builds `elfsyms`) |
| `prefix_header`, `prefixed_archive_check`, `checked_cxx_library` | rename every global symbol of a vendored library under a prefix and prove it (see below) |
| `c_check` | run a built executable on the execution platform; validation: exit 0 and exact stdout |
| `glibc_floor_check` | validation: the ELF needs no glibc symbol version newer than `max` |

Symbol prefixing: `<lib>_unprefixed` is built with upstream names; `prefix_tool header` reads its archive's symbol
table (`elfsyms`) and writes the renaming header; `<lib>_prefixed` force-includes it; `prefix_tool check` reads the
prefixed archive back and fails unless every defined symbol carries the prefix. All checks are `ValidationInfo`,
which Buck2 runs in every build whose graph holds the library.

Example: `third_party/aws-lc` (aws-lc 1.39.0, libcrypto only, linux x86_64): `crypto[static-pic]`, prefix
`buildrules_awslc_`, gated by `crypto_symbols`, `selfcheck_runs` (known-answer tests through the public API) and
`selfcheck_floor`.

Planted defects (each goes red; logs under the scratch directory, see docs/cxx_mutants.md):
wrong tarball sha256, a wrong `__umodti3`, a dropped `allow`, a missing renaming header, a wrong `expected_stdout`,
a floor lower than the binary needs. The tools' own unit tests (`prefix_tool_unit`, `glibc_floor_unit`) carry their
planted-defect cases and are welded to the tools.
