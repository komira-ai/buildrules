"""The hang limit of a welded test (docs/contract.md, section 12.8): the longest a welded Mojo test run may take before it is stopped as hung.

It is infrastructure and not an assertion about time: a test never waits for a time to pass, so a test that has not finished by the limit did not finish at all.
Every welded Mojo test action carries it, the same contract in these rules and in a consumer's own rules (`gate_mojo`, test_runtime.bzl):

  * 1800 seconds by default (`HANG_LIMIT_S`); per target, `test_hang_limit_s` (a positive whole number of seconds). Raise it for a test that is genuinely long;
    never lower it to make a test pass.
  * on expiry the whole process group of the test is killed, the exit status is 125, and stderr gets one line, `hang limit: <test> did not finish within <N> s
    and was stopped; a test never waits on time, so this means it hung (an event that never came)`, with the test's label. The action stays red: no marker is written.

The actions that carry it are the ones whose marker welds `:lib`: the test run of `mojo_test_run_rule` (`check marker`, rules/check) and the gated run of
`gate mojo` (rules/gate). The coverage runs are not welded and do not carry it; they have no limit of their own, and a coverage run that hangs is ended by the executor's timeout.
"""

# The default, in seconds, of every welded Mojo test action.
HANG_LIMIT_S = 1800

def check_hang_limit(where, limit, refuse = fail):
    """`test_hang_limit_s` is a positive whole number of seconds. Returns whether it is; `refuse` is `fail` in a rule, a recorder in a test."""
    if type(limit) != "int" or limit <= 0:
        refuse("{}: test_hang_limit_s {} is not a positive whole number of seconds (raise it for a test that is genuinely long; never lower it to make a test pass)".format(where, repr(limit)))
        return False
    return True

def check_hang_limits(where, limits, tests, refuse = fail):
    """`mojo_package(test_hang_limit_s = {"<test source or *>": seconds})`: a dict whose keys are `*` or a test of the package (`tests`, as `test_data` names them) and
    whose values are accepted by `check_hang_limit`. Returns whether it is."""
    if type(limits) != "dict":
        refuse("{}: test_hang_limit_s must be a dict {{\"<test source or *>\": seconds}}, not {}".format(where, type(limits)))
        return False
    ok = True
    for key in sorted(limits.keys()):
        if key != "*" and key not in tests:
            refuse("{}: test_hang_limit_s names {}, which is `*` or a test of the package ({})".format(where, repr(key), ", ".join(sorted(tests))))
            ok = False
        if not check_hang_limit("{}: test_hang_limit_s[{}]".format(where, repr(key)), limits[key], refuse):
            ok = False
    return ok

def hang_limit_of(limits, test):
    """The limit of `test` in `limits`: its own entry, else the `*` entry, else the default."""
    if test in limits:
        return limits[test]
    return limits.get("*", HANG_LIMIT_S)

def hang_limit_args(label, limit):
    """The options of `check marker` that put the hang limit on a test run called `label` (the test's label as the rule prints it)."""
    return ["--hang-limit-s", str(limit), "--hang-label", label]

def hang_limit_flags(limit):
    """The option of `gate mojo` that puts the hang limit on the run (its `--label` is the test's label)."""
    return ["--hang-limit-s", str(limit)]
