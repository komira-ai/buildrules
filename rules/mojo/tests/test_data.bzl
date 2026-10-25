"""What `mojo_package(test_data = ..., test_env = ...)` stages for each test (rules/mojo/test_data.bzl): the checks of rules/mojo/tests/BUCK.

A check takes the way to refuse as an argument (rules/rust/refusal.bzl) and refuses with what is wrong, so a test target is green only if nothing was.
"""

load("//rules/mojo:test_data.bzl", "check_test_defines", "stage_test_data")

TESTS = ["tests/test_a.mojo", "tests/test_b.mojo"]

# What the coverage run's tree holds for each test: the test's source and the library's sources.
HELD = {t: [t, "pkg/__init__.mojo", "pkg/io/reader.mojo"] for t in TESTS}

def staging_is_per_test_and_star_is_all(refuse = fail):
    """`*` is every test; a test's own entries are added to it, and only to it."""
    got = stage_test_data("examples/x", TESTS, {
        "*": {"spec/parquet.thrift": "//third_party:parquet.thrift"},
        "tests/test_b.mojo": {"bin/tool": "//tools:tool", "golden/out.txt": "golden/out.txt"},
    }, HELD, refuse)
    if got["tests/test_a.mojo"] != {"spec/parquet.thrift": "//third_party:parquet.thrift"}:
        refuse("test_a is given exactly what `*` stages: {}".format(got["tests/test_a.mojo"]))
    want_b = {"spec/parquet.thrift": "//third_party:parquet.thrift", "bin/tool": "//tools:tool", "golden/out.txt": "golden/out.txt"}
    if got["tests/test_b.mojo"] != want_b:
        refuse("test_b is given what `*` stages and its own: {}".format(got["tests/test_b.mojo"]))

def no_data_is_no_staging(refuse = fail):
    """A package without `test_data` stages nothing for any test."""
    got = stage_test_data("examples/x", TESTS, {}, HELD, refuse)
    if got != {"tests/test_a.mojo": {}, "tests/test_b.mojo": {}}:
        refuse("no test_data, no staging: {}".format(got))

def a_path_next_to_the_coverage_tree_is_not_in_it(refuse = fail):
    """`pkg_data/x` shares a prefix with `pkg/` and `tests/test_a.mojo.golden` with a test source, and neither is inside the other."""
    got = stage_test_data("examples/x", TESTS, {"*": {"pkg_data/x.txt": "x.txt", "tests/test_a.mojo.golden": "g"}}, HELD, refuse)
    if len(got["tests/test_a.mojo"]) != 2:
        refuse("both paths are staged: {}".format(got))

def defines_become_dash_d_pairs_in_name_order(refuse = fail):
    """Each define is `-D NAME=value`, in the order of the names whatever the order they were written in; a bool is `true` or `false`, an int its digits, and a value that holds `=` is kept whole."""
    got = check_test_defines("examples/x", {"ZED": "1", "ALPHA": True, "OFF": False, "LEVEL": 3, "TAG": "a=b", "_Under9": "x"}, refuse)
    want = ["-D", "ALPHA=true", "-D", "LEVEL=3", "-D", "OFF=false", "-D", "TAG=a=b", "-D", "ZED=1", "-D", "_Under9=x"]
    if got != want:
        refuse("the defines are {}, wanted {}".format(got, want))

def no_defines_no_arguments(refuse = fail):
    """A package without `test_defines` adds nothing to the compiler's command line."""
    got = check_test_defines("examples/x", {}, refuse)
    if got != []:
        refuse("no defines, no arguments: {}".format(got))

def a_refused_define_leaves_no_arguments(refuse = fail):
    """One bad entry among good ones: the package does not load (`fail`); where a refusal is only recorded, nothing half-valid is returned."""
    recorded = []
    got = check_test_defines("examples/x", {"GOOD": "1", "bad-name": "2"}, lambda m: recorded.append(m))
    if got != [] or len(recorded) != 1:
        refuse("one refusal and no arguments expected, got {} and {}".format(recorded, got))
