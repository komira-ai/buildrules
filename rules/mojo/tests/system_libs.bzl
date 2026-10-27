"""Checks of the system libraries a graph pins (rules/mojo/system_libs.bzl) that need no action. Each takes `refuse`, as the checks of siblings.bzl do."""

load("//rules/mojo:system_libs.bzl", "check_graph_format", "check_loads", "check_same_system_libs", "compile_format", "system_libs_of")

_SHA = "c294029f893d05286f1061bbab85b820f1eea73dd859af4bcc619197bcc34810"

def _entry(name, **kwargs):
    e = {"name": name, "version": "1.0", "build": "h0_0", "url": "https://example.invalid/" + name + ".conda", "sha256": _SHA, "size": 10}
    e.update(kwargs)
    return e

def graph(fmt = 3, libs = ["libsqlite", "libzlib"], loads = ["libsqlite", "libzlib"], system_libs = None):
    """A graph of one test that loads `loads`, pinning `libs` (or the entries `system_libs`)."""
    g = {
        "unit_graph": fmt,
        "units": [
            {"id": "p@1.0.0#mojo1.0.0/lib", "kind": "lib", "deps": []},
            {"id": "p@1.0.0#mojo1.0.0/test:t", "kind": "test", "deps": ["p@1.0.0#mojo1.0.0/lib"], "loads": loads},
        ],
    }
    if system_libs != None:
        g["system_libs"] = system_libs
    elif libs != None:
        g["system_libs"] = [_entry(n) for n in libs]
    return g

def the_formats_of_the_rules_are_accepted(refuse = fail):
    """Formats 1, 2 and 3 are read: a graph of a format that predates `loads` is as it always was, and 3 is the one that has them."""
    for n in [1, 2, 3]:
        check_graph_format("g", n, refuse)

def a_format_above_three_is_refused(refuse = fail):
    """A rules version that does not know a format must not run its tests: 4 is refused naming the formats read and the fix."""
    check_graph_format("the committed unit graph", 4, refuse)

def a_format_that_is_no_number_is_refused(refuse = fail):
    """0, a negative number and text are no format number."""
    for n in [0, -1, "3"]:
        check_graph_format("g", n, refuse)

def pinned_system_libs_are_read_by_name(refuse = fail):
    """`system_libs_of` keys the entries by name, whole, and a graph with none gives an empty dict."""
    got = system_libs_of("g", graph(), refuse)
    if sorted(got.keys()) != ["libsqlite", "libzlib"] or got["libzlib"]["size"] != 10:
        refuse("the entries of a graph are not read by name: {}".format(got))
    if system_libs_of("g", graph(2, None, []), refuse) != {}:
        refuse("a graph without system_libs does not give an empty dict")

def an_entry_without_a_size_is_refused(refuse = fail):
    """Every field of an entry is required: the sha256 and size are what the download is checked against."""
    e = _entry("libsqlite")
    e.pop("size")
    system_libs_of("g", graph(system_libs = [e]), refuse)

def an_entry_with_a_short_sha256_is_refused(refuse = fail):
    """An entry is pinned like every download: 64 lower-case hex digits and a positive size."""
    system_libs_of("g", graph(system_libs = [_entry("libsqlite", sha256 = "abc")]), refuse)

def a_library_pinned_twice_is_refused(refuse = fail):
    """One name, one pin."""
    system_libs_of("g", graph(libs = ["libsqlite", "libsqlite"]), refuse)

def system_libs_in_an_older_graph_are_refused(refuse = fail):
    """`system_libs` is a format 3 key: a graph of format 2 that has it was not made by a mopm that knows what it means."""
    system_libs_of("g", graph(fmt = 2), refuse)

def a_library_a_unit_loads_is_pinned(refuse = fail):
    """Every name of a `loads` is an entry."""
    g = graph()
    check_loads("g", g, system_libs_of("g", g, refuse), refuse)

def a_library_a_unit_loads_and_the_graph_does_not_pin_is_refused(refuse = fail):
    """A lock without the pin (`mopm lock` not run) leaves a test with nothing to run on: refused naming the unit, the library and the fix."""
    g = graph(libs = ["libsqlite"])
    check_loads("g", g, system_libs_of("g", g, refuse), refuse)

def loads_in_an_older_graph_are_refused(refuse = fail):
    """`loads` is a format 3 key as well."""
    g = graph(fmt = 2, libs = None)
    check_loads("g", g, {}, refuse)

def a_graph_without_loads_needs_no_pin(refuse = fail):
    """A package that loads nothing has units without `loads` and no `system_libs`: accepted, in any format."""
    g = {"unit_graph": 2, "units": [{"id": "p@1.0.0#mojo1.0.0/lib", "kind": "lib", "deps": []}]}
    check_loads("g", g, system_libs_of("g", g, refuse), refuse)

def subdirs_that_pin_the_same_libraries_are_accepted(refuse = fail):
    """Each subdir has its own file for a library; the libraries and who loads them are the same."""
    check_same_system_libs({"linux-64": graph(), "osx-arm64": graph()}, "linux-64", refuse)

def a_subdir_that_pins_another_library_is_refused(refuse = fail):
    """A subdir changes the file of a library, never which libraries a package needs."""
    check_same_system_libs({"linux-64": graph(), "osx-arm64": graph(libs = ["libsqlite"])}, "linux-64", refuse)

def a_subdir_whose_unit_loads_another_library_is_refused(refuse = fail):
    """Nor which of them a unit loads."""
    check_same_system_libs({"linux-64": graph(), "osx-arm64": graph(loads = ["libsqlite"])}, "linux-64", refuse)

def a_slice_for_the_compile_is_never_above_format_two(refuse = fail):
    """`mopm unit build` of the pinned mopm reads formats 1 and 2: 1 and 2 stay as they are, and 3 is said as 2."""
    for n, want in [(1, 1), (2, 2), (3, 2)]:
        if compile_format(n) != want:
            refuse("compile_format({}) is {}, not {}".format(n, compile_format(n), want))
