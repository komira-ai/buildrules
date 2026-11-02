"""Providers of the Mojo rules. Lists and dicts only, never a tset (facebook/buck2#683: a tset's type is per loading cell)."""

# One pinned Mojo toolchain, as `toolchains//:mojo_<v>` declares it from toolchains/mojo_pins.bzl (which `buildrules mojo sync`
# copies from mopm's unit graphs).
MojoToolchainInfo = provider(fields = {
    # The compiler version, `1.0.0`.
    "version": provider_field(str),
    # mopm's hash of the whole closure (the compiler packages and the zig), the value of the graph's
    # `toolchain.closure_sha256`. The unit action writes it into the toolchain directory's CLOSURE_SHA256 and
    # `mopm unit build` refuses unless the graph names the same.
    "closure_sha256": provider_field(str),
    # Every closure hash the packages that share this toolchain pin, sorted (`closure_sha256` is the first): two releases of mopm that pin the same compiler, runtime packages and zig
    # may hash their solve of the environment differently, and the toolchain is the same files for both. A unit's action is given the closure of its own graph, which must be one of these.
    "closures": provider_field(list),
    "cc_target": provider_field(str),
    # The toolchain row of toolchains/mojo_pins.bzl this toolchain was declared from, whole (mopm's `toolchain` section of the graph, verbatim): the
    # `:check` of a package compares it with the table's own graph, so a pins file edited without a sync is red.
    "facts": provider_field(dict),
    # Directory: bin/mojo, lib/, share/max/modular.cfg and CLOSURE_MANIFEST (conda_unpack).
    "compiler": provider_field(typing.Any),
    # Directory: the unpacked zig distribution, which serves as `cc` and the linker.
    "zig": provider_field(typing.Any),
})

# A built library unit (or an unpacked registry package).
MojoLibInfo = provider(fields = {
    "id": provider_field(str),
    # The `<package>.mojoc` file.
    "mojoc": provider_field(typing.Any),
    # package name -> its `.mojoc`, this unit and everything it imports (a unit's `--deps` directory holds these, flat).
    "closure": provider_field(dict),
    # package name -> the id of its unit (`<name>@<version>#mojo<mojo version>/lib`), the same keys: what each `.mojoc` of the closure was built as.
    # A unit that imports it checks these against its own graph (rules/mojo/unit.bzl, `check_closure_ids`).
    "ids": provider_field(dict),
})

# The files `mopm plan` reads for a package and for the path dependencies it imports, at their repository paths (rules/mojo/check.bzl).
MojoWorkspaceInfo = provider(fields = {
    # repository path -> file: this package's files and everything its path dependencies' workspaces hold.
    "files": provider_field(dict),
})

# The native libraries a library unit links, which an adopted label hands to a dependent that still links through other rules: the unit's `natives` in the
# graph's order (a library before every library it needs), and the file of each by soname. A static library a member builds (`native:<package>/<id>`), one a
# registry package ships and a shared library the BUCK file names are all here; `sonames` is the order of the link line.
MojoNativeArchiveInfo = provider(fields = {
    "sonames": provider_field(list),
    "archives": provider_field(dict),
})

# The directories of the shared libraries a package pins for its tests to load (its unit graph's `system_libs`, `mojo_system_lib`, rules/mojo/system_libs.bzl), which an adopted
# label hands to a dependent that still runs its tests through other rules: that dependent's test opens the same libraries by their bare names. One directory per pinned
# package, in the graph's order (by name); each holds the package's shared libraries flat. A package that pins none has an empty list. Directories only, never a tset
# (facebook/buck2#683).
MojoSystemLibsInfo = provider(fields = {
    "dirs": provider_field(list),
})

# A compiled test or binary: the unit's output directory (the executable and lib/ with its native libraries).
MojoExeInfo = provider(fields = {
    "id": provider_field(str),
    "dir": provider_field(typing.Any),
    # The executable inside `dir`, and its file name.
    "exe": provider_field(typing.Any),
    "name": provider_field(str),
})

# What a test run needs to be a `buck2 test` target as well as a build action.
MojoTestRunInfo = provider(fields = {
    "marker": provider_field(typing.Any),
})
