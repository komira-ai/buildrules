"""Checks of rules/mojo/native_build.bzl that are not a refusal: what it reads out of a value. Each takes `refuse` and calls it for every difference."""

load("//rules/mojo:native_build.bzl", "archive_extension")

def archive_extensions_are_read_from_the_file_name(refuse = fail):
    cases = {
        "https://h/a/b-1.0.tar.gz": ".tar.gz",
        "https://h/a/b-1.0.tgz": ".tgz",
        "https://h/a/b-1.0.tar.xz": ".tar.xz",
        "https://h/a/b-1.0.tar": ".tar",
        "https://h/a/b-1.0.zip": ".zip",
        # Query and fragment are not part of the file name.
        "https://h/a/b-1.0.tar.gz?download=1": ".tar.gz",
        "https://h/a/b-1.0.zip#frag": ".zip",
        # A directory called like an archive does not make the file one.
        "https://h/a.tar.gz/b.c": None,
        "https://h/b.tar.gz.sig": None,
        "https://h/b.tar.bz2": None,
        "https://h/.zip": None,
    }
    for url, want in cases.items():
        got = archive_extension(url)
        if got != want:
            refuse("archive_extension({}) is {}, want {}".format(repr(url), repr(got), repr(want)))

def up_with(base, **kw):
    """`base` (a dict) with the keys of `kw` set: a spelling of the table that differs from a good one in one key."""
    d = dict(base)
    d.update(kw)
    return d
