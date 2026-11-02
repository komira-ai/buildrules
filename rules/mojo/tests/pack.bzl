"""What `mojo_conda` stages for `mopm pack` (rules/mojo/pack.bzl, `workspace_tree`): the checks of rules/mojo/tests/BUCK. Each takes `refuse`, as the checks of siblings.bzl do.
A check that expects refusals asserts the tree it gets with `fail`, not `refuse`: its recorder holds only `workspace_tree`'s own refusals, so a wrong tree fails loading."""

load("//rules/mojo:defs.bzl", "program_sources")
load("//rules/mojo:pack.bzl", "pack_workspace", "workspace_tree")

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

def program_leaving_the_package_is_refused(refuse = fail):
    """A program whose path climbs out of the package's directory is not the package's own: refused, and not staged, whether it stays in the repository
    (`../b/x.mojo`, `bins/../../y.mojo`) or leaves it (`../../../x.mojo`, `/etc/x.mojo`); a path that names the directory itself (`.`) is no file and is refused too. The
    other programs stay."""
    got, _ = workspace_tree("src/p", "m", {}, {"../../../x.mojo": "x", "/etc/x.mojo": "e", "../b/x.mojo": "b", "bins/../../y.mojo": "y", ".": "d", "bins/run.mojo": "run"}, refuse)
    if got != {"src/p/mopm.toml": "m", "src/p/bins/run.mojo": "run"}:
        fail("a refused program is staged, or the others are lost: {}".format(got))
    root, _ = workspace_tree("", "m", {}, {"../x.mojo": "x", "./run.mojo": "run"}, refuse)
    if root != {"mopm.toml": "m", "run.mojo": "run"}:
        fail("a program leaving a package at the repository root is staged, or one that stays below it is lost: {}".format(root))

def program_on_a_staged_manifest_is_refused(refuse = fail):
    """A program that lands on a file already staged (the package's manifest, a member's) is refused, and the manifest keeps its file."""
    got, _ = workspace_tree("src/p", "m", {"util": "um"}, {"mopm.toml": "p", "util/mopm.toml": "u"}, refuse)
    if got != {"src/p/mopm.toml": "m", "src/p/util/mopm.toml": "um"}:
        fail("a program replaced a staged manifest: {}".format(got))

def two_paths_of_one_program_are_refused(refuse = fail):
    """Two programs that normalize to one path (`bins/a.mojo` and `./bins/a.mojo`) are one file: refused, and the first keeps it."""
    got, _ = workspace_tree("src/p", "m", {}, {"bins/a.mojo": "first", "./bins/a.mojo": "second"}, refuse)
    if got != {"src/p/mopm.toml": "m", "src/p/bins/a.mojo": "first"}:
        fail("a second program replaced the first: {}".format(got))

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

def neither_programs_nor_members_is_the_manifest_alone(refuse = fail):
    """A package with neither programs nor members gives `mopm pack` its manifest alone, no workspace, whether the two are left out or given empty; either one
    alone makes the workspace."""
    for got in [pack_workspace("src/p", "m"), pack_workspace("src/p", "m", {}, {}, refuse), pack_workspace("", "m", {}, {}, refuse)]:
        if got != None:
            refuse("a package with neither programs nor members is staged in a workspace: {}".format(got))
    if pack_workspace("src/p", "m", {}, {"bins/run.mojo": "run"}, refuse) != ({"src/p/mopm.toml": "m", "src/p/bins/run.mojo": "run"}, "src/p/mopm.toml"):
        refuse("a package with a program and no members is not staged in a workspace")
    if pack_workspace("src/p", "m", {"util": "um"}, {}, refuse) != ({"src/p/mopm.toml": "m", "src/p/util/mopm.toml": "um"}, "src/p/mopm.toml"):
        refuse("a package with a member and no programs is not staged in a workspace")

def program_through_a_dot_dot_or_naming_a_directory_is_refused(refuse = fail):
    """mopm opens a program's path as written. `bins/../run.mojo` stays in the package once normalized but goes through `bins/`, which nothing else stages, and
    `bins/run.mojo/` and `bins/run.mojo/.` name a directory: each is refused and not staged; `./bins//x.mojo` and `bins/./y.mojo`, which a filesystem resolves to
    the staged file, are staged."""
    got, _ = workspace_tree("src/p", "m", {}, {"bins/../run.mojo": "r", "bins/run.mojo/": "d", "bins/run.mojo/.": "dd", "./bins//x.mojo": "x", "bins/./y.mojo": "y"}, refuse)
    if got != {"src/p/mopm.toml": "m", "src/p/bins/x.mojo": "x", "src/p/bins/y.mojo": "y"}:
        fail("a program through `..` or naming a directory is staged, or a plain one is lost: {}".format(got))
    root, _ = workspace_tree("", "m", {}, {"run.mojo/.": "d", "./run.mojo": "run"}, refuse)
    if root != {"mopm.toml": "m", "run.mojo": "run"}:
        fail("a program naming a directory of a package at the repository root is staged, or the plain one is lost: {}".format(root))

def package_leaving_the_repository_is_refused(refuse = fail):
    """A package directory that climbs out of the repository has no tree: refused, with nothing staged and no manifest path."""
    got, own = workspace_tree("../x", "m", {"util": "um"}, {"bins/run.mojo": "run"}, refuse)
    if got != {} or own != "":
        fail("a package outside the repository is staged: {} (manifest {})".format(got, own))

def member_leaving_the_repository_is_refused(refuse = fail):
    """A member whose path climbs out of the repository is refused and not staged; the package's manifest and the other members stay."""
    got, own = workspace_tree("src/p", "m", {"../../../q": "qm", "util": "um"}, {}, refuse)
    if got != {"src/p/mopm.toml": "m", "src/p/util/mopm.toml": "um"} or own != "src/p/mopm.toml":
        fail("a member outside the repository is staged, or the others are lost: {} (manifest {})".format(got, own))

def member_on_a_staged_manifest_is_refused(refuse = fail):
    """Two member paths that normalize to one directory (`util`, `./util/`), and a member at the package's own directory (`.`), land on a staged manifest:
    refused, and the first keeps its file."""
    got, own = workspace_tree("src/p", "m", {"util": "um", "./util/": "second", ".": "self"}, {}, refuse)
    if got != {"src/p/mopm.toml": "m", "src/p/util/mopm.toml": "um"} or own != "src/p/mopm.toml":
        fail("a member replaced a staged manifest: {} (manifest {})".format(got, own))

def program_source_outside_the_package_is_refused(refuse = fail):
    """In a rooted graph a program of the package whose source is not below the package's directory is refused and left out: one elsewhere in the repository,
    and one in a directory that only starts with the package's name (`src/application` for the package at `src/app`). The program below it stays."""
    units = [
        {"kind": "bin", "package": "app", "srcs": [{"path": "other/x.mojo"}]},
        {"kind": "bin", "package": "app", "srcs": [{"path": "src/application/y.mojo"}]},
        {"kind": "bin", "package": "app", "srcs": [{"path": "src/app/bins/run.mojo"}]},
    ]
    got = program_sources(units, "app", "src/app", "", True, refuse)
    if got != {"bins/run.mojo": "bins/run.mojo"}:
        fail("a program source outside the package is kept, or the one below it is lost: {}".format(got))
