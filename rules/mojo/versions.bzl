"""The Mojo versions of a package, and how a target platform chooses among them (docs/contract.md, section 12.3, "One graph per Mojo version").

A package whose `mopm.toml` lists several Mojo versions (`[package] mojo = ["1.0.0", "1.1.0", "1.2.0"]`) has a unit graph for each. `buildrules mojo sync` commits
the graph of the default version (`MOJO`, the version mopm-toolchain.toml names) as it always did, and the graphs of the others as `GRAPH_JSON_MOJO_<v>` blocks,
with `MOJOS` naming every version, each with its own closure hash and its graph per subdir:

    MOJOS = {
        "1.0.0": {"CLOSURE_SHA256": CLOSURE_SHA256, "GRAPHS": GRAPHS},
        "1.2.0": {"CLOSURE_SHA256": "<sha256>", "GRAPHS": {"linux-64": json.decode(GRAPH_JSON_MOJO_1_2_0)}},
    }

`mojo_package` chooses the version by the target platform: its value of the constraint `buildrules//platforms:mojo_version` (`mojo_<v>`, one value for each
version of `MOJO_VERSIONS`). The graph a unit is built from, the toolchain (`toolchains//:mojo_<v>`), the unit ids, the `.conda` of a registry package and the
name of `:conda` follow it, through a `select` on the config setting `buildrules//platforms:mojo_is_<v>` whose branches are the `select`s by subdir of
rules/mojo/subdirs.bzl. A platform with no Mojo constraint is built at the default version. The dependencies of a package are configured for the same platform,
so each is built at the same version with its own toolchain, and the analysis refuses a dependency built for another (rules/mojo/unit.bzl, `check_closure_ids`).
A platform that asks for a version the table has no graph for is refused by the package's `:check`, which every target waits for, naming the package, the
version and `buildrules mojo sync`. rules/matrix.bzl (`mojo_at`) builds targets at a version in the same build as the default.

A table without `MOJOS` has one version, the default: on a platform without the constraint its targets, their attributes and their outputs are what they were.
"""

load(":link.bzl", _check_link_keys = "check_link_keys", _check_same_links = "check_same_links", _is_provided = "is_provided", _unit_link = "unit_link")
load(":names.bzl", _check_import_names = "check_import_names")
load(":subdirs.bzl", "BASE_SUBDIR", "check_same_units", "table_graphs")
load(":version_names.bzl", "MOJO_VERSIONS", "mojo_setting")
load(":system_libs.bzl", _check_graph_format = "check_graph_format", _check_loads = "check_loads", _check_same_system_libs = "check_same_system_libs", _system_libs_of = "system_libs_of")

# mopm-toolchain.toml names the mopm and the default Mojo of the packages at and below its directory.
TOOLCHAIN_FILE = "mopm-toolchain.toml"

# mopm-toolchain.toml is required: no mopm and no Mojo is chosen for a package that does not name them.
TOOLCHAIN_FILE_HELP = ("{} is required and there is no default. Create it at or above the package directory, for example:\n\n" +
                       "[toolchain]\nmopm = \"0.0.48\"\nmojo = \"1.0.0\"\n\n(an exact release each), then run `buildrules mojo sync`.").format(TOOLCHAIN_FILE)

def check_toolchain_file_recorded(t, refuse = fail):
    """A table made without mopm-toolchain.toml (or by hand) is refused: the file is what chooses mopm and Mojo. `refuse` is `fail` in a
    build; a test passes a recorder (rules/rust/refusal.bzl)."""
    names = [k for k in t.get("MANIFEST_SHA256", {}).keys() if k.split("/")[-1] == TOOLCHAIN_FILE]
    if not names:
        refuse("buildrules.mojo.lock.bzl records no {}: {}".format(TOOLCHAIN_FILE, TOOLCHAIN_FILE_HELP))

def check_toolchain_file_present(where, present, refuse = fail):
    """The file the table names is not in the checkout (`present` is the result of a glob): refused, naming the file and an example."""
    if not present:
        refuse("{}: {}".format(where, TOOLCHAIN_FILE_HELP))

def table_mojos(table, refuse = fail):
    """`{version: {"closure": sha256, "graphs": {subdir: graph}}}` of a table. A table without `MOJOS` has the default version alone. `refuse` is `fail` in a build;
    a test passes a recorder (rules/rust/refusal.bzl)."""
    default = table["MOJO"]
    own = {"closure": table["CLOSURE_SHA256"], "graphs": table_graphs(table, refuse)}
    mojos = table.get("MOJOS")
    if mojos == None:
        return {default: own}
    if default not in mojos:
        refuse("buildrules.mojo.lock.bzl has MOJOS for {} and MOJO {}, which it does not name: the file was edited by hand; run `buildrules mojo sync`".format(", ".join(sorted(mojos.keys())), default))
        return {default: own}
    out = {}
    for v in sorted(mojos.keys()):
        e = mojos[v]
        if v == default:
            if e["CLOSURE_SHA256"] != own["closure"] or e["GRAPHS"] != own["graphs"]:
                refuse("buildrules.mojo.lock.bzl: the MOJOS entry of the default Mojo {} is not its MOJO, CLOSURE_SHA256 and graphs: the file was edited by hand; run `buildrules mojo sync`".format(v))
            out[v] = own
            continue
        if v not in MOJO_VERSIONS:
            refuse(("buildrules.mojo.lock.bzl holds a unit graph for Mojo {}, a version no target platform of these rules can ask for (they know {}): build it as the default " +
                    "(name it in mopm-toolchain.toml) or use a buildrules that knows it").format(v, ", ".join(MOJO_VERSIONS)))
        out[v] = {"closure": e["CLOSURE_SHA256"], "graphs": table_graphs({"GRAPHS": e["GRAPHS"]}, refuse)}
    return out

def unit_slot(uid):
    """A unit's id without the version of its package and the Mojo version: `example/json@0.1.0#mojo1.2.0/test:tests/t.mojo` -> `example/json#test:tests/t.mojo`.
    The graphs of two Mojo versions name the same units by different ids (the id says the version, and a registry package may resolve to another version of it
    for each Mojo); the slot is what is the same. A reader splits the id at the first `@` (a full name has none, a test file may), then at `#mojo` and at the
    first `/` after it. A native unit (`native:<package>/<id>`) names no version and is its own slot."""
    if uid.startswith("native:"):
        return uid
    name, _, rest = uid.partition("@")
    _, _, mode = rest.partition("#mojo")
    return name + "#" + mode.partition("/")[2]

def _shape(graph):
    """What must be the same in the graphs of two Mojo versions, unit by unit (by slot): what is built, from which sources, with which libraries, in which order."""
    return {unit_slot(u["id"]): {
        "deps": [unit_slot(d) for d in u["deps"]],
        "kind": u["kind"],
        "link": (_unit_link(u), _is_provided(u)),
        "loads": u.get("loads", []),
        "natives": [n["soname"] for n in u.get("natives", [])],
        "outputs": u.get("outputs", []),
        "package": u.get("package"),
        "srcs": [s["path"] for s in u.get("srcs", [])],
    } for u in graph["units"]}

def check_mojos(table, refuse = fail):
    """Every graph of the table is what it says (the format, the keys of formats 3 to 6, the Mojo version, the subdir, the closure) and the graphs of each version are
    one package: the same units in every subdir (rules/mojo/subdirs.bzl), and in every version the same units by slot, with the same subdirs and the same system
    libraries. `mojo_package` builds one set of targets whose attributes follow the version, so a version that builds other units is refused. Returns `table_mojos`."""
    mojos = table_mojos(table, refuse)
    default = table["MOJO"]
    base = mojos[default]["graphs"]
    for v in sorted(mojos.keys()):
        graphs = mojos[v]["graphs"]
        check_same_units(graphs, refuse)
        _check_same_system_libs(graphs, BASE_SUBDIR, refuse)
        _check_same_links(graphs, BASE_SUBDIR, refuse)
        for sd, x in sorted(graphs.items()):
            who = "the committed unit graph of {}".format(sd) if v == default else "the committed unit graph for Mojo {} of {}".format(v, sd)
            _check_graph_format(who, x["unit_graph"], refuse)
            _check_link_keys(who, x, refuse)
            _check_import_names(who, x, refuse)
            _check_loads(who, x, _system_libs_of(who, x, refuse), refuse)
            if x["mojo"] != v or x["toolchain"]["mojo"] != v:
                refuse("{} is for Mojo {}, not {}: run `buildrules mojo sync`".format(who, x["mojo"], v))
            if x["toolchain"].get("subdir", BASE_SUBDIR) != sd:
                refuse("the graph kept for {} is the graph of {}: the file was edited by hand; run `buildrules mojo sync`".format(sd, x["toolchain"].get("subdir", BASE_SUBDIR)))
        if v == default:
            continue
        if graphs[BASE_SUBDIR]["toolchain"]["closure_sha256"] != mojos[v]["closure"]:
            refuse("the table records toolchain closure {} for Mojo {} but its unit graph pins {}: the file was edited by hand; run `buildrules mojo sync`".format(mojos[v]["closure"], v, graphs[BASE_SUBDIR]["toolchain"]["closure_sha256"]))
        if sorted(graphs.keys()) != sorted(base.keys()):
            refuse("the table holds graphs of {} for Mojo {} and of {} for Mojo {}: every version is built for the same platforms; run `buildrules mojo sync` with a mopm.lock that locks every version for each".format(
                ", ".join(sorted(graphs.keys())),
                v,
                ", ".join(sorted(base.keys())),
                default,
            ))
            continue
        if _shape(graphs[BASE_SUBDIR]) != _shape(base[BASE_SUBDIR]):
            refuse(("the unit graph for Mojo {} does not name the units of the graph for Mojo {} (their packages, sources, outputs, native and system libraries, " +
                    "or dependencies): one package builds the same units for every version; run `buildrules mojo sync`").format(v, default))
        for sd in sorted(graphs.keys()):
            if graphs[sd].get("system_libs", []) != base[sd].get("system_libs", []):
                refuse(("the unit graph for Mojo {} of {} pins other system libraries than the graph for Mojo {}: the test runs of every version load the same files; " +
                        "pin the same ones for each").format(v, sd, default))
    return mojos

def ids_by_slot(graph):
    """`{slot: unit id}` of a graph."""
    return {unit_slot(u["id"]): u["id"] for u in graph["units"]}

def by_mojo(mojos, default, value):
    """`value(default)` for a table with one version, else a `select` over the versions the table has graphs for: the branch of each is `value(version)`, and a
    platform with no Mojo constraint (or one for a version the table lacks, which `unsupported_mojo` refuses) gets the default's."""
    if len(mojos) == 1:
        return value(default)
    branches = {mojo_setting(v): value(v) for v in sorted(mojos.keys()) if v in MOJO_VERSIONS}
    branches["DEFAULT"] = value(default)
    return select(branches)

def unsupported_mojo_branches(mojos, default, who):
    """`{config setting or "DEFAULT": refusal}` of `unsupported_mojo`: empty for a version the table has a graph for and for a platform that asks for none; the
    refusal for every other version a platform can ask for."""
    branches = {"DEFAULT": ""}
    for v in MOJO_VERSIONS:
        if v in mojos:
            branches[mojo_setting(v)] = ""
        else:
            branches[mojo_setting(v)] = ("{}: the target platform asks for Mojo {} and buildrules.mojo.lock.bzl holds unit graphs for Mojo {} only. List {} in " +
                                         "`mojo = [...]` of the package's mopm.toml, run `mopm lock`, then `buildrules mojo sync` (default Mojo: {}, from mopm-toolchain.toml)").format(
                who,
                v,
                ", ".join(sorted(mojos.keys())),
                v,
                default,
            )
    return branches

def unsupported_mojo(mojos, default, who):
    """What the package's `:check` is given as `unsupported_mojo`: empty on a platform whose Mojo version the table has a graph for, else the refusal."""
    return select(unsupported_mojo_branches(mojos, default, who))
