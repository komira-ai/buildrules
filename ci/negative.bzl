"""The planted defects of ci/negative must stay red (and the Mojo gate, `gate_problems`, below): what the check holds them to (ci/negative.bxl, and ci/completeness.bxl, which the public CI runs).

A wildcard build skips the fixture (it is compatible only with the platform it breaks on), so nothing else notices if it turns green. `negative_problems`
analyses it on that platform and reports every way it is not red for the reason it plants. The control (`v3_test_with_isa_property`: the same test run with
the one line the fixture leaves out) must analyse on the same platform, so the fixture is known to be red for that line and not for some other reason.
Make the fixture valid (give it `exec_compatible_with = test_exec_compatible_with()`) and the check reports "analysed"; break the control and it reports the
control's own error. ci/negative_check.zig holds the wiring of this file to the fixtures, in //ci:all.
"""

load("//examples/mojo/sys_app:buildrules.mojo.lock.bzl", SYS_APP_GRAPH = "GRAPH")
load("//examples/mojo/ws:buildrules.mojo.lock.bzl", WS_GRAPH = "GRAPH")

PLATFORM = "buildrules//platforms:linux_x86_64_v3"
FIXTURE = "//ci/negative:v3_test_without_isa_property"
CONTROL = "//ci/negative:v3_test_with_isa_property"

# What the rule says when a test built for x86-64-v3 is given an execution platform that lacks it (rules/rust/test_run.bzl).
REASON = "built for ISA x86-64-v3 but its execution platform reports ISA="

# More fixtures that must stay red, each for the reason it plants: (label, platform it is analysed on, text the failure must hold). The ci/negative ones are
# compatible only with the platform they are analysed on (so a wildcard build skips them, and ci/all.bzl lists them in EXCLUDED); ci/negative_check.zig holds the names
# to ci/negative/BUCK and ci/all.bzl. The reasons are Buck2's own words for a dependency of the wrong kind, and the rules' for the rest (rules/zig/checks.bzl,
# rules/coverage/checks.bzl, rules/mojo/unit.bzl).
CASES = [
    ("//ci/negative:zig_exe_with_a_dep_of_the_wrong_kind", PLATFORM, "Attribute requires a dep that provides `ZigModuleInfo`"),
    ("//ci/negative:cxx_library_gated_by_the_wrong_kind", PLATFORM, "Attribute requires a dep that provides `ValidationInfo`"),
    ("//ci/negative:npm_tarball_with_a_dep_of_the_wrong_kind", PLATFORM, "Attribute requires a dep that provides `NpmPackageInfo`"),
    ("//ci/negative:zig_coverage_of_no_test", PLATFORM, "test_targets is empty: a package with no test has no coverage to measure"),
    ("//ci/negative:cross_exe_with_other_tests", PLATFORM, "waits for the unit tests"),
    ("//ci/negative:mojo_instrumented_link_without_a_native_the_unit_links", PLATFORM, "the unit links the native library libbase_sys.a and the instrumented link of its branch coverage is not given it"),
    ("//ci/negative:mojo_instrumented_link_with_a_needed_archive_before_its_user", PLATFORM, "libbase_sys.a is linked before libprobe_sys.a, which needs it"),
    ("//examples/mojo/registry/cnative:coverage", "buildrules//platforms:linux_x86_64", "this package has no test, so there is no coverage to measure"),
    ("//examples/mojo/registry/probe_sys:coverage", "buildrules//platforms:linux_x86_64", "this package has no test, so there is no coverage to measure"),
    ("//examples/mojo/registry/probe_sys/base_sys:coverage", "buildrules//platforms:linux_x86_64", "this package has no test, so there is no coverage to measure"),
    # A sibling whose table names another version of the library than the one next to it is (rules/mojo/unit.bzl, `check_closure_ids`).
    ("//examples/mojo/sibfake/stale:lib_ungated", "buildrules//platforms:linux_x86_64", "the graph imports base as base@0.2.0#mojo1.0.0/lib but the dependency target provides base@0.1.0#mojo1.0.0/lib"),
]

def _analyse(ctx, label, platform = PLATFORM):
    node = ctx.configured_targets(label, target_platform = platform)
    return ctx.lazy.analysis(node).catch().resolve()

def negative_problems(ctx):
    """Every way the planted defect is not red for its reason, or its control does not analyse: a list of strings, empty when all is as planted."""
    problems = []

    planted = _analyse(ctx, FIXTURE)
    if planted.is_ok():
        problems.append("{} analysed on {}: the planted defect is no longer red".format(FIXTURE, PLATFORM))
    else:
        why = str(planted.unwrap_err())
        if REASON not in why:
            problems.append("{} is red on {}, but not for the reason it plants (expected \"{}\"): {}".format(FIXTURE, PLATFORM, REASON, why))

    control = _analyse(ctx, CONTROL)
    if not control.is_ok():
        problems.append("{} (the control) does not analyse on {}: {}".format(CONTROL, PLATFORM, str(control.unwrap_err())))

    for label, platform, reason in CASES:
        got = _analyse(ctx, label, platform)
        if got.is_ok():
            problems.append("{} analysed on {}: the planted defect is no longer red".format(label, platform))
        elif reason not in str(got.unwrap_err()):
            problems.append("{} is red on {}, but not for the reason it plants (expected \"{}\"): {}".format(label, platform, reason, str(got.unwrap_err())))
    return problems + gate_problems(ctx) + planted_problems(ctx) + coverage_red_problems(ctx) + coverage_floor_wiring_problems(ctx) + coverage_branch_wiring_problems(ctx) + native_link_problems(ctx)

# Coverage fixtures that fail when their actions run, not at analysis (so CASES cannot hold them): built here, each must FAIL and say why. The partner
# that is green is //examples/mojo/reexport:coverage, built by //ci:mojo: the same package with a __init__.mojo that only re-exports.
COVERAGE_REDS = [
    ("//examples/mojo/reexport_unused:coverage", "is in no report: no test compiled it, or kcov could not open it"),
    ("//examples/mojo/coverage_floors:floor_above_the_coverage", "line coverage is 60.00% (3/5), below its floor 70.00%: coverage fell"),
    ("//examples/mojo/coverage_floors:branches_floor_above_the_coverage", "branch coverage is 50.00% (1/2), below its floor 60.00%: coverage fell"),
    ("//examples/mojo/coverage_floors:floor_without_branches", "the tests record branches (1/2) and the floor file has no `branches` figure: add `branches 50.00`"),
    ("//examples/mojo/coverage_floors:branches_floor_on_no_decisions", "the floor file has a `branches` figure and the coverage has no branches to hold"),
]

def coverage_red_problems(ctx):
    """Every way a coverage fixture is not red for its reason: a list of strings, empty when all is as planted."""
    problems = []
    for label, reason in COVERAGE_REDS:
        built, failed = _built_with_why(ctx, label)
        if not failed:
            problems.append("{} built ({} artifact(s)): the planted defect is no longer red".format(label, built))
        elif reason not in failed:
            problems.append("{} is red, but not for the reason it plants (expected \"{}\"): {}".format(label, reason, failed))
    return problems

# A package has a `:coverage_floor` exactly when it has a coverage_floor.txt beside its BUCK file (rules/mojo/defs.bzl): a package without one has the targets it
# had before floors existed. (package, whether it has a floor file)
COVERAGE_FLOOR_PACKAGES = [
    ("//examples/mojo/partial", True),
    ("//examples/mojo/reexport", True),
    ("//examples/mojo/testdata", True),
    ("//examples/mojo/branch_shapes", True),
    ("//examples/mojo/reexport_unused", False),
    ("//examples/mojo/copy_of_base", False),
    ("//examples/mojo/sys_app", True),
    ("//examples/mojo/ws", False),
    ("//examples/mojo/ws/util", False),
    ("//examples/mojo/ws/util/base", False),
]

def coverage_floor_wiring_problems(ctx):
    """Every package that has (or lacks) a `:coverage_floor` against its coverage_floor.txt: a list of strings, empty when all agree."""
    problems = []
    q = ctx.uquery()
    for package, has_floor_file in COVERAGE_FLOOR_PACKAGES:
        names = [t.label.name for t in q.eval(package + ":")]
        if "coverage" not in names:
            problems.append("{} has no :coverage: the floor check has nothing to hold there".format(package))
        elif has_floor_file and "coverage_floor" not in names:
            problems.append("{} has a coverage_floor.txt and no :coverage_floor: its floor is read by nothing".format(package))
        elif not has_floor_file and "coverage_floor" in names:
            problems.append("{} has a :coverage_floor and no coverage_floor.txt: a package without a floor must be as it was".format(package))
    return problems

# A package whose tests run in the default layout has the five branch coverage actions of each test, and its `:coverage` waits for the last: also a package whose tests link native
# libraries (`ws`: a shared object; `sys_app`: two static archives), because the instrumented link is given them as the ordinary link is (rules/mojo/defs.bzl,
# rules/coverage/branch/README.md). One whose tests run in the installed layout has none of them (the branch run has no installed layout), so its `coverage.txt` has no `branches` rows
# and a floor may not hold a `branches` figure. (package, the stem of its test, whether it is instrumented)
BRANCH_PACKAGES = [
    ("//examples/mojo/partial", "test_partial", True),
    ("//examples/mojo/reexport", "test_ops", True),
    ("//examples/mojo/copy_of_base", "test_base", True),
    ("//examples/mojo/ws/util", "test_util", True),
    ("//examples/mojo/ws/util/base", "test_base", True),
    ("//examples/mojo/testdata", "test_data_files", True),
    ("//examples/mojo/branch_shapes", "test_branch_shapes", True),
    ("//examples/mojo/sibfake/app", "test_util", True),
    ("//examples/mojo/sibfake/base", "test_base", True),
    ("//examples/mojo/ws", "test_app", True),
    ("//examples/mojo/sys_app", "test_sys_app", True),
    ("//examples/mojo/installed", "test_installed_layout", False),
]

# The packages whose tests link native libraries, with their committed graphs: what `__pgo` is held to (`native_link_problems`).
NATIVE_PACKAGES = [
    ("//examples/mojo/sys_app", "test_sys_app", SYS_APP_GRAPH),
    ("//examples/mojo/ws", "test_app", WS_GRAPH),
]

def coverage_branch_wiring_problems(ctx):
    """Every example package against the branch coverage targets of its test: a list of strings, empty when all are there and `:coverage` waits for them."""
    problems = []
    q = ctx.uquery()
    for package, stem, instrumented in BRANCH_PACKAGES:
        names = [t.label.name for t in q.eval(package + ":")]
        mine = [stem + "__" + step for step in ["bc", "pgo", "profdata", "ir", "info"]]
        have = [n for n in mine if n in names]
        waits = (stem + "__info") in [t.label.name for t in q.eval("deps({}:coverage, 1)".format(package))]
        if instrumented and (len(have) != len(mine) or not waits):
            problems.append("{} has {} of the {} branch coverage targets of {} and its :coverage {} wait for {}__info: its branch figure is not made".format(package, len(have), len(mine), stem, "does" if waits else "does not", stem))
        elif not instrumented and (have or waits):
            problems.append("{} runs its tests in the installed layout and has branch coverage targets ({}): its tests are not instrumented, so it must have none".format(package, ", ".join(have) if have else stem + "__info is a dependency of :coverage"))
    return problems

def _test_natives(graph):
    """(soname list in the graph's order, soname -> what it needs) of the test unit of a package's committed graph."""
    for u in graph["units"]:
        if u["kind"] == "test":
            return [n["soname"] for n in u["natives"]], {n["soname"]: n["needs"] for n in u["natives"] if n.get("needs")}
    return [], {}

def native_link_problems(ctx):
    """Every way the instrumented link of a package whose tests link native libraries is not given the graph's natives: a list of strings, empty when it is.
    `mojo_package` must hand `__pgo` the graph's list and each library's `needs` (the order check reads them), and the action must pass the libraries to
    `cov_branch link` as `--native` flags in the graph's order, which is the order of the ordinary link."""
    problems = []
    for package, stem, graph in NATIVE_PACKAGES:
        label = "{}:{}__pgo".format(package, stem)
        want, want_needs = _test_natives(graph)
        node = ctx.configured_targets(label, target_platform = GATE_PLATFORM)
        attrs = node.attrs_eager()
        got = list(attrs.native_sonames.value())
        if got != want:
            problems.append("{}: native_sonames is {}, the graph's natives of the test are {}".format(label, got, want))
        got_needs = {k: list(v) for k, v in attrs.native_needs.value().items()}
        if got_needs != want_needs:
            problems.append("{}: native_needs is {}, the graph's `needs` are {}: the order check has nothing to hold".format(label, got_needs, want_needs))
        emitted = []
        for action in ctx.aquery().all_actions(node):
            # The command prints as `[arg, arg, ...]`; an action that runs no command has none.
            if not hasattr(action.attrs, "cmd"):
                continue
            cmd = str(action.attrs.cmd).lstrip("[").rstrip("]").split(", ")
            emitted += [cmd[i + 1].split("/")[-1] for i in range(len(cmd) - 1) if cmd[i] == "--native"]
        if emitted != want:
            problems.append("{}: the link action passes --native {} in this order, the graph's order is {}".format(label, emitted, want))
        if not want:
            problems.append("{}: the graph's test links no native library, so there is nothing to hold here".format(label))
    return problems

def _built_with_why(ctx, label):
    """(artifacts built, the failures of building `label` on GATE_PLATFORM as one string, empty when none)."""
    built = 0
    why = ""
    for _, result in ctx.build(label, target_platform = GATE_PLATFORM).items():
        ok = result.artifacts()
        bad = result.failures()
        built += len(list(ok)) if ok else 0
        for failure in (list(bad) if bad else []):
            why += str(failure)
    return built, why

# The gate of a Mojo library (docs/contract.md, 12.8): a library's public `.mojoc` exists only if every test of its package passed. Two things are held.
#
#   behaviour  //ci/mojo_gate:consumer_of_red (and consumer_of_red_first, the failing test listed first) reads a library that waits for a failing test run, and must FAIL to build; the same library behind
#              a passing run, //ci/mojo_gate:consumer_of_green, must build. The two are one rule (`mojo_gated_lib_rule`) and one consumer; they differ
#              by the failing test, so the red is that test's. They use a stand-in for the compiler, so this needs no Mojo toolchain.
#   wiring     the real packages' `:lib` (made by `mojo_package`) has every test run of its package among its dependencies, so the rule above is
#              what guards a real library and not only the fixture.
GATE_PLATFORM = "buildrules//platforms:linux_x86_64"
GATE_GREEN = "//ci/mojo_gate:consumer_of_green"
GATE_REDS = ["//ci/mojo_gate:consumer_of_red", "//ci/mojo_gate:consumer_of_red_first"]  # the failing test last, and first (every marker must be an input)
# The cross-package edge: a package's `:lib_ungated` reads its dependencies' gated `:lib`, never their `:lib_ungated` (which would bypass their tests).
GATE_EDGES = [
    ("//examples/mojo/ws", "//examples/mojo/ws/util"),
    ("//examples/mojo/ws/util", "//examples/mojo/ws/util/base"),
    ("//examples/mojo/sibfake/app", "//examples/mojo/sibfake/base"),
]
GATE_PACKAGES = [
    "//examples/mojo/copy_of_base",
    "//examples/mojo/sibfake/app",
    "//examples/mojo/sibfake/base",
    "//examples/mojo/ws",
    "//examples/mojo/ws/util",
    "//examples/mojo/ws/util/base",
    "//examples/mojo/sys_app",
]

def _built(ctx, label):
    """(artifacts built, artifacts that failed) of building `label` on GATE_PLATFORM."""
    built = 0
    failed = 0
    for _, result in ctx.build(label, target_platform = GATE_PLATFORM).items():
        ok = result.artifacts()
        bad = result.failures()
        built += len(list(ok)) if ok else 0
        failed += len(list(bad)) if bad else 0
    return built, failed

def gate_problems(ctx):
    """Every way the Mojo gate is not held: a list of strings, empty when all is as planted."""
    problems = []
    built, failed = _built(ctx, GATE_GREEN)
    if failed or not built:
        problems.append("{} (the library behind a passing test) must build, and it built {} artifact(s) and failed {}".format(GATE_GREEN, built, failed))
    for red in GATE_REDS:
        built, failed = _built(ctx, red)
        if not failed:
            problems.append("{} built ({} artifact(s)): a library behind a failing test is usable, the gate is gone".format(red, built))

    q = ctx.uquery()
    for package in GATE_PACKAGES:
        want = sorted([str(t.label) for t in q.eval("kind('mojo_test_run_rule', {}:)".format(package))])
        if not want:
            problems.append("{} has no test run: the gate check has nothing to hold there".format(package))
            continue
        lib = package + ":lib"
        have = [str(t.label) for t in q.eval("deps({})".format(lib))]
        for test in want:
            if test not in have:
                problems.append("{} does not wait for {}: a failing test would not stop the library".format(lib, test))
        ungated = [str(x.label) for x in q.eval("deps({}:lib_ungated)".format(package))]
        if [t for t in want if t in ungated]:
            problems.append("{}:lib_ungated waits for a test: the tests import it, so that is a cycle in waiting".format(package))
    for user, dep in GATE_EDGES:
        direct = [str(x.label).split("//", 1)[-1] for x in q.eval("deps({}:lib_ungated, 1)".format(user))]
        dep = dep[2:]
        if dep + ":lib" not in direct:
            problems.append("{}:lib_ungated does not depend on {}:lib: a dependent must read the gated library".format(user, dep))
        if dep + ":lib_ungated" in direct:
            problems.append("{}:lib_ungated depends on {}:lib_ungated: that bypasses the tests of {}".format(user, dep, dep))
    return problems

# The checks and markers of the rules (ci/planted/BUCK): each rule runs `check` (rules/check) to compare, hash, copy or run a test, and writes its output
# only when that passed. For each rule, a bad input the action must refuse (the build is red), and a control, the same rule on a good input, that must
# build (so the refusal is for the input and not for something else). The Mojo test run has no control here: its stand-in program cannot pass,
# and the real runs are built by //ci:mojo.
#
# Each row is (target that must be refused, control or None, the text its refusal must hold). The text is what `check` says when it ran the right command
# and the check failed, so a command line `check` itself refuses (a wrong option, a missing program) does not satisfy it. `check marker` says
# `TEST FAILED: ` only after it started the test, and that is what the Mojo test run (which has no control) is held to.
PLANTED = [
    ("//ci/planted:run_check_of_other_stdout", "//examples/hello:hello_runs", "run_check: expected output equal to 'not what it prints' but"),
    ("//ci/planted:c_check_of_other_stdout", "//ci/planted:c_check_of_its_stdout", "c_check: expected output equal to 'not what it prints' but"),
    ("//ci/planted:mojo_same_of_other_bytes", "//ci/mojo_gate:consumer_of_green", "differ at byte 1"),
    ("//ci/planted:table_of_other_bytes", "//ci/planted:table_in_sync", "STALE ci/planted/empty.txt"),
    ("//ci/planted:rust_toolchain_of_other_version", "toolchains//:rust", "rust_toolchain: expected output starting with 'rustc 0.0.0 (' but"),
    ("//ci/planted:fails", "//examples/hello:hello_lib_test", "this test fails by design"),
    ("//ci/planted:lib_behind_a_failing_test", "//examples/hello:hello_lib", "this test fails by design"),
    ("//ci/planted:mojo_test_that_fails", None, "check marker: TEST FAILED: "),
    # The data and the variables of a Mojo test (ci/mojo_data/BUCK): the stand-in test reads what is staged and says which of its expectations failed.
    # The control of each is the run that stages everything the probe expects.
    ("//ci/mojo_data:run_red_content", "//ci/mojo_data:run_green", "data_probe: greeting.txt holds other data"),
    ("//ci/mojo_data:run_red_env", "//ci/mojo_data:run_green", "data_probe: PROBE_MODE is lax, not strict"),
    ("//ci/mojo_data:run_red_no_program", "//ci/mojo_data:run_green", "data_probe: cannot start bin/hello: FileNotFound"),
    ("//ci/mojo_data:run_red_not_executable", "//ci/mojo_data:run_green", "data_probe: cannot start bin/hello: AccessDenied"),
    # The installed layout (`test_layout = "installed"`): the control is the run in which the probe finds everything where the layout puts it.
    ("//ci/mojo_data:run_red_installed_probe_in_default_layout", "//ci/mojo_data:run_green_installed", "is not in a bin/ directory"),
    ("//ci/mojo_data:run_red_default_probe_in_installed_layout", "//ci/mojo_data:run_green", "is not BUILDRULES_TEST_DATA"),
    ("//ci/mojo_data:run_red_installed_no_greeting", "//ci/mojo_data:run_green_installed", "data_probe: cannot read share/greeting.txt: FileNotFound"),
    ("//ci/mojo_data:run_red_installed_content", "//ci/mojo_data:run_green_installed", "data_probe: share/greeting.txt holds other data"),
]

def _failures(ctx, label):
    """The text of what failed when building `label` on GATE_PLATFORM."""
    text = ""
    for _, result in ctx.build(label, target_platform = GATE_PLATFORM).items():
        bad = result.failures()
        for f in (list(bad) if bad else []):
            text += str(f) + "\n"
    return text

def planted_problems(ctx):
    """Every way a check or marker does not refuse its bad input for its reason, or its control is not green: a list of strings, empty when all hold."""
    problems = []
    for planted, control, reason in PLANTED:
        built, failed = _built(ctx, planted)
        if not failed:
            problems.append("{} built ({} artifact(s)): the check it plants is gone, a failure leaves the target green".format(planted, built))
        elif reason not in _failures(ctx, planted):
            problems.append("{} is red, but not for the reason it plants (expected \"{}\"): {}".format(planted, reason, _failures(ctx, planted)))
        if control:
            built, failed = _built(ctx, control)
            if failed or not built:
                problems.append("{} (the control of {}) must build, and it built {} artifact(s) and failed {}".format(control, planted, built, failed))
    return problems + test_command_problems(ctx)

# The command `buck2 test` runs for a test (its ExternalRunnerTestInfo): `check run`, the start options, then `--` and the program. No build action of CI runs it,
# so a command that lost its options is green everywhere but under `buck2 test`; this holds the text of the command of one cargo test (the working directory, the
# absolute directories and the one that is made) and of one Mojo test run (the compiler's lib on the library path), and that the program is the test's binary.
# It also holds the rest of what `buck2 test` is given: the environment (the keys a test reads: CARGO_MANIFEST_DIR, the package's CARGO_PKG_*, the nonce, and
# CARGO_TARGET_TMPDIR for an integration test only), the labels, and the inputs the run reads (`hidden`). The three kinds of cargo test are here: a library
# test (examples/p4ws), a binary's test and an integration test (ci/cargo_run). Each row: label, text of the command, keys the environment has, keys it has not,
# labels, text of the command's `hidden`.
_CARGO_START = "\"run\", \"--tmpdir\", \"--abs\", \"CARGO_MANIFEST_DIR\", \"--cwd-env\", \"CARGO_MANIFEST_DIR\", "
_CARGO_ENV = ["CARGO_MANIFEST_DIR", "CARGO_PKG_NAME", "CARGO_PKG_VERSION", "BUILDRULES_NONCE"]
TEST_COMMANDS = [
    ("//ci/cargo_run:env_test", [
        _CARGO_START + "\"--abs\", \"CARGO_TARGET_TMPDIR\", \"--mkdir-env\", \"CARGO_TARGET_TMPDIR\", \"--\", <build artifact env_test__bin_bin/env",
    ], _CARGO_ENV + ["CARGO_TARGET_TMPDIR"], [], ["test", "cargo_run"], ["hidden=[", "ci/cargo_run/tests/env.rs"]),
    ("//ci/cargo_run:bin_test", [
        _CARGO_START + "\"--\", <build artifact bin_test__bin_bin/cargo_run",
    ], _CARGO_ENV, ["CARGO_TARGET_TMPDIR"], ["test", "cargo_run"], ["hidden=[", "ci/cargo_run/src/main.rs"]),
    ("//examples/p4ws/crates/probe_ok:probe_ok-0.1.0_2662e7548e", [
        _CARGO_START + "\"--\", <build artifact",
    ], _CARGO_ENV, ["CARGO_TARGET_TMPDIR"], ["test"], ["hidden=[", "src/lib.rs"]),
    ("//ci/planted:mojo_test_that_fails", [
        "\"run\", \"--ld-library-path\", cmd_args(<build artifact check",
        "\"/lib\", delimiter=\"\"), \"--private-scratch\", \"--\", <build artifact check",
    ], [], [], ["test", "mojo"], ["hidden=[<build artifact check"]),
    # A Mojo test with data and variables: the private scratch (always), the data directory as the working directory and named by BUILDRULES_TEST_DATA, made
    # absolute (the command starts in the execution root), and the variable is given; the directory is an input of the command.
    ("//ci/mojo_data:run_green", [
        "\"--private-scratch\", \"--env\"",
        "\"--abs\", \"BUILDRULES_TEST_DATA\", \"--cwd-env\", \"BUILDRULES_TEST_DATA\"",
        "\"PROBE_MODE=strict\"",
        "cmd_args(\"BUILDRULES_TEST_DATA=\"",
    ], [], [], ["test", "mojo"], ["hidden=["]),
    # The installed layout: the private scratch, `--installed` (the fresh root, the binary at `<root>/bin/`), the data directory copied to `<root>/share` and named by
    # BUILDRULES_TEST_DATA; the default layout's working-directory options are not in it.
    ("//ci/mojo_data:run_green_installed", [
        "\"--private-scratch\", \"--installed\", \"--install-share\", <build artifact",
        "\"--share-env\", \"BUILDRULES_TEST_DATA\"",
        "\"PROBE_LAYOUT=installed\"",
    ], [], [], ["test", "mojo"], ["hidden=["]),
]

def test_command_problems(ctx):
    """Every way what `buck2 test` is given for the tests in TEST_COMMANDS is not what the rule builds: a list of strings, empty when all is as expected."""
    problems = []
    for label, wants, env_has, env_hasnt, labels, hidden in TEST_COMMANDS:
        node = ctx.configured_targets(label, target_platform = GATE_PLATFORM)
        info = ctx.analysis(node).providers()[ExternalRunnerTestInfo]
        if len(info.command) != 1:
            problems.append("{}: the `buck2 test` command is {} argument lists, not 1".format(label, len(info.command)))
            continue
        text = str(info.command[0])
        for want in wants + hidden:
            if want not in text:
                problems.append("{}: the `buck2 test` command lacks `{}`: {}".format(label, want, text))
        env = info.env or {}
        for key in env_has:
            if key not in env:
                problems.append("{}: the environment `buck2 test` gives lacks {}: {}".format(label, key, sorted(env.keys())))
        for key in env_hasnt:
            if key in env:
                problems.append("{}: the environment `buck2 test` gives has {}, which this kind of test does not get".format(label, key))
        for want in labels:
            if want not in (info.labels or []):
                problems.append("{}: the labels `buck2 test` is given lack `{}`: {}".format(label, want, info.labels))
    return problems
