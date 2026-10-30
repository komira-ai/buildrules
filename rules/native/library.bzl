"""The rule behind `native_library` (defs.bzl): the checked archive of a library, and what a dependent needs of it.

`native_archive` (rules/cxx/native.bzl) writes `lib<id>.a` out of the library's `cxx_library` and holds it to `archive_check`. This rule forwards every
provider of that archive (so a `mojo_package` takes the target wherever it takes a `native_archive`: `NativeArchiveInfo`, the validation, the file) and adds
`NativeLibraryInfo`: the archives of the link line in order, the exported include directories, and whether the C++ runtime is linked.
"""

load("//rules/cxx:providers.bzl", "NativeArchiveInfo", "NativeLibraryInfo")
load(":checks.bzl", "check_cxx_runtime", "link_order")

def _impl(ctx):
    archive = ctx.attrs.archive
    own = archive[NativeArchiveInfo]
    who = str(ctx.label.raw_target())
    check_cxx_runtime(who, ctx.attrs.cxx_runtime, own.cxx)

    deps = [d[NativeLibraryInfo] for d in ctx.attrs.deps + ctx.attrs.exported_deps]
    exported = [d[NativeLibraryInfo] for d in ctx.attrs.exported_deps]

    # Directories of the upstream tree: projections of its one directory artifact.
    include_dirs = []
    if ctx.attrs.include_tree:
        tree = ctx.attrs.include_tree[DefaultInfo].default_outputs[0]
        for d in ctx.attrs.exported_includes:
            include_dirs.append(tree if d == "." else tree.project(d))
    for e in exported:
        for d in e.include_dirs:
            if d not in include_dirs:
                include_dirs.append(d)

    cxx_runtime = own.cxx or any([d.cxx_runtime for d in deps])
    info = NativeLibraryInfo(
        soname = own.soname,
        archive = own.archive,
        archives = link_order(own.archive, [d.archives for d in deps]),
        include_dirs = include_dirs,
        cxx_runtime = cxx_runtime,
    )

    # The forwarded archive provider says the library needs the C++ runtime when a library it links does: a program that links this archive links theirs.
    forwarded = [p for p in archive.providers if not isinstance(p, NativeArchiveInfo)]
    return forwarded + [
        NativeArchiveInfo(soname = own.soname, archive = own.archive, symbols = own.symbols, cxx = cxx_runtime),
        info,
    ]

native_library_rule = rule(
    impl = _impl,
    doc = "The `native_archive` `archive` with `NativeLibraryInfo` added (see native_library in rules/native/defs.bzl).",
    attrs = {
        "archive": attrs.dep(providers = [NativeArchiveInfo]),
        # Libraries this one calls into, and those whose headers it re-exports: both are linked after it; only the second hand their include directories on.
        "deps": attrs.list(attrs.dep(providers = [NativeLibraryInfo]), default = []),
        "exported_deps": attrs.list(attrs.dep(providers = [NativeLibraryInfo]), default = []),
        # The directories (of the one upstream tree) a dependent compiles with -I.
        "exported_includes": attrs.list(attrs.string(), default = []),
        "include_tree": attrs.option(attrs.dep(), default = None),
        # What the target states about its sources (None: not stated); a statement that is not what the sources are is refused.
        "cxx_runtime": attrs.option(attrs.bool(), default = None),
    },
)
