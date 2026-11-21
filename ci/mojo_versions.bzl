"""A Mojo package built for several Mojo versions is configured, at each version, with that version's graph and toolchain, and so is every package it imports
(rules/mojo/versions.bzl); a package with one version builds as it did. Read off configured targets and their analysis, not off the macro:

  - one package at each version (`--target-platforms buildrules//platforms:linux_x86_64_mojo_<v>`, and no constraint for the default): the toolchain target of
    its library is `mojo_<v>`, its unit id and the graph it is given are for Mojo `<v>` with the closure the table records for it, `:conda` is named
    `-mojo<v>_0.conda`, and its outputs are in a directory of their own (another configuration: other action keys and cache entries);
  - a chain app -> util at a version: the library app imports is util's `:lib` configured for the same platform, built with util's `<v>` toolchain as
    util's `<v>` unit, and app's closure names that unit;
  - the same through `mojo_at` (rules/matrix.bzl, examples/mojo/versions/BUCK): every library unit of the cell is built at its version, none at another;
  - eight examples of one version on the default platform: the same targets and the same paths of their default outputs as before versions existed
    (ci/mojo_versions_golden.bzl).

A platform that asks for a version a table has no graph for is refused, naming the package, the version and `buildrules mojo sync` (ci/negative.bzl CASES).
`versions_problems` is a part of ci/negative.bxl, which the public CI runs as a part of ci/completeness.bxl.
"""

load("//examples/mojo/versions/app:buildrules.mojo.lock.bzl", "MOJOS")
load(":mojo_versions_golden.bzl", "GOLDEN")

APP = "//examples/mojo/versions/app"
UTIL = "//examples/mojo/versions/util"
DEFAULT_PLATFORM = "buildrules//platforms:linux_x86_64"

# (target platform, Mojo version it builds). The first is the platform with no Mojo constraint: the default version, 1.0.0.
CELLS = [
    (DEFAULT_PLATFORM, "1.0.0"),
    ("buildrules//platforms:linux_x86_64_mojo_1_1_0", "1.1.0"),
    ("buildrules//platforms:linux_x86_64_mojo_1_2_0", "1.2.0"),
]

# The `mojo_at` cells of examples/mojo/versions/BUCK and the version of each.
MATRIX = [("//examples/mojo/versions:app_at_mojo_1_1_0", "1.1.0"), ("//examples/mojo/versions:app_at_mojo_1_2_0", "1.2.0")]

def _outputs(ctx, node):
    r = ctx.lazy.analysis(node).catch().resolve()
    if not r.is_ok():
        return None, str(r.unwrap_err())
    return [get_path_without_materialization(o, ctx) for o in r.unwrap().providers()[DefaultInfo].default_outputs], None

def _config(label):
    """The configuration of a configured label: the part of its text in parentheses."""
    return str(label).partition(" (")[2]

def _unit_problems(who, attrs, package, version):
    """The library unit `attrs` (configured attributes) is the unit of `package` for Mojo `version`, built with that version's toolchain."""
    problems = []
    tc = attrs.toolchain.value().name
    if tc != "mojo_" + version.replace(".", "_"):
        problems.append("{}: is built with {}, not the toolchain of Mojo {}".format(who, tc, version))
    uid = attrs.unit_id.value()
    if not uid.startswith(package + "@") or "#mojo{}/".format(version) not in uid:
        problems.append("{}: is the unit {}, not the {} unit for Mojo {}".format(who, uid, package, version))
    graph = json.decode(attrs.graph.value())
    if graph["mojo"] != version or graph["toolchain"]["mojo"] != version:
        problems.append("{}: is given the graph for Mojo {}, not {}".format(who, graph["mojo"], version))
    if graph["toolchain"]["closure_sha256"] != MOJOS[version]["CLOSURE_SHA256"]:
        problems.append("{}: its graph pins the closure {}, not the one the table records for Mojo {}".format(who, graph["toolchain"]["closure_sha256"], version))
    if attrs.mojo.value() != version:
        problems.append("{}: says Mojo {}, not {}".format(who, attrs.mojo.value(), version))
    return problems

def _cell_problems(ctx):
    problems = []
    dirs = {}
    for platform, version in CELLS:
        who = "{} on {}".format(APP, platform)
        lib = ctx.configured_targets(APP + ":lib_ungated", target_platform = platform)
        problems += _unit_problems(who + ":lib_ungated", lib.attrs_eager(), "versions_app", version)
        outs, err = _outputs(ctx, lib)
        if err:
            problems.append("{}: the library does not analyse: {}".format(who, err))
        else:
            d = outs[0].rpartition("/examples/mojo/versions/app/")[0]
            if d in dirs:
                problems.append("{}: its outputs are in {}, the directory of the build for Mojo {}: the two versions would share action keys and cache entries".format(who, d, dirs[d]))
            dirs[d] = version
        conda, err = _outputs(ctx, ctx.configured_targets(APP + ":conda", target_platform = platform))
        want = "-0.1.0-mojo{}_0.conda".format(version)
        if err:
            problems.append("{}: :conda does not analyse: {}".format(who, err))
        elif not conda[0].endswith(want):
            problems.append("{}: :conda is {}, not a file named ...{}".format(who, conda[0], want))

        # The chain: what app imports is util's library for the same platform, util's unit for this version.
        deps = lib.attrs_eager().deps.value()
        if [str(d.raw_target()) for d in deps] != ["buildrules" + UTIL + ":lib"]:
            problems.append("{}: imports {}, not util's :lib".format(who, [str(d) for d in deps]))
            continue
        if _config(deps[0]) != _config(lib.label):
            problems.append("{}: imports util's :lib configured for {}, not for {}".format(who, _config(deps[0]), _config(lib.label)))
        util = ctx.configured_targets(UTIL + ":lib_ungated", target_platform = platform)
        problems += _unit_problems("{} on {}:lib_ungated".format(UTIL, platform), util.attrs_eager(), "versions_util", version)
        closure = lib.attrs_eager().closure_ids.value()
        if closure.get("versions_util") != util.attrs_eager().unit_id.value():
            problems.append("{}: its closure names util as {}, not as util's unit for Mojo {}, {}".format(who, closure.get("versions_util"), version, util.attrs_eager().unit_id.value()))
    return problems

def _matrix_problems(ctx):
    """Every library unit in the closure of a `mojo_at` cell is built at the cell's version: app's and util's, and no other."""
    problems = []
    for cell, version in MATRIX:
        units = {}
        for node in ctx.cquery().deps(ctx.configured_targets(cell, target_platform = DEFAULT_PLATFORM)):
            label = node.label.raw_target()
            if label.name == "lib_ungated" and label.package.startswith("examples/mojo/versions/"):
                units[label.package] = units.get(label.package, 0) + 1
                problems += _unit_problems("{}: {}".format(cell, node.label), node.attrs_eager(), "versions_" + label.package.rpartition("/")[2], version)
        if units != {"examples/mojo/versions/app": 1, "examples/mojo/versions/util": 1}:
            problems.append("{}: builds the library units {} (count per package), not app's and util's once each".format(cell, units))
    return problems

def golden_listing(ctx):
    """`{package: {target: [paths of its default outputs]}}` of the packages of GOLDEN on the default platform (`["<analysis fails>"]` for a target that does not analyse)."""
    out = {}
    for pkg in sorted(GOLDEN.keys()):
        rows = {}
        for node in ctx.configured_targets(pkg + ":", target_platform = DEFAULT_PLATFORM):
            outs, err = _outputs(ctx, node)
            rows[node.label.name] = ["<analysis fails>"] if err else outs
        out[pkg] = rows
    return out

def _golden_problems(ctx):
    problems = []
    got = golden_listing(ctx)
    for pkg in sorted(GOLDEN.keys()):
        want = GOLDEN[pkg]
        have = got[pkg]
        for t in sorted({k: True for k in list(want.keys()) + list(have.keys())}.keys()):
            if t not in have:
                problems.append("{}:{} is in the golden and no longer a target on {}".format(pkg, t, DEFAULT_PLATFORM))
            elif t not in want:
                problems.append("{}:{} is a target on {} the golden does not have".format(pkg, t, DEFAULT_PLATFORM))
            elif have[t] != want[t]:
                problems.append("{}:{} has the outputs {}, the golden {}".format(pkg, t, have[t], want[t]))
    return problems

def versions_problems(ctx):
    """Every way the build of a package at a Mojo version is not that version's, or the default build is not what it was: a list of strings, empty when all holds."""
    return _cell_problems(ctx) + _matrix_problems(ctx) + _golden_problems(ctx)
