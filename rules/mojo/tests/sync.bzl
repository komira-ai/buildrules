"""Checks of `mojo_sync` (rules/mojo/sync.bzl) that need no action: which directories it syncs and what it stages. Each takes `refuse`, as the checks of siblings.bzl do."""

load("//rules/mojo:sync.bzl", "sync_packages", "sync_stage_tree")

def packages_are_normalized(refuse = fail):
    """A package is named as a directory below the root, however it is spelled; the root itself is the empty string."""
    got = sync_packages(["examples/mojo/a", "./examples//mojo/b/", "."], refuse)
    if got != ["examples/mojo/a", "examples/mojo/b", ""]:
        refuse("the packages are not normalized: {}".format(got))

def stage_holds_the_workspaces_and_the_other_files_once(refuse = fail):
    """The staged repository is the workspaces of the packages and the other inputs, each at its repository path; a file two workspaces hold is one entry."""
    got = sync_stage_tree(
        [{"a/mopm.toml": "a", "c/mopm.toml": "c"}, {"b/mopm.toml": "b", "c/mopm.toml": "c"}],
        {"ex/mopm-toolchain.toml": "t", "c/mopm.toml": "c"},
        refuse,
    )
    want = {"a/mopm.toml": "a", "b/mopm.toml": "b", "c/mopm.toml": "c", "ex/mopm-toolchain.toml": "t"}
    if got != want:
        refuse("the staged repository is not the workspaces and the files at their paths: {}".format(got))
