"""Checks of what a graph says about linking (rules/mojo/link.bzl) that need no action. Each takes `refuse`, as the checks of system_libs.bzl do."""

load("//rules/mojo:link.bzl", "check_link_keys", "check_same_links", "slice_has_provided", "unit_link")

_NATIVE = "native:p/shim"
_LIB = "p@1.0.0#mojo1.0.0/lib"
_TEST = "p@1.0.0#mojo1.0.0/test:t"

def graph(fmt = 5, link = ["c++", "m"], provided = True, native_extra = {}, test_extra = {}):
    """A graph of a native unit (provided or not), a library and a test that link it, both with `link`."""
    native = {"id": _NATIVE, "kind": "native", "soname": "libshim.a", "srcs": [], "deps": [], "natives": []}
    if provided:
        native["provided"] = True
    native.update(native_extra)
    lib = {"id": _LIB, "kind": "lib", "deps": [], "natives": [{"soname": "libshim.a", "built": _NATIVE}]}
    test = {"id": _TEST, "kind": "test", "deps": [_LIB], "natives": [{"soname": "libshim.a", "built": _NATIVE}]}
    if link != None:
        lib["link"] = link
        test["link"] = link
    test.update(test_extra)
    return {"unit_graph": fmt, "units": [native, lib, test]}

def a_graph_of_format_five_with_link_and_a_provided_native_is_accepted(refuse = fail):
    """What mopm 0.0.101 prints for a package whose archive a rule supplies and whose C++ archive needs libc++."""
    check_link_keys("g", graph(), refuse)

def a_graph_of_format_four_with_a_provided_native_and_no_link_is_accepted(refuse = fail):
    """Format 4 is a graph that has `provided` and no `link`."""
    check_link_keys("g", graph(fmt = 4, link = None), refuse)

def a_graph_of_format_three_without_either_key_is_accepted(refuse = fail):
    """A graph made before the keys existed: no `link`, no `provided`, no change."""
    check_link_keys("g", graph(fmt = 3, link = None, provided = False), refuse)

def an_empty_link_in_an_old_graph_is_the_same_as_none(refuse = fail):
    """`link = []` says nothing and is allowed in any format; `provided = false` likewise."""
    check_link_keys("g", graph(fmt = 2, link = [], provided = False, native_extra = {"provided": False}), refuse)

def a_link_name_outside_the_list_is_refused(refuse = fail):
    """A name from a hand-edited table would reach the linker."""
    check_link_keys("g", graph(link = ["c++", "X11"]), refuse)

def a_link_name_twice_is_refused(refuse = fail):
    """mopm names each library once."""
    check_link_keys("g", graph(link = ["m", "m"]), refuse)

def a_link_in_a_graph_older_than_five_is_refused(refuse = fail):
    """`link` is a format 5 key: a graph of format 4 that has it was not made by a mopm that knows what it means."""
    check_link_keys("g", graph(fmt = 4), refuse)

def a_link_on_a_native_unit_is_refused(refuse = fail):
    """An archive is not linked: the units that link it carry the libraries."""
    check_link_keys("g", graph(native_extra = {"link": ["c++"]}), refuse)

def a_provided_native_in_a_graph_older_than_four_is_refused(refuse = fail):
    """`provided` is a format 4 key."""
    check_link_keys("g", graph(fmt = 3, link = None), refuse)

def a_provided_that_is_not_a_bool_is_refused(refuse = fail):
    """true or false."""
    check_link_keys("g", graph(link = None, provided = False, native_extra = {"provided": "yes"}), refuse)

def a_provided_unit_that_is_not_native_is_refused(refuse = fail):
    """A library or a test is built from its sources."""
    check_link_keys("g", graph(link = None, test_extra = {"provided": True}), refuse)

def subdirs_with_one_link_are_accepted(refuse = fail):
    """Each subdir has its own archives; what the final link adds is the same."""
    check_same_links({"linux-64": graph(), "osx-arm64": graph()}, "linux-64", refuse)

def a_subdir_whose_unit_links_other_libraries_is_refused(refuse = fail):
    """A subdir changes the file of a library, never what its final link adds."""
    check_same_links({"linux-64": graph(), "osx-arm64": graph(link = ["c++"])}, "linux-64", refuse)

def a_subdir_that_provides_another_unit_is_refused(refuse = fail):
    """Nor which native units a rule supplies."""
    check_same_links({"linux-64": graph(), "osx-arm64": graph(provided = False, fmt = 5)}, "linux-64", refuse)

def a_unit_link_is_what_the_graph_says_and_none_is_empty(refuse = fail):
    """The unit's list in mopm's order; a unit with no key has an empty one; the slice of a provided unit is known."""
    g = graph(link = ["c++", "dl"])
    if unit_link(g["units"][2]) != ["c++", "dl"]:
        refuse("the link of the test is {}, not [\"c++\", \"dl\"]".format(unit_link(g["units"][2])))
    if unit_link(g["units"][0]) != []:
        refuse("the link of a native unit is {}, not empty".format(unit_link(g["units"][0])))
    if not slice_has_provided(g["units"]) or slice_has_provided(g["units"][1:]):
        refuse("a slice is told to hold a provided native unit by that unit alone")
