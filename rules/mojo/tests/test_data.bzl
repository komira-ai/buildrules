"""What `mojo_package(test_data = ..., test_env = ...)` stages for each test (rules/mojo/test_data.bzl): the checks of rules/mojo/tests/BUCK.

A check takes the way to refuse as an argument (rules/rust/refusal.bzl) and refuses with what is wrong, so a test target is green only if nothing was.
"""

load("//rules/mojo:test_data.bzl", "stage_test_data")

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
