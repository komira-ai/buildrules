"""Where the native libraries of a unit come from (rules/mojo/defs.bzl, `native_wiring` and `own_static_natives`): the checks of rules/mojo/tests/BUCK.

The unit is the shape of mopm's graph with two static archives of registry packages, the second needed by the first (a library before every library it
needs: the order of the link line, which is not the sorted order), and a shared library a user supplies. A check takes the way to refuse as an argument
(rules/rust/refusal.bzl) and refuses with what is wrong, so a test target is green only if nothing was.
"""

load("//rules/mojo:defs.bzl", "is_native_unit", "native_include_dirs", "native_unit_id", "native_wiring", "own_static_natives")

PROBE = {"id": "probe_sys", "soname": "libprobe_sys.a", "sha256": "aa", "package": "probe_sys", "kind": "static", "needs": ["libbase_sys.a"]}
BASE = {"id": "base_sys", "soname": "libbase_sys.a", "sha256": "bb", "package": "base_sys", "kind": "static"}
SHARED = {"id": "cnative", "soname": "libcnative.so.1", "sha256": "cc", "package": "cnative"}
UNIT = {"id": "app@1.0.0#mojo1.0.0/test:t", "package": "app", "natives": [PROBE, BASE, SHARED]}
PREBUILT = {"probe_sys": True, "base_sys": True, "cnative": True}
USER = {"libcnative.so.1": "//x:cnative"}

def wiring_is_as_the_graph_says(refuse = fail):
    """The order of the graph is the order of the unit's native_sonames, and the lock alone gives the static libraries their targets."""
    sonames, labels = native_wiring(UNIT, PREBUILT, USER, "examples/x", refuse)
    if sonames != ["libprobe_sys.a", "libbase_sys.a", "libcnative.so.1"]:
        refuse("the order of the graph is not kept: {}".format(sonames))
    want = {"libprobe_sys.a": ":prebuilt_probe_sys[libprobe_sys.a]", "libbase_sys.a": ":prebuilt_base_sys[libbase_sys.a]", "libcnative.so.1": "//x:cnative"}
    if labels != want:
        refuse("the targets are not the lock's: {}".format(labels))

def reversed_graph_is_reversed(refuse = fail):
    """The reverse order in the graph is the reverse order out: nothing sorts."""
    unit = dict(UNIT, natives = [SHARED, BASE, PROBE])
    sonames, _ = native_wiring(unit, PREBUILT, USER, "examples/x", refuse)
    if sonames != ["libcnative.so.1", "libbase_sys.a", "libprobe_sys.a"]:
        refuse("the order of the graph is not kept: {}".format(sonames))

def own_natives(refuse = fail):
    """Only the static libraries of the package itself come out of its `.conda` (a shared library does not), in the graph's order."""
    got = own_static_natives({"package": "probe_sys", "natives": [PROBE, BASE]})
    if list(got.items()) != [("libprobe_sys.a", "aa")]:
        refuse("a prebuilt unit extracts the natives of its own package only: {}".format(got))
    two = {"package": "p", "natives": [dict(PROBE, package = "p"), dict(BASE, package = "p"), dict(SHARED, package = "p")]}
    got = own_static_natives(two)
    if list(got.items()) != [("libprobe_sys.a", "aa"), ("libbase_sys.a", "bb")]:
        refuse("the static natives of one package are not in the graph's order, or include a shared one: {}".format(got))

# Natives a workspace member builds: entries with `built`, the id of a native unit of the graph (`native:<package>/<id>`). `shim` is the dependent's own member,
# `core` the member below it; the second is needed by the first, so it comes after it in the link line.
SHIM = {"id": "shim", "soname": "libshim.a", "package": "app", "kind": "static", "needs": ["libcore.a"], "built": "native:app/shim"}
CORE = {"id": "core", "soname": "libcore.a", "package": "core", "kind": "static", "built": "native:core/core"}
BUILT_UNIT = {"id": "app@1.0.0#mojo1.0.0/test:t", "package": "app", "natives": [SHIM, CORE, BASE]}
BUILT = {"native:app/shim": ":native_shim", "native:core/core": "//core:native_core"}

def built_natives_are_the_targets_of_their_units(refuse = fail):
    """A `built` entry is the target of the native unit it names (this package's, or the member's), in the graph's order, beside a registry package's archive."""
    sonames, labels = native_wiring(BUILT_UNIT, {"base_sys": True}, {}, "examples/x", refuse, BUILT)
    if sonames != ["libshim.a", "libcore.a", "libbase_sys.a"]:
        refuse("the order of the graph is not kept: {}".format(sonames))
    want = {"libshim.a": ":native_shim", "libcore.a": "//core:native_core", "libbase_sys.a": ":prebuilt_base_sys[libbase_sys.a]"}
    if labels != want:
        refuse("the targets are not the units': {}".format(labels))

def native_units_are_told_by_their_id(refuse = fail):
    """`native:<package>/<id>` is a native unit and its id is what follows the slash; a library or a test is neither."""
    if not is_native_unit("native:app/shim") or is_native_unit("app@1.0.0#mojo1.0.0/lib") or is_native_unit("x/native:y"):
        refuse("is_native_unit does not tell a native unit by its id")
    if native_unit_id("native:app/shim") != "shim" or native_unit_id("native:core/a/b") != "a/b":
        refuse("native_unit_id is not what follows the first slash")

def native_includes_are_below_the_package_in_both_bases(refuse = fail):
    """`includes` is used as the graph prints it, in a rooted graph and an unrooted one (mopm prints directories below the member either way), and is
    never joined to the package's directory again."""
    for rooted, pkg_dir in [(True, "examples/x"), (False, "examples/x"), (True, "")]:
        got = native_include_dirs({"includes": ["native", "extra"], "hdrs": []}, pkg_dir, rooted, refuse)
        if got != ["native", "extra"]:
            refuse("includes are not used as printed (rooted={}, package {}): {}".format(rooted, repr(pkg_dir), got))

def native_includes_default_to_the_header_directories_below_the_package(refuse = fail):
    """A unit that prints no `includes` has the directories of its headers: for a rooted graph the headers carry the repository path, and the default is
    still below the package (`native`, not `examples/x/native`); sorted, each directory once."""
    hdrs = [{"path": "examples/x/native/b.h"}, {"path": "examples/x/native/a.h"}, {"path": "examples/x/third/inc/c.h"}, {"path": "examples/x/top.h"}]
    got = native_include_dirs({"hdrs": hdrs}, "examples/x", True, refuse)
    if got != [".", "native", "third/inc"]:
        refuse("the default of a rooted graph is not the header directories below the package: {}".format(got))
    unrooted = [{"path": "native/a.h"}, {"path": "native/b.h"}]
    got = native_include_dirs({"hdrs": unrooted}, "examples/x", False, refuse)
    if got != ["native"]:
        refuse("the default of an unrooted graph is not the header directories: {}".format(got))
    if native_include_dirs({"hdrs": []}, "examples/x", True, refuse) != []:
        refuse("a unit with no header and no includes has no include directory")
    # An empty `includes` list is unset, as mopm treats it.
    got = native_include_dirs({"includes": [], "hdrs": [{"path": "examples/x/native/a.h"}]}, "examples/x", True, refuse)
    if got != ["native"]:
        refuse("an empty includes list does not fall back to the header directories: {}".format(got))
