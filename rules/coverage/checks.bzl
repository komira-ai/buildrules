"""What the coverage rules refuse at analysis (zig_cover.bzl), as functions of plain values.

Each check takes the values it judges and `refuse`, which is `fail` in a rule: the build stops at the first refusal, with its message. A test passes a
recorder instead (rules/rust/refusal.bzl) and reads what was refused (rules/coverage/tests).
"""

def check_test_targets(who, test_targets, refuse = fail):
    """A package with no test has no coverage to measure."""
    if not test_targets:
        refuse("{}: test_targets is empty: a package with no test has no coverage to measure".format(who))
