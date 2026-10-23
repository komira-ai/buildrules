"""The analysis tests of `mojo_package(test_data = ..., test_env = ...)` (rules/mojo/test_data.bzl), as targets; rules/mojo/tests/BUCK calls `test_data_targets`.

Each target is green only if the arguments were refused with the reason stated (rules/rust/refusal.bzl), so a refusal that is removed stops the target from
existing (analysis fails: "expected a refusal"). `:test_data` is the group of them. What a test is given and what it does with it at run time is held by
ci/mojo_data (a stand-in for the compiler) and examples/mojo/testdata (the real thing).
"""

load("//rules/mojo:test_data.bzl", "check_test_env", "stage_test_data")
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
    targets += [refuses(name = n, check = check_test_env, args = [_R, e], contains = c) for n, e, c in _ENV]
    mojo_group(name = "test_data", deps = targets, visibility = ["PUBLIC"])
