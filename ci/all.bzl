# What //ci:all covers, and what it deliberately does not. Read by ci/completeness.bxl, which fails when a target of the tree is neither
# built by //ci:all (or //ci:mojo) nor listed here. Every entry is a target pattern and the one-line reason it is not built.

# Targets that are red on purpose or are not built by a wildcard build. A key is a target expression and must match at least one target.
# Each package's scrub_files is not excluded: the scrub reads a fixture's text like any other file's.
EXCLUDED = {
    "//examples/p4ws/crates/probe_env/... - //examples/p4ws/crates/probe_env:scrub_files": "refusal fixture: the build script is refused by design (a hidden input through the environment)",
    "//examples/p4ws/crates/probe_tree/... - //examples/p4ws/crates/probe_tree:scrub_files": "refusal fixture: the build script is refused by design (it reads outside its declared tree)",
    "//examples/p4ws/crates/probe_usr/... - //examples/p4ws/crates/probe_usr:scrub_files": "refusal fixture: the build script is refused by design (it reads the host's /usr)",
    "//examples/mojo/reexport_unused:coverage + //examples/mojo/reexport_unused:test_ops__cov + //examples/mojo/reexport_unused:test_ops__cov_bin": "planted defect: ../reexport with a function in __init__.mojo that no test calls, so the Mojo report omits the file and it has a statement; `:coverage` must be red with \"is in no report\", which //ci:completeness.bxl:check builds and requires (ci/negative.bzl, COVERAGE_REDS)",
    "//examples/mojo/registry/cnative:coverage": "refusal fixture: a package with no test has no coverage to measure, and the rule refuses; //ci:completeness.bxl:check analyses it and requires the reason (ci/negative.bzl, CASES)",
    "//examples/mojo/registry/probe_sys:coverage": "refusal fixture: a package with no test has no coverage to measure (a `-sys` package: an empty module over a C library), and the rule refuses; //ci:completeness.bxl:check analyses it and requires the reason (ci/negative.bzl, CASES)",
    "//examples/mojo/registry/probe_sys/base_sys:coverage": "refusal fixture: a package with no test has no coverage to measure (a `-sys` package: an empty module over a C library), and the rule refuses; //ci:completeness.bxl:check analyses it and requires the reason (ci/negative.bzl, CASES)",
    "//ci/mojo_gate:test_fails + //ci/mojo_gate:lib_red + //ci/mojo_gate:consumer_of_red + //ci/mojo_gate:lib_red_first + //ci/mojo_gate:consumer_of_red_first": "the planted defect of the Mojo gate (ci/mojo_gate/BUCK): a library behind a failing test, and a target that reads it, red by design at build time; //ci:completeness.bxl:check builds the consumer, requires the failure, and requires //ci/mojo_gate:consumer_of_green (which //ci:all builds) to build (ci/negative.bzl, gate_problems)",
    "//ci/planted:run_check_of_other_stdout + //ci/planted:c_check_of_other_stdout + //ci/planted:mojo_same_of_other_bytes + //ci/planted:lib_a + //ci/planted:lib_b + //ci/planted:table_of_other_bytes + //ci/planted:rust_toolchain_of_other_version +//ci/planted:fails + //ci/planted:fails__bin + //ci/planted:lib_behind_a_failing_test +//ci/planted:mojo_test_that_fails + //ci/planted:mojo_test_exe + //ci/planted:mojo_toolchain + //ci/planted:zig_dist_of_other_bytes + //ci/planted:zig_dist_over_its_max_output + //ci/planted:zig_dist_of_a_corrupt_archive + //ci/planted:corrupt.tar.xz":"the planted defects of the checks and markers of the rules (ci/planted/BUCK): a comparison, a digest, a test, a copy or an unpacking that must fail, each red by design at build time; //ci:completeness.bxl:check builds each, requires the failure, and requires the control of each (built by //ci:all) to build (ci/negative.bzl, planted_problems)",
    "crates//crates/zdemo:coverage": "refusal: Rust coverage is not implemented, so the target is incompatible with every platform; a wildcard build skips it, and a target that depends on it is refused",
    "deps(//rules/pins:host_downloads, 2)": "about 1.1 GB of pinned downloads for the linux-aarch64 and macos-aarch64 hosts (rules/pins/hosts.bzl): the host_arm job of ci.yml builds them on an aarch64 runner, and a run on the farm checks every sha256 and size; the x86 runner does not fetch them on every pull request",
    "//ci/negative:v3_test_without_isa_property + //ci/negative:v3_test_with_isa_property": "the planted defect, red by design on the one platform it is compatible with, and its control, which is valid there; a wildcard build skips both as incompatible. //ci:completeness.bxl:check analyses them (ci/negative.bzl), and //ci/negative:negative_check, which //ci:all builds, holds their files to each other",
    "//ci/negative:cross_exe_with_other_tests": "the planted defect of the cross-built program that waits for other tests than its original (comment in ci/negative/BUCK), red by design in analysis on the one platform it is compatible with; a wildcard build skips it as incompatible",
    "//ci/negative:zig_exe_with_a_dep_of_the_wrong_kind + //ci/negative:cxx_library_gated_by_the_wrong_kind + //ci/negative:npm_tarball_with_a_dep_of_the_wrong_kind + //ci/negative:zig_coverage_of_no_test": "planted defects (comments in ci/negative/BUCK): a dependency of the wrong kind, and coverage of no test, each red by design in analysis on the one platform it is compatible with; a wildcard build skips them as incompatible. //ci:completeness.bxl:check analyses each and requires its reason (ci/negative.bzl, CASES)",
}

# Built by //ci:mojo and not by //ci:all: the public runner has no mirror for the Mojo packages (docs/contract.md, section 14). Their
# coverage is checked against //ci:mojo instead.
MIRROR_ONLY = "//ci:mojo"

# Rule kinds that describe a configuration and build nothing.
NOT_BUILT_KINDS = "constraint_setting|constraint_value|config_setting|platform|_exec_platforms"

# Directories that are in no Buck2 graph of this repository on purpose, with the reason. A key is a path; beta/check.zig (`//beta:beta_check`) requires
# the line for `beta/`, and checks that nothing under it is named BUCK, so the directory is not packages of this graph.
OUTSIDE_THE_GRAPH = {
    "beta/": "user-style hello-world repositories, each a standalone layout that consumes buildrules as an external cell at the candidate commit. The beta job of the release (RELEASING.md) copies one out of the checkout and builds it with `buildrules` and buck2 as a user would; built here they would be packages of this graph, loaded with a cell they do not declare. Their BUCK files are kept as BUCK.beta.",
}
