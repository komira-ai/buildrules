"""What `mojo_conda` stages for `mopm pack` (rules/mojo/pack.bzl, `workspace_tree`): the checks of rules/mojo/tests/BUCK. Each takes `refuse`, as the checks of siblings.bzl do."""

load("//rules/mojo:defs.bzl", "program_sources")
load("//rules/mojo:pack.bzl", "workspace_tree")

def program_is_staged_at_its_path(refuse = fail):
    """A program of `[targets] bins` is staged below the package's directory at the path the manifest writes, beside the manifest and the members."""
    got, own = workspace_tree("src/p", "m", {"../b": "bm"}, {"bins/run.mojo": "run", "./tools//x.mojo": "x"}, refuse)
    want = {
        "src/p/mopm.toml": "m",
        "src/b/mopm.toml": "bm",
        "src/p/bins/run.mojo": "run",
        "src/p/tools/x.mojo": "x",
    }
    if got != want or own != "src/p/mopm.toml":
        refuse("the programs are not staged below the package's directory: {} (manifest {})".format(got, own))
    root, root_own = workspace_tree("", "m", {}, {"run.mojo": "run"}, refuse)
    if root != {"mopm.toml": "m", "run.mojo": "run"} or root_own != "mopm.toml":
        refuse("a program of a package at the repository root is not staged at its own path: {}".format(root))

def package_without_programs_stages_what_it_did(refuse = fail):
    """No programs: the tree is the manifest and the members, exactly as before `bins` existed."""
    got, own = workspace_tree("src/p", "m", {"../b": "bm", "util": "um"}, {}, refuse)
    if got != {"src/p/mopm.toml": "m", "src/b/mopm.toml": "bm", "src/p/util/mopm.toml": "um"} or own != "src/p/mopm.toml":
        refuse("a package with no programs is not staged as members alone: {} (manifest {})".format(got, own))
    default, _ = workspace_tree("src/p", "m", {"../b": "bm", "util": "um"})
    if default != got:
        refuse("leaving `bins` out is not the same as an empty `bins`: {}".format(default))

def program_leaving_the_repository_is_refused(refuse = fail):
    """A program whose path climbs out of the repository from the package's directory has no place in the tree: refused, and not staged."""
    got, _ = workspace_tree("src/p", "m", {}, {"../../../x.mojo": "x", "bins/run.mojo": "run"}, refuse)
    if "src/p/bins/run.mojo" not in got or len(got) != 2:
        refuse("a refused program is staged, or the others are lost: {}".format(got))

def program_on_a_staged_manifest_is_refused(refuse = fail):
    """A program that lands on a file already staged (the package's manifest, a member's) is refused, and the manifest keeps its file."""
    got, _ = workspace_tree("src/p", "m", {"util": "um"}, {"mopm.toml": "p", "util/mopm.toml": "u"}, refuse)
    if got != {"src/p/mopm.toml": "m", "src/p/util/mopm.toml": "um"}:
        refuse("a program replaced a staged manifest: {}".format(got))

def two_paths_of_one_program_are_refused(refuse = fail):
    """Two programs that normalize to one path (`bins/a.mojo` and `./bins/a.mojo`) are one file: refused, and the first keeps it."""
    got, _ = workspace_tree("src/p", "m", {}, {"bins/a.mojo": "first", "./bins/a.mojo": "second"}, refuse)
    if got != {"src/p/mopm.toml": "m", "src/p/bins/a.mojo": "first"}:
        refuse("a second program replaced the first: {}".format(got))

_UNITS = [
    {"kind": "lib", "package": "app", "srcs": [{"path": "src/app/src/app/__init__.mojo"}]},
    {"kind": "bin", "package": "app", "srcs": [{"path": "src/app/bins/run.mojo"}]},
    {"kind": "bin", "package": "app", "srcs": [{"path": "src/app/tools/x.mojo"}]},
    {"kind": "bin", "package": "util", "srcs": [{"path": "src/util/bins/other.mojo"}]},
]

def programs_are_the_packages_own_below_it(refuse = fail):
    """The programs come from the package's own `bin` units: a member's are left out, two are two, and each file is named from the BUCK file's directory, in a
    graph whose paths start at the repository root and in one whose paths start at the package."""
    rooted = program_sources(_UNITS, "app", "src/app", "", True, refuse)
    if rooted != {"bins/run.mojo": "bins/run.mojo", "tools/x.mojo": "tools/x.mojo"}:
        refuse("the programs of a rooted graph are not the package's own, below it: {}".format(rooted))
    nested = program_sources(_UNITS, "app", "src/app", "src/app", True, refuse)
    if nested != {"bins/run.mojo": "src/app/bins/run.mojo", "tools/x.mojo": "src/app/tools/x.mojo"}:
        refuse("a package below the BUCK file's directory is not named from it: {}".format(nested))
    unrooted_units = [dict(u, srcs = [{"path": s["path"][len("src/" + u["package"] + "/"):]} for s in u["srcs"]]) for u in _UNITS]
    unrooted = program_sources(unrooted_units, "app", "src/app", "", False, refuse)
    if unrooted != {"bins/run.mojo": "bins/run.mojo", "tools/x.mojo": "tools/x.mojo"}:
        refuse("the programs of an unrooted graph are not the package's own: {}".format(unrooted))
    if program_sources([u for u in _UNITS if u["kind"] != "bin"], "app", "src/app", "", True, refuse) != {}:
        refuse("a package with no program has programs")
