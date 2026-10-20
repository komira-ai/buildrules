"""The planted defect of ci/negative must stay red: what the check holds it to (ci/negative.bxl, and ci/completeness.bxl, which the public CI runs).

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

def _analyse(ctx, label):
    node = ctx.configured_targets(label, target_platform = PLATFORM)
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
    return problems
