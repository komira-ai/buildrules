"""The archives a program links beyond the ones its unit graph lists (rules/mojo/unit.bzl).

mopm's unit graph lists the native libraries a unit links, one soname each, in link order. A `native_library` that has `deps` needs the archives of those too, and the graph
does not list them: they come from `NativeLibraryInfo.archives` of each listed library. They end the link line, after every archive of the graph and before the C++ runtime
(`-lc++`), in an order a ONE-PASS linker accepts (lld and ld64 do not need it, a GNU ld does): a library before every library it needs, each archive once, a shared one after its last
user. An archive the graph lists is linked where the graph puts it. It is written again in the tail when an extra archive comes before it in some library's list: the graph's copy was
linked first and a one-pass linker would pass over it for what that extra archive needs. That is a test of order and not of need, so an archive may be repeated that the extra archive does not use; it is never left out when it is used.

An archive is told from another by its identity (`key`: its path, or its label), never by its file name: two packages may each have a `libx.a`.
"""

def extra_link_archives(archive_lists, linked, key):
    """The archives to append to the link line. `archive_lists` is the `archives` of each library the graph lists, in the graph's order; `linked` the keys of the archives the
    graph links itself; `key` maps an archive to its identity.

    Each archive appears once, at its LAST place in the concatenation of the lists, so an archive two libraries share comes after both. One the graph links is left out, unless
    an archive that is not the graph's comes before it in some list (it may need it, and the graph's copy is behind it): then it is written again after that archive. This may repeat an archive the extra one does not use; it never leaves out one it does."""
    flat = []
    needed = {}
    for archives in archive_lists:
        flat.extend(archives)
        seen_extra = False
        for a in archives:
            if key(a) in linked:
                if seen_extra:
                    needed[key(a)] = True
            else:
                seen_extra = True
    last = {}
    for i, a in enumerate(flat):
        last[key(a)] = i
    return [a for i, a in enumerate(flat) if last[key(a)] == i and (key(a) not in linked or key(a) in needed)]

# Where, in the toolchain directory of a unit's action, the extra archives are (mojo_launch.zig, `link_archive`).
LINK_ARCHIVE_DIR = "link_archives"

def link_archive_name(position, basename):
    """The name of the `position`th extra archive in the toolchain directory: its place in the line and its own name, so two archives of one name are two files."""
    return "{}_{}".format(("000" + str(position))[-3:], basename)

def link_cfg(archive_names, cxx_runtime):
    """The lines of toolchain.cfg that end the link line: one `link_archive=` for each extra archive (a file of `LINK_ARCHIVE_DIR` of the toolchain directory), in order, and
    `link_tail=-lc++` once when some library of the link has C++ sources. A link of C libraries alone gets neither a runtime nor an archive it does not need."""
    text = "".join(["link_archive={}/{}\n".format(LINK_ARCHIVE_DIR, n) for n in archive_names])
    if cxx_runtime:
        text += "link_tail=-lc++\n"
    return text
