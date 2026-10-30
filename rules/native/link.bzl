"""The archives a program links beyond the ones its unit graph lists (rules/mojo/unit.bzl).

mopm's unit graph lists the native libraries a unit links, one soname each, in link order. A `native_library` that has `deps` needs the archives of those too, and
the graph does not list them: they come from `NativeLibraryInfo.archives` of each listed library. They end the link line, after every archive of the graph and before
the C++ runtime (`-lc++`), in the order a linker needs them: a library before the libraries it calls into, each archive once, a shared one after its last user.
"""

def extra_link_archives(archive_lists, linked, name):
    """The archives to append to the link line. `archive_lists` is the `archives` of each library the graph lists, in the graph's order; `linked` the file names the graph
    links itself (they are not appended again); `name` maps an archive to its file name. Each archive appears once, at its LAST place in the concatenation, so an archive
    two libraries share comes after both."""
    flat = []
    for archives in archive_lists:
        flat.extend(archives)
    last = {}
    for i, a in enumerate(flat):
        last[name(a)] = i
    return [a for i, a in enumerate(flat) if last[name(a)] == i and name(a) not in linked]

# Where, in the toolchain directory of a unit's action, the extra archives are (mojo_launch.zig, `link_archive`).
LINK_ARCHIVE_DIR = "link_archives"

def link_cfg(archive_names, cxx_runtime):
    """The lines of toolchain.cfg that end the link line: one `link_archive=` for each extra archive (a file of `LINK_ARCHIVE_DIR` of the toolchain directory), in order, and
    `link_tail=-lc++` once when some library of the link has C++ sources. A link of C libraries alone gets neither a runtime nor an archive it does not need."""
    text = "".join(["link_archive={}/{}\n".format(LINK_ARCHIVE_DIR, n) for n in archive_names])
    if cxx_runtime:
        text += "link_tail=-lc++\n"
    return text
