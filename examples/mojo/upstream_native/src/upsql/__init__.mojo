"""upsql: Mojo over SQLite, which the package builds itself from a pinned upstream archive (its `[native.sqlite]`, native/upsql_sqlite3.c) with every symbol renamed
to start with `upsql_sqlite3_`, so the copy bundled here cannot clash with a system libsqlite3 in the same process."""

from std.ffi import external_call


def version_number() -> Int:
    """`sqlite3_libversion_number()`: 3053004 for 3.53.4."""
    return Int(external_call["upsql_sqlite3_libversion_number", Int32]())


def threadsafe() -> Int:
    """`sqlite3_threadsafe()`: the compile-time threading mode (1: serialized), set by the manifest's `-DSQLITE_THREADSAFE=1`."""
    return Int(external_call["upsql_sqlite3_threadsafe", Int32]())


def initialize() -> Int:
    """`sqlite3_initialize()`: 0 (SQLITE_OK) once the library is ready."""
    return Int(external_call["upsql_sqlite3_initialize", Int32]())
