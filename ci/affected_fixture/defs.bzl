"""The macro of the selector's fixture (ci/affected_fixture/BUCK): a `group` under another name, so that BUCK loads a .bzl and the
reverse build-file query of the selector has a loader to find."""

load("//rules:matrix.bzl", "group")
load(":inner.bzl", "VISIBILITY")

def fixture_check(name, deps):
    group(name = name, deps = deps, visibility = VISIBILITY)
