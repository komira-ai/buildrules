"""The end of a program's link line (rules/mojo/unit.bzl): the archives beyond the ones its unit graph lists, then the system libraries its graph names.

mopm's unit graph lists the native libraries a unit links, one soname each, in link order. A `native_library` that has `deps` needs the archives of those too, and the graph
does not list them: they come from `NativeLibraryInfo.archives` of each listed library. They end the link line, after every archive of the graph and before the C++ runtime
(`-lc++`), in an order a ONE-PASS linker accepts (lld and ld64 do not need it, a GNU ld does): a library before every library it needs, each archive once, a shared one after its last
user. An archive the graph lists is linked where the graph puts it. It is written again in the tail when an extra archive comes before it in some library's list: the graph's copy was
linked first and a one-pass linker would pass over it for what that extra archive needs. That is a test of order and not of need, so an archive may be repeated that the extra archive does not use; it is never left out when it is used.

An archive is told from another by its identity (`key`: its path, or its label), never by its file name: two packages may each have a `libx.a`.

The system libraries come from mopm's unit graph and from nowhere else: a unit that links archives has `link` (format 5), the `link` of its natives (`[native.<id>] link = ["c++"]` in
mopm.toml, carried by the metadata of a published package and by the lock), each name once, in mopm's order. They end the line as `-l<name>`, after every archive, the extra ones
too. What an archive needs is stated by its member and held against the sources: a `native_library` with a C++ source, in a link whose `link` lacks `c++`, is refused (`check_cxx_link`).
"""

# The names mopm lets a native put in `link`: a closed list, because they come from published packages and reach linker command lines (mopm's spec/unit-graph.md).
LINK_NAMES = ["c++", "dl", "m", "pthread"]

def check_link_names(who, link, refuse = fail):
    """`link`, the system libraries a unit's final link adds, is a list of names of `LINK_NAMES`, none twice. `refuse` is `fail` in a build; a test passes a recorder (rules/rust/refusal.bzl)."""
    if type(link) != "list":
        refuse("{}: link is {}, a list of the names {}".format(who, repr(link), ", ".join(LINK_NAMES)))
        return
    seen = {}
    for n in link:
        if type(n) != "string" or n not in LINK_NAMES:
            refuse("{}: link names {}, which is not one of {}".format(who, repr(n), ", ".join(LINK_NAMES)))
            return
        if n in seen:
            refuse("{}: link names {} twice".format(who, n))
            return
        seen[n] = True

def check_cxx_link(who, cxx, link, refuse = fail):
    """A link that holds an archive with C++ sources (`cxx`: some library of it, or one it depends on, says so) names `c++` in `link`, mopm's list of the system libraries the final
    link adds: the field is the one source of them, so an archive that needs libc++ and a graph that does not say so would link without it (or, before this check, with a runtime
    nothing declared)."""
    if cxx and "c++" not in link:
        refuse(("{}: links a native library with C++ sources, and the link of the unit is {}: `c++` must be in it. Declare `link = [\"c++\"]` on the `[native.<id>]` of the member that ships the " +
                "library in mopm.toml (a library a registry package ships says it in its own manifest), then run `mopm lock` and `buildrules mojo sync`").format(who, repr(list(link))))

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

def link_cfg(archive_names, link):
    """The lines of toolchain.cfg that end the link line: one `link_archive=` for each extra archive (a file of `LINK_ARCHIVE_DIR` of the toolchain directory), in order, then one
    `link_tail=-l<name>` for each name of the unit's `link` (mopm's list, in its order). A unit with no `link` gets none, so a link of C libraries alone has no runtime and no archive it
    does not need, and its configuration is what it was before `link` existed."""
    text = "".join(["link_archive={}/{}\n".format(LINK_ARCHIVE_DIR, n) for n in archive_names])
    for name in link:
        text += "link_tail=-l{}\n".format(name)
    return text
