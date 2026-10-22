"""The planted defects of ci/negative must stay red (and the Mojo gate, `gate_problems`, below): what the check holds them to (ci/negative.bxl, and ci/completeness.bxl, which the public CI runs).

A wildcard build skips the fixture (it is compatible only with the platform it breaks on), so nothing else notices if it turns green. `negative_problems`
analyses it on that platform and reports every way it is not red for the reason it plants. The control (`v3_test_with_isa_property`: the same test run with
the one line the fixture leaves out) must analyse on the same platform, so the fixture is known to be red for that line and not for some other reason.
Make the fixture valid (give it `exec_compatible_with = test_exec_compatible_with()`) and the check reports "analysed"; break the control and it reports the
control's own error. ci/negative_check.zig holds the wiring of this file to the fixtures, in //ci:all.
"""

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
    ("//examples/mojo/registry/cnative:coverage", "buildrules//platforms:linux_x86_64", "this package has no test, so there is no coverage to measure"),
    ("//examples/mojo/registry/probe_sys:coverage", "buildrules//platforms:linux_x86_64", "this package has no test, so there is no coverage to measure"),
    ("//examples/mojo/registry/probe_sys/base_sys:coverage", "buildrules//platforms:linux_x86_64", "this package has no test, so there is no coverage to measure"),
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
    return problems + gate_problems(ctx) + planted_problems(ctx)

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
]
GATE_PACKAGES = [
    "//examples/mojo/copy_of_base",
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
# only when that passed. For each rule a planted input that must make the action fail, and a control, the same rule on an input that is right, that must
# build (so the planted one is red for its input and not for something else). The Mojo test run has no control here: its stand-in program cannot pass,
# and the real runs are built by //ci:mojo.
PLANTED = [
    ("//ci/planted:run_check_of_other_stdout", "//examples/hello:hello_runs"),
    ("//ci/planted:c_check_of_other_stdout", "//ci/planted:c_check_of_its_stdout"),
    ("//ci/planted:mojo_same_of_other_bytes", "//ci/mojo_gate:consumer_of_green"),
    ("//ci/planted:table_of_other_bytes", "//ci/planted:table_in_sync"),
    ("//ci/planted:rust_toolchain_of_other_version", "toolchains//:rust"),
    ("//ci/planted:fails", "//examples/hello:hello_lib_test"),
    ("//ci/planted:lib_behind_a_failing_test", "//examples/hello:hello_lib"),
    ("//ci/planted:mojo_test_that_fails", None),
]

def planted_problems(ctx):
    """Every way a planted check or marker is not red, or its control is not green: a list of strings, empty when all is as planted."""
    problems = []
    for planted, control in PLANTED:
        built, failed = _built(ctx, planted)
        if not failed:
            problems.append("{} built ({} artifact(s)): the check it plants is gone, a failure leaves the target green".format(planted, built))
        if control:
            built, failed = _built(ctx, control)
            if failed or not built:
                problems.append("{} (the control of {}) must build, and it built {} artifact(s) and failed {}".format(control, planted, built, failed))
    return problems
