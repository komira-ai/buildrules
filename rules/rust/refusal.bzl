"""Testing a refusal. Buck2 has no "expect this target to fail" test, and `fail()` cannot be caught, so the rules that refuse take the
way they refuse as an argument (`cargo_package(refuse = ...)`, `check_toolchain(table, refuse)`; the default is `fail`). A test passes a
recorder, and `refusal_test` is a target that exists, and is green, only if the refusal happened with the reason it should.

    refusals, refuse = recording()
    cargo_package(path = ".", refuse = refuse)      # a table for a Rust nobody pins: refused, and the load goes on
    refusal_test(name = "unpinned_is_refused", refusals = refusals, contains = ["does not pin"])

Remove the refusal from the rule and the test target fails analysis ("expected a refusal"); build it and read the reason.
"""

def recording():
    """(messages, refuse): `refuse(m)` appends `m` to `messages`."""
    messages = []

    def refuse(m):
        messages.append(m)

    return messages, refuse

def _refusal_test_impl(ctx):
    who = str(ctx.label.raw_target())
    got = ctx.attrs.refusals
    if ctx.attrs.none:
        if got:
            fail("{}: expected no refusal, got: {}".format(who, got))
    else:
        if not got:
            fail("{}: expected a refusal and there was none: the rule accepted what it must refuse".format(who))
        for want in ctx.attrs.contains:
            if not any([want in m for m in got]):
                fail("{}: the refusal does not say {!r}; it says: {}".format(who, want, got))
    marker = ctx.actions.write(ctx.label.name + ".passed", "ok\n")
    return [DefaultInfo(default_output = marker)]

refusal_test = rule(
    impl = _refusal_test_impl,
    doc = "Green only if `refusals` (what a recorder collected while a rule was loaded) is as expected: non-empty and containing every string of `contains`, or, with `none`, empty.",
    attrs = {
        "contains": attrs.list(attrs.string(), default = []),
        "none": attrs.bool(default = False),
        "refusals": attrs.list(attrs.string(), default = []),
    },
)

def refuses(name, check, args, contains, kwargs = {}):
    """A refusal test for `check(*args, refuse = ...)`: green only if the check refused and every string of `contains` is in what it said. Make the
    check accept what it must refuse and the target stops existing (analysis fails: "expected a refusal"). Returns the target's label, for a group."""
    refusals, refuse = recording()
    check(*args, **dict(kwargs, refuse = refuse))
    refusal_test(name = name, refusals = refusals, contains = contains, visibility = ["PUBLIC"])
    return ":" + name

def accepts(name, check, args, kwargs = {}):
    """The other half of `refuses`: green only if `check(*args)` accepts, so a check that refuses everything is red too."""
    refusals, refuse = recording()
    check(*args, **dict(kwargs, refuse = refuse))
    refusal_test(name = name, refusals = refusals, none = True, visibility = ["PUBLIC"])
    return ":" + name
