"""The real-graph cases of the selector (rules/affected): `select` and `without_left_out` over Buck2's own answers for the fixture
ci/affected_fixture, through `make_graph`. What they hold: the owner query, the build-file and reverse build-file queries, the
reverse-dependency query within a scope that leaves the aggregate's package out, and `exists` read from the root of the cell of the
BXL script that runs them. The table cases (rules/affected/tests/cases.bzl) hold the rules over graphs written out.

`affected_problems(ctx)` returns one line per case that answered otherwise. ci/completeness.bxl reports them (the public CI runs it);
run alone: `buck2 bxl //ci:affected.bxl:check`.
"""

load("@buildrules//rules/affected:defs.bzl", "AFFECTED", "VACUOUS", "WIDENED", "make_graph", "select", "without_left_out")

FIXTURE = "buildrules//ci/affected_fixture"
_DIR = "ci/affected_fixture/"
_AGG_PKG = "ci/affected_fixture/agg"
_SCOPE = ["{}:{}".format(FIXTURE, n) for n in ["leaf_src", "lonely_src", "leaf", "mid", "top", "lonely"]]
_RULES = struct(
    widen = [(_DIR + "widen*", "a fixture row")],
    inert = [],
)

def _real_case(g, name, changed, kind, targets = None):
    v = select(_RULES, changed, g, _AGG_PKG)
    problems = []
    if v.kind != kind:
        problems.append("kind {} (reason: {}), wanted {}".format(v.kind, v.reason, kind))
    if targets != None:
        got = [t for t in v.targets if t.startswith(FIXTURE + ":")]
        want = ["{}:{}".format(FIXTURE, t) for t in targets]
        if got != want:
            problems.append("targets {}, wanted {}".format(got, want))
    return [] if not problems else ["{}: {}".format(name, "; ".join(problems))]

def affected_problems(ctx):
    out = []
    g = make_graph(ctx, _SCOPE, "buildrules//" + _AGG_PKG + ":")
    both = ["leaf", "leaf_src", "lonely", "lonely_src", "mid", "top"]

    # the owner query, then the reverse dependencies within the scope
    out += _real_case(g, "a leaf file selects its owner and every dependent, not the unrelated check", [_DIR + "leaf.txt"], AFFECTED, ["leaf", "leaf_src", "mid", "top"])
    out += _real_case(g, "the other leaf selects only its own chain", [_DIR + "lonely.txt"], AFFECTED, ["lonely", "lonely_src"])

    # the build-file queries: a BUCK file and a file deleted from the package select the package; a .bzl, the packages that load it
    out += _real_case(g, "a BUCK file selects its whole package", [_DIR + "BUCK"], AFFECTED, both)
    out += _real_case(g, "a file deleted from the package selects the package", [_DIR + "gone.txt"], AFFECTED, both)
    out += _real_case(g, "a bzl selects the packages that load it", [_DIR + "defs.bzl"], AFFECTED, both)
    out += _real_case(g, "a bzl loaded by another bzl selects the packages that load either, and nothing for the bzl between", [_DIR + "inner.bzl"], AFFECTED, both)

    # a file no target owns widens (and exists: `exists` reads the root of this script's cell); inert, it is vacuous
    out += _real_case(g, "a file no target owns widens", [_DIR + ".unowned"], WIDENED)
    if not g.exists(_DIR + ".unowned") or g.exists(_DIR + "gone.txt"):
        out.append("exists: reads the fixture's files from the cell root: .unowned {}, gone.txt {}".format(g.exists(_DIR + ".unowned"), g.exists(_DIR + "gone.txt")))
    out += _real_case(g, "a widen row widens", [_DIR + "widen_me"], WIDENED)
    out += _real_case(g, "the aggregate's package widens", [_AGG_PKG + "/BUCK"], WIDENED)
    v = select(struct(widen = [], inert = [_DIR + ".unowned"]), [_DIR + ".unowned"], g, _AGG_PKG)
    if v.kind != VACUOUS:
        out.append("an inert unowned file: kind {}, wanted {}".format(v.kind, VACUOUS))

    # what the aggregate leaves out (the configuration's `excluded`) is never selected: a change to lonely.txt reaches `lonely` and
    # `lonely_src`; with a row naming `lonely` only the source stays
    v = select(_RULES, [_DIR + "lonely.txt"], g, _AGG_PKG)
    kept = without_left_out(ctx, v.targets, [FIXTURE + ":lonely"])
    if FIXTURE + ":lonely" not in v.targets or kept != [t for t in v.targets if t != FIXTURE + ":lonely"] or FIXTURE + ":lonely_src" not in kept:
        out.append("an excluded row naming `lonely` must drop it from the selection and keep `lonely_src`: selected {}, kept {}".format(v.targets, kept))
    if without_left_out(ctx, v.targets, []) != v.targets:
        out.append("no excluded row must leave the selection as it is")
    if without_left_out(ctx, v.targets, [FIXTURE + ":"]) != []:
        out.append("a package pattern in excluded must drop every target of the package")

    # the aggregate's package is left out of the reverse-dependency universe: over the whole fixture but `all` (which depends on the
    # aggregate, and would bring it back: rdeps answers over the universe's dependency closure), a leaf reaches its chain and not the
    # aggregate; with nothing left out (the control) it reaches the aggregate too
    whole = [FIXTURE + "/... - " + FIXTURE + ":all"]
    chain = sorted(["{}:{}".format(FIXTURE, n) for n in ["leaf_src", "leaf", "mid", "top"]])
    left_out = sorted(make_graph(ctx, whole, "buildrules//" + _AGG_PKG + ":").rdeps([FIXTURE + ":leaf_src"]))
    if left_out != chain:
        out.append("the aggregate's package left out of the universe: rdeps {}, wanted {}".format(left_out, chain))
    control = sorted(make_graph(ctx, whole, "buildrules//rules/affected:").rdeps([FIXTURE + ":leaf_src"]))
    if control != sorted(chain + [FIXTURE + "/agg:agg"]):
        out.append("nothing left out of the universe (the control): rdeps {}, wanted the chain and the aggregate".format(control))
    return out
