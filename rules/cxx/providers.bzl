"""Providers of the C/C++ rules. Plain data only (facebook/buck2#683: a tset's type is per loading cell)."""

# A native static library (`native_archive`, native.bzl).
NativeArchiveInfo = provider(fields = {
    # The file name the library is linked by, `lib<id>.a`.
    "soname": provider_field(str),
    # The `.a` file, under that name.
    "archive": provider_field(typing.Any),
    # The sorted defined global symbols of the archive, one per line.
    "symbols": provider_field(typing.Any),
    # The library has C++ sources: a program that links it also links the C++ runtime, once (rules/mojo/unit.bzl).
    "cxx": provider_field(bool, default = False),
})

# A native library built by `native_library` (rules/native/library.bzl). Plain data only: lists of artifacts and strings, no tset.
NativeLibraryInfo = provider(fields = {
    # `lib<id>.a`: the file name the library is linked by, and its file.
    "soname": provider_field(str),
    "archive": provider_field(typing.Any),
    # The archives of the link line, this library's first and then, in the order a linker needs them (a library before the libraries it calls into), the
    # archives of its `deps`, each once. A program that links the library links all of them.
    "archives": provider_field(list[typing.Any]),
    # The directories a dependent compiles with `-I`: this library's `exported_includes` (directories of its upstream tree) and those of its `exported_deps`.
    "include_dirs": provider_field(list[typing.Any]),
    # Some library of the link (this one, or one of its `deps`) has C++ sources: a program that links it also links the C++ runtime, once.
    "cxx_runtime": provider_field(bool),
})
