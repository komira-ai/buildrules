"""Path dependencies that are siblings of the package that imports them (rules/mojo/defs.bzl, `member_label`; rules/mojo/check.bzl, `workspace_tree`;
rules/mojo/unit.bzl, `check_closure_ids`): the checks of rules/mojo/tests/BUCK.

A check takes the way to refuse as an argument (rules/rust/refusal.bzl) and refuses with what is wrong, so a test target is green only if nothing was.
"""

load("//rules/mojo:check.bzl", "workspace_tree")
load("//rules/mojo:defs.bzl", "graph_path_in_package", "member_label")

def nested_member_keeps_its_target(refuse = fail):
    """A path dependency below the package is named as it always was: `//<package dir>/<its dir>:lib`, from a root relative to the package."""
    got = member_label("examples/mojo/ws", "base@0.1.0#mojo1.0.0/lib", "base", "util/base/src/base", "examples/mojo/ws", refuse)
    if got != "//examples/mojo/ws/util/base:lib":
        refuse("a member below the package is not //<package>/<dir>:lib: {}".format(got))
    got = member_label("examples/mojo/ws", "util@0.1.0#mojo1.0.0/lib", "util", "util/src/util", "examples/mojo/ws", refuse)
    if got != "//examples/mojo/ws/util:lib":
        refuse("a member below the package is not //<package>/<dir>:lib: {}".format(got))

def sibling_is_named_by_its_directory(refuse = fail):
    """With paths from the repository root, a package next to this one is `//<its directory>:lib`, and so is one at the root itself."""
    got = member_label("src/codec", "json@1.0.0#mojo1.0.0/lib", "json", "src/json/src/json", "", refuse)
    if got != "//src/json:lib":
        refuse("a sibling is not named by its directory: {}".format(got))
    got = member_label("src/codec", "top@1.0.0#mojo1.0.0/lib", "top", "src/top", "", refuse)
    if got != "//:lib":
        refuse("a library at the repository root is not //:lib: {}".format(got))

def sibling_with_a_path_up_is_named_by_its_directory(refuse = fail):
    """A mopm that prints paths from the package may print a sibling as `../<dir>`: the same target as from the root."""
    got = member_label("src/codec", "json@1.0.0#mojo1.0.0/lib", "json", "../json/src/json", "src/codec", refuse)
    if got != "//src/json:lib":
        refuse("a sibling written with .. is not named by its directory: {}".format(got))

def workspace_is_flat_at_repository_paths(refuse = fail):
    """A package and the workspaces of its path dependencies are one map of repository paths: a dependency below the package and one next to it lie
    where the repository has them, with no nesting; a dependency two others import is once."""
    util = {"app/util/mopm.toml": "u", "app/util/base/mopm.toml": "b"}
    base_again = {"app/util/base/mopm.toml": "b"}
    sibling = {"lib/json/mopm.toml": "j", "lib/json/src/json/__init__.mojo": "jj"}
    got = workspace_tree("app", [("mopm.toml", "a"), ("src/app/__init__.mojo", "aa")], [util, base_again, sibling])
    want = {
        "app/mopm.toml": "a",
        "app/src/app/__init__.mojo": "aa",
        "app/util/mopm.toml": "u",
        "app/util/base/mopm.toml": "b",
        "lib/json/mopm.toml": "j",
        "lib/json/src/json/__init__.mojo": "jj",
    }
    if got != want:
        refuse("the workspace is not the files at their repository paths: {}".format(got))
    root = workspace_tree("", [("mopm.toml", "a")], [])
    if root != {"mopm.toml": "a"}:
        refuse("a package at the repository root is not staged at its own paths: {}".format(root))

def graph_paths_below_the_package(refuse = fail):
    """A path of the graph is below the package's directory: from the root it is that directory less its first part; from the package it already is."""
    if graph_path_in_package("src/codec/src/codec/x.mojo", "src/codec", True, refuse) != "src/codec/x.mojo":
        refuse("a path from the repository root is not made relative to the package")
    if graph_path_in_package("src/codec/x.mojo", "src/codec", False, refuse) != "src/codec/x.mojo":
        refuse("a path from the package is changed")
    if graph_path_in_package("tests/x.mojo", "", True, refuse) != "tests/x.mojo":
        refuse("a package at the repository root changes its paths")
