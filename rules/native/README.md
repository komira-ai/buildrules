# rules/native: `native_library`

A C, C++ and assembly static library built by the pinned zig for the target platform, from the package's files and a sha256-pinned upstream tarball. The contract is
section 12.12 of [docs/contract.md](../../docs/contract.md); the arguments are in [defs.bzl](defs.bzl).

| file | what |
|---|---|
| `defs.bzl` | the macro `native_library`: stages the tarball (`pinned_file`, `archive_files`), a `cxx_library` of the sources, the `native_archive` behind `archive_check`, and the rule below |
| `library.bzl` | the rule that adds `NativeLibraryInfo` (`rules/cxx/providers.bzl`) to the checked archive |
| `checks.bzl` | the refusals made while the graph is analysed, and the link order, as functions of plain values |
| `link.bzl` | the archives a program links beyond the unit graph's (a library's deps, each once, a shared one after its last user) and the toolchain.cfg lines for them and for the C++ runtime |
| `tests/` | the analysis tests of those refusals |

Examples: `examples/native` (zlib, C++, assembly by CPU, dependencies), `examples/mojo/native_library` (a Mojo package that links them through `natives`).
Held by CI: `ci/native_library.bzl` (what each platform's `select()` chose, flags, provider data), `ci/faulty` (a dependent that includes a header its dependency does
not export fails to compile).
