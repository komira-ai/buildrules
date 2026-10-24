"""The analysis tests of `mojo_package(test_data = ..., test_env = ...)` (rules/mojo/test_data.bzl), as targets; rules/mojo/tests/BUCK calls `test_data_targets`.

Each target is green only if the arguments were refused with the reason stated (rules/rust/refusal.bzl), so a refusal that is removed stops the target from
existing (analysis fails: "expected a refusal"). `:test_data` is the group of them. What a test is given and what it does with it at run time is held by
ci/mojo_data (a stand-in for the compiler) and examples/mojo/testdata (the real thing).
"""

load("//rules/mojo:defs.bzl", "stage_package_test_data")
load("//rules/mojo:test_data.bzl", "check_installed_tree", "check_test_env", "check_test_layout", "stage_test_data")
load("//rules/mojo:unit.bzl", "mojo_group")
load("//rules/rust:refusal.bzl", "accepts", "recording", "refusal_test", "refuses")
load(":test_data.bzl", "HELD", "TESTS", "a_path_next_to_the_coverage_tree_is_not_in_it", "no_data_is_no_staging", "staging_is_per_test_and_star_is_all")

_R = "examples/x"

# (name, test_data, what the refusal says)
_STAGE = [
    # A key that is no test: a mistyped path would stage nothing and the test would fail with a missing file, far from the cause.
    ("test_data_for_no_such_test_is_refused", {"tests/test_typo.mojo": {"a.txt": "a.txt"}}, ["examples/x: test_data[\"tests/test_typo.mojo\"]: names no test of the package", "tests/test_a.mojo, tests/test_b.mojo"]),
    # A path that leaves the test's directory, or is not a file path.
    ("test_data_with_an_absolute_path_is_refused", {"*": {"/etc/passwd": "x"}}, ["data destination \"/etc/passwd\" must be a relative file path"]),
    ("test_data_with_a_path_leaving_the_directory_is_refused", {"*": {"../escape.txt": "x"}}, ["data destination \"../escape.txt\" holds an empty, `.` or `..` segment"]),
    ("test_data_with_a_dotdot_in_the_middle_is_refused", {"tests/test_a.mojo": {"a/../../b": "x"}}, ["holds an empty, `.` or `..` segment"]),
    ("test_data_with_an_empty_path_is_refused", {"*": {"": "x"}}, ["must be a relative file path"]),
    ("test_data_with_a_directory_path_is_refused", {"*": {"dir/": "x"}}, ["must be a relative file path"]),
    # One path with two sources.
    ("test_data_staged_twice_by_star_and_the_test_is_refused", {"*": {"a.txt": "x"}, "tests/test_b.mojo": {"a.txt": "y"}}, ["\"a.txt\" is staged twice for tests/test_b.mojo (\"x\" and \"y\")", "one path has one source"]),
    ("test_data_file_and_directory_across_keys_is_refused", {"*": {"a": "x"}, "tests/test_b.mojo": {"a/b": "y"}}, ["data destination \"a\" is both a file and the directory of \"a/b\""]),
    # The coverage run's tree holds the test's source and the library's sources.
    ("test_data_on_the_coverage_trees_test_source_is_refused", {"*": {"tests/test_a.mojo": "x"}}, ["stages \"tests/test_a.mojo\" for tests/test_a.mojo", "coverage run (:coverage) already holds"]),
    ("test_data_over_a_library_source_is_refused", {"*": {"pkg/io/reader.mojo": "x"}}, ["already holds \"pkg/io/reader.mojo\""]),
    ("test_data_over_the_library_directory_is_refused", {"tests/test_b.mojo": {"pkg": "x"}}, ["stages \"pkg\" for tests/test_b.mojo", "already holds \"pkg/__init__.mojo\""]),
    ("test_data_under_a_library_source_is_refused", {"*": {"pkg/__init__.mojo/x": "x"}}, ["already holds \"pkg/__init__.mojo\""]),
    # The shape.
    ("test_data_value_that_is_not_a_string_is_refused", {"*": {"a.txt": 5}}, ["\"a.txt\" must be a label or a file name (a string), not int"]),
    ("test_data_that_is_not_a_dict_is_refused", ["a.txt"], ["test_data must be a dict"]),
    ("test_data_of_a_test_that_is_not_a_dict_is_refused", {"*": ["a.txt"]}, ["test_data[\"*\"] must be a dict {staged path: label or file}, not list"]),
]

# A package below the repository root with a rooted graph: the test is `tests/test_a.mojo` to the package and `examples/x/tests/test_a.mojo` in the graph, and
# the tree of its coverage run holds it at the graph's name (rules/mojo/defs.bzl, `stage_package_test_data`).
_ROOTED_TESTS = {"tests/test_a.mojo": "examples/x/tests/test_a.mojo"}
_ROOTED_LIB = ["pkg/__init__.mojo"]

# (name, test_data, what the refusal says)
_ROOTED = [
    ("rooted_test_data_on_the_graphs_test_path_is_refused", {"tests/test_a.mojo": {"examples/x/tests/test_a.mojo": "x"}}, ["stages \"examples/x/tests/test_a.mojo\" for tests/test_a.mojo", "already holds \"examples/x/tests/test_a.mojo\""]),
    ("rooted_test_data_over_a_library_source_is_refused", {"*": {"pkg/__init__.mojo": "x"}}, ["already holds \"pkg/__init__.mojo\""]),
]

# (name, test_data): accepted, and with the same package-relative name the test has to the package: the tree holds the test at the graph's name only.
_ROOTED_ACCEPTED = [
    ("rooted_test_data_at_the_packages_test_name_is_accepted", {"tests/test_a.mojo": {"tests/test_a.mojo": "x"}}),
]

# (name, test_env, what the refusal says): the runner's own variables, and the ones these rules set.
_ENV = [
    ("test_env_path_is_refused", {"PATH": "/x"}, ["test_env sets PATH, which the test runner sets itself"]),
    ("test_env_ld_library_path_is_refused", {"LD_LIBRARY_PATH": "/x"}, ["test_env sets LD_LIBRARY_PATH"]),
    ("test_env_tmpdir_is_refused", {"TMPDIR": "/x"}, ["test_env sets TMPDIR"]),
    ("test_env_data_directory_is_refused", {"BUILDRULES_TEST_DATA": "/x"}, ["test_env sets BUILDRULES_TEST_DATA", "runner-owned"]),
    ("test_env_unit_nonce_is_refused", {"BUILDRULES_UNIT_NONCE": "1"}, ["test_env sets BUILDRULES_UNIT_NONCE"]),
    ("test_env_scratch_path_is_refused", {"BUCK_SCRATCH_PATH": "/x"}, ["test_env sets BUCK_SCRATCH_PATH"]),
    ("test_env_name_with_a_dash_is_refused", {"MY-VAR": "1"}, ["test_env name \"MY-VAR\" is not a shell variable name"]),
    ("test_env_name_with_an_equals_sign_is_refused", {"A=B": "1"}, ["is not a shell variable name"]),
    ("test_env_value_that_is_not_a_string_is_refused", {"N": 5}, ["test_env N must be a string, not int"]),
    ("test_env_that_is_not_a_dict_is_refused", ["A=1"], ["test_env must be a dict"]),
]

# (name, test_layout, what the refusal says): the layouts a test is run in are `default` and `installed`, and nothing else.
_LAYOUT = [
    ("test_layout_unknown_value_is_refused", "installd", ["examples/x: test_layout \"installd\" is not one of default, installed"]),
    ("test_layout_empty_is_refused", "", ["test_layout \"\" is not one of default, installed"]),
    ("test_layout_uppercase_is_refused", "Installed", ["test_layout \"Installed\" is not one of default, installed"]),
    ("test_layout_that_is_not_a_string_is_refused", True, ["test_layout True is not one of default, installed"]),
]

# (name, sources of the coverage root, what the refusal says): the installed layout keeps `bin/` and `share/` for the binary and the data.
_INSTALLED_TREE = [
    ("installed_source_in_bin_is_refused", ["tests/test_a.mojo", "bin/tool.mojo"], ["the source bin/tool.mojo is in bin/"]),
    ("installed_source_in_share_is_refused", ["share/deep/x.mojo", "pkg/__init__.mojo"], ["the source share/deep/x.mojo is in share/", "would merge them"]),
    ("installed_library_named_share_is_refused", ["share/__init__.mojo"], ["is in share/"]),
]

# (name, the check): green only if it refused nothing.
_CHECKS = [
    ("test_data_staging_is_per_test_and_star_is_all", staging_is_per_test_and_star_is_all),
    ("test_data_absent_stages_nothing", no_data_is_no_staging),
    ("test_data_beside_the_coverage_tree_is_accepted", a_path_next_to_the_coverage_tree_is_not_in_it),
]

def _check_target(name, check):
    refusals, refuse = recording()
    check(refuse)
    refusal_test(name = name, refusals = refusals, none = True, visibility = ["PUBLIC"])
    return ":" + name

def test_data_targets():
    targets = [_check_target(name, check) for name, check in _CHECKS]
    targets.append(accepts(name = "test_env_names_and_values_are_accepted", check = check_test_env, args = [_R, {"MODE": "strict", "_x2": "y", "EMPTY": ""}]))
    targets += [refuses(name = n, check = stage_test_data, args = [_R, TESTS, d, HELD], contains = c) for n, d, c in _STAGE]
    targets += [refuses(name = n, check = stage_package_test_data, args = [_R, _ROOTED_TESTS, _ROOTED_LIB, d, False], contains = c) for n, d, c in _ROOTED]
    targets += [accepts(name = n, check = stage_package_test_data, args = [_R, _ROOTED_TESTS, _ROOTED_LIB, d, False]) for n, d in _ROOTED_ACCEPTED]
    # The installed layout stages the data apart from the sources: the graph's test path and a library source are accepted there, and the other rules hold.
    targets.append(accepts(name = "installed_test_data_on_the_test_and_library_paths_is_accepted", check = stage_package_test_data, args = [_R, _ROOTED_TESTS, _ROOTED_LIB, {"*": {"examples/x/tests/test_a.mojo": "x", "pkg/__init__.mojo": "y"}}, True]))
    targets.append(refuses(name = "installed_test_data_leaving_the_directory_is_refused", check = stage_package_test_data, args = [_R, _ROOTED_TESTS, _ROOTED_LIB, {"*": {"../escape.txt": "x"}}, True], contains = ["data destination \"../escape.txt\" holds an empty, `.` or `..` segment"]))
    targets += [refuses(name = n, check = check_test_env, args = [_R, e], contains = c) for n, e, c in _ENV]
    targets += [refuses(name = n, check = check_test_layout, args = [_R, l], contains = c) for n, l, c in _LAYOUT]
    targets += [refuses(name = n, check = check_installed_tree, args = [_R, s], contains = c) for n, s, c in _INSTALLED_TREE]
    targets.append(accepts(name = "test_layout_default_is_accepted", check = check_test_layout, args = [_R, "default"]))
    targets.append(accepts(name = "test_layout_installed_is_accepted", check = check_test_layout, args = [_R, "installed"]))
    # `bin2/` and `shared/` only start with the reserved names, and a file may be named for them below the first directory.
    targets.append(accepts(name = "installed_sources_beside_the_reserved_names_are_accepted", check = check_installed_tree, args = [_R, ["tests/bin/x.mojo", "bin2/x.mojo", "shared/x.mojo", "pkg/share/y.mojo"]]))
    mojo_group(name = "test_data", deps = targets, visibility = ["PUBLIC"])
