"""Providers of the C/C++ rules. Plain data only (facebook/buck2#683: a tset's type is per loading cell)."""

# A native static library (`native_archive`, native.bzl).
NativeArchiveInfo = provider(fields = {
    # The file name the library is linked by, `lib<id>.a`.
    "soname": provider_field(str),
    # The `.a` file, under that name.
    "archive": provider_field(typing.Any),
    # The sorted defined global symbols of the archive, one per line.
    "symbols": provider_field(typing.Any),
})
