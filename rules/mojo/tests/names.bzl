"""The names of a unit graph of format 6 (rules/mojo/names.bzl) and what the rules make of them (rules/mojo/defs.bzl): the checks of rules/mojo/tests/BUCK.

The graph is mopm 0.0.113's real output (graph6.bzl). A check takes the way to refuse as an argument (rules/rust/refusal.bzl) and refuses with what is wrong, so a test
target is green only if nothing was.
"""

load("//rules/mojo:defs.bzl", "member_label", "native_unit_id", "native_wiring", "unit_slice")
load("//rules/mojo:names.bzl", "check_import_names", "import_name")
load("//rules/mojo:pack.bzl", "conda_name")
load(":graph6.bzl", "GRAPH6_JSON")

GRAPH6 = json.decode(GRAPH6_JSON)

APP_LIB = "example/app@0.1.0#mojo1.0.0/lib"
APP_TEST = "example/app@0.1.0#mojo1.0.0/test:pkgs/app/tests/test_app.mojo"
UTIL_LIB = "example/util@0.2.0#mojo1.0.0/lib"
SHIM = "native:example/app/shim"

def _units(g):
    return {u["id"]: u for u in g["units"]}

def import_names_are_the_name_after_the_namespace(refuse = fail):
    """The import name of a full name is what follows its `/`; a name of a graph before format 6 is its own import name."""
    for package, want in [("example/json", "json"), ("example/http_core", "http_core"), ("json", "json"), ("", "")]:
        if import_name(package) != want:
            refuse("import_name({}) is {}, not {}".format(repr(package), repr(import_name(package)), repr(want)))

def mopm_graph_of_format_six_says_the_import_names_mopm_prints(refuse = fail):
    """Every unit of mopm 0.0.113's graph has the `import` of its full name, and a graph before format 6 has none: both are accepted."""
    check_import_names("g", GRAPH6, refuse)
    check_import_names("g", {"unit_graph": 5, "units": [{"id": "p@1.0.0#mojo1.0.0/lib", "package": "p"}]}, refuse)
    got = {u["id"]: u["import"] for u in GRAPH6["units"]}
    want = {APP_LIB: "app", APP_TEST: "app", "example/app@0.1.0#mojo1.0.0/test:pkgs/app/src/app/tests/test_in_src.mojo": "app", UTIL_LIB: "util", SHIM: "app"}
    if got != want:
        refuse("the golden's import names are not what mopm printed: {}".format(got))

def _graph6_with(**kwargs):
    unit = {"id": "example/json@0.1.0#mojo1.0.0/lib", "package": "example/json", "import": "json"}
    unit.update(kwargs)
    return {"unit_graph": 6, "units": [{k: v for k, v in unit.items() if v != None}]}

def a_unit_of_format_six_without_import_is_refused(refuse = fail):
    """A graph of format 6 that does not say a unit's import name was not printed by mopm."""
    check_import_names("g", _graph6_with(**{"import": None}), refuse)

def an_import_that_is_not_the_name_of_the_package_is_refused(refuse = fail):
    """The import name is the name after the namespace: another would stage the library under a name its importers do not use."""
    check_import_names("g", _graph6_with(**{"import": "example"}), refuse)

def a_bare_package_name_in_format_six_is_refused(refuse = fail):
    """Every package of a graph of format 6 has a full name, even when `import` repeats the bare one."""
    check_import_names("g", _graph6_with(package = "json"), refuse)

def an_import_in_a_graph_older_than_six_is_refused(refuse = fail):
    """`import` is a format 6 key: a graph of format 5 that has it was not printed by a mopm that knows what it means."""
    check_import_names("g", {"unit_graph": 5, "units": [{"id": "p@1.0.0#mojo1.0.0/lib", "package": "p", "import": "p"}]}, refuse)

def a_native_unit_not_named_for_its_package_is_refused(refuse = fail):
    """The id of a native unit starts with its package's full name: another is not a unit mopm printed."""
    native_unit_id("native:example/other/shim", "example/app", refuse)

def the_member_of_a_rooted_graph_of_format_six_is_named_by_its_import(refuse = fail):
    """The library of the path dependency `example/util` is at `pkgs/util/src/util`: its package's directory is above `src/<import>`, not `src/<namespace>/<name>`."""
    u = _units(GRAPH6)[UTIL_LIB]
    got = member_label("pkgs/app", UTIL_LIB, import_name(u["package"]), u["root"], "", refuse, manifest_dirs = [])
    if got != "//pkgs/util:lib":
        refuse("the member of a rooted graph of format 6 is {}, not //pkgs/util:lib".format(got))

def a_slice_of_a_graph_of_format_six_says_six_and_keeps_the_import_names(refuse = fail):
    """`mopm unit build` of mopm 0.0.113 reads format 6 alone: the slice of a test says 6, its own unit and the library it imports keep their `import`, and the native
    unit its `built` entry names is whole but for its `key`."""
    us = _units(GRAPH6)
    for profile in [None, {"opt": 0, "assert": "all", "debug": True}]:
        s = unit_slice(GRAPH6, us, APP_TEST, profile)
        if s["unit_graph"] != 6:
            refuse("the slice of a graph of format 6 says format {}".format(s["unit_graph"]))
        got = {u["id"]: u for u in s["units"]}
        if sorted(got.keys()) != sorted([APP_LIB, APP_TEST, SHIM, UTIL_LIB]):
            refuse("the slice of the test holds {}".format(sorted(got.keys())))
            continue
        if [got[i].get("import") for i in [APP_LIB, APP_TEST, SHIM, UTIL_LIB]] != ["app", "app", "app", "util"]:
            refuse("the slice drops the import names: {}".format(s["units"]))
        if "key" in got[SHIM] or got[SHIM]["srcs"] != us[SHIM]["srcs"] or "srcs" in got[UTIL_LIB]:
            refuse("the native unit is not whole but for its key, or a dependency is not cut: {}".format(s["units"]))
        if profile and got[APP_TEST]["profile"] != profile:
            refuse("the profile of the slice is not the one given: {}".format(got[APP_TEST]["profile"]))

def a_slice_of_a_graph_of_format_five_is_as_it_was(refuse = fail):
    """A graph of an older format is sliced as before: a compile reads format 2 of the mopm that printed it, and the units have no `import` to keep."""
    g = {
        "unit_graph": 5,
        "package": "p@1.0.0",
        "mojo": "1.0.0",
        "toolchain": {},
        "units": [
            {"id": "p@1.0.0#mojo1.0.0/lib", "package": "p", "kind": "lib", "deps": [], "natives": [], "srcs": [], "key": "k"},
            {"id": "p@1.0.0#mojo1.0.0/test:t", "package": "p", "kind": "test", "deps": ["p@1.0.0#mojo1.0.0/lib"], "natives": [], "link": ["m"], "key": "k"},
        ],
    }
    s = unit_slice(g, _units(g), "p@1.0.0#mojo1.0.0/test:t")
    if s["unit_graph"] != 2 or [sorted(u.keys()) for u in s["units"]] != [["deps", "id", "kind", "package"], ["deps", "id", "kind", "natives", "package"]]:
        refuse("the slice of a graph of format 5 is not what it was: {}".format(s))

# A registry package of a graph of format 6, as mopm's spec/unit-graph.md prints one: its static archive is a sub-target of the unpacked `.conda`, named by the import name.
HTTP_CORE_Z = {"id": "z", "soname": "libz_native.a", "sha256": "348e", "package": "example/http_core", "kind": "static"}

def the_archive_of_a_registry_package_of_format_six_is_named_by_its_import(refuse = fail):
    """`:prebuilt_<import name>[<soname>]`: a target name has no `/`, and the import name is the one name of the package within its graph."""
    unit = {"id": "example/app@1.0.0#mojo1.0.0/lib", "package": "example/app", "natives": [HTTP_CORE_Z]}
    sonames, labels = native_wiring(unit, {"example/http_core": True}, {}, "examples/x", refuse)
    if sonames != ["libz_native.a"] or labels != {"libz_native.a": ":prebuilt_http_core[libz_native.a]"}:
        refuse("the archive of a registry package of format 6 is {}".format(labels))

def the_conda_name_of_a_full_name_spells_the_namespace_with_a_dot(refuse = fail):
    """`mopm pack` names the `.conda` of `example/nsshim` `mojo-example.nsshim-...`, and of a package before namespaces `mojo-<name>-...` as it always did."""
    for package, want in [("example/nsshim", "mojo-example.nsshim"), ("example/http_core", "mojo-example.http_core"), ("base", "mojo-base")]:
        if conda_name(package) != want:
            refuse("conda_name({}) is {}, not {}".format(repr(package), repr(conda_name(package)), repr(want)))
