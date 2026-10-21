"""Where the native libraries of a unit come from (rules/mojo/defs.bzl, `native_wiring` and `own_static_natives`): the checks of rules/mojo/tests/BUCK.

The unit is the shape of mopm's graph with two static archives of registry packages, the second needed by the first (a library before every library it
needs: the order of the link line, which is not the sorted order), and a shared library a user supplies. A check takes the way to refuse as an argument
(rules/rust/refusal.bzl) and refuses with what is wrong, so a test target is green only if nothing was.
"""

load("//rules/mojo:defs.bzl", "native_wiring", "own_static_natives")

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
