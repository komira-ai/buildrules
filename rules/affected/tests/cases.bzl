"""The table cases of the selector (rules/affected): `select`, the holds, the heavy rows and `affected_answer`, over graphs written out in
this file. `table_problems()` returns one line per case that answered otherwise; tests/BUCK fails the load with each, so the package (and
//ci:refusals) is red while one is. Each case's name says what it holds.

The real graph (Buck2's own queries over a fixture package) is ci/affected.bzl's.
"""

load(
    "//rules/affected:defs.bzl",
    "AFFECTED",
    "BROKEN",
    "EMPTY",
    "VACUOUS",
    "WIDENED",
    "affected_answer",
    "affected_config",
    "affected_output",
    "answer_json",
    "heavy_split",
    "held_config",
    "held_refusals",
    "is_held_file",
    "parse_held_lines",
    "pattern_matches",
    "plan",
    "select",
)
load("//rules/affected:select.bzl", "format_refusal")

def _reverse_closure(dependents, seeds):
    seen = {}
    todo = list(seeds)
    for _ in range(1000):
        if not todo:
            break
        t = todo.pop()
        if t in seen:
            continue
        seen[t] = True
        todo += dependents.get(t, [])
    return seen.keys()

# ---- the table graph ---------------------------------------------------
#
#   src/a/a.mojo  -> owned by a:a        src/a/BUCK (package src/a: a:a, a:a_test)
#   src/b/b.mojo  -> owned by b:b        b:b depends on a:a; c:c depends on b:b
#   src/lib.bzl   -> loaded by src/a/BUCK and src/b/BUCK
#   src/data.bzl  -> loaded by src/b/BUCK, and listed as a source by docs:doc_tree
#   docs/x.md     -> owned by docs:doc_tree
#   .hidden       -> owned by nothing
#   ci/BUCK, ci/targets.bzl, ci/targets/shard_3.bzl -> the aggregate's package (ci:pr)

_FILES = {
    "src/a/a.mojo": True,
    "src/a/BUCK": True,
    "src/b/b.mojo": True,
    "src/b/BUCK": True,
    "src/lib.bzl": True,
    "docs/x.md": True,
    "docs/BUCK": True,
    "README.md": True,
    ".hidden": True,
    "ci/BUCK": True,
    "ci/targets.bzl": True,
    "ci/targets/shard_3.bzl": True,
    "orphan.bzl": True,
    "src/data.bzl": True,
}
_OWNERS = {
    "src/a/a.mojo": ["t//src/a:a"],
    "src/b/b.mojo": ["t//src/b:b"],
    "docs/x.md": ["t//docs:doc_tree"],
    "ci/targets.bzl": ["t//ci:pr"],
    "src/data.bzl": ["t//docs:doc_tree"],
}
_PACKAGES = {
    "src/a": ["t//src/a:a", "t//src/a:a_test"],
    "src/b": ["t//src/b:b"],
    "docs": ["t//docs:doc_tree"],
    "ci": ["t//ci:pr"],
}
_INCLUDING = {
    "src/lib.bzl": ["t//src/a:a", "t//src/a:a_test", "t//src/b:b"],
    "ci/targets.bzl": ["t//ci:pr"],
    "ci/targets/shard_3.bzl": ["t//ci:pr"],
    "src/data.bzl": ["t//src/b:b"],
}

# reverse edges: who depends on a target (the aggregate is not in the universe)
_DEPENDENTS = {
    "t//src/a:a": ["t//src/b:b", "t//src/a:a_test"],
    "t//src/b:b": ["t//src/c:c"],
}

def _table():
    return struct(
        exists = lambda p: p in _FILES,
        owners = lambda p: _OWNERS.get(p, []),
        package_targets = lambda d: _PACKAGES.get(d, []),
        including = lambda p: _INCLUDING.get(p, []),
        rdeps = lambda seeds: _reverse_closure(_DEPENDENTS, seeds),
    )

_RULES = struct(
    widen = [
        (".buckconfig", "the configuration"),
        ("tools/build/**", "the build system"),
        ("third_party/**", "pinned sources"),
    ],
    inert = ["*.md", ".github/CODEOWNERS"],
)

_A_AND_DEPENDENTS = ["t//src/a:a", "t//src/a:a_test", "t//src/b:b", "t//src/c:c"]

def _table_case(name, changed, kind, targets = None, reason = None):
    v = select(_RULES, changed, _table(), "ci")
    problems = []
    if v.kind != kind:
        problems.append("kind {} (reason: {}), wanted {}".format(v.kind, v.reason, kind))
    if targets != None and v.targets != targets:
        problems.append("targets {}, wanted {}".format(v.targets, targets))
    if reason != None and reason not in v.reason:
        problems.append("reason '{}' lacks '{}'".format(v.reason, reason))
    return [] if not problems else ["select: {}: {}".format(name, "; ".join(problems))]

def _table_cases():
    out = []

    # a leaf change selects its owner and every dependent, transitively, and nothing else
    out += _table_case("leaf source selects owner and dependents", ["src/a/a.mojo"], AFFECTED, _A_AND_DEPENDENTS)
    out += _table_case("a leaf with one dependent chain", ["src/b/b.mojo"], AFFECTED, ["t//src/b:b", "t//src/c:c"])

    # BUCK seeds the package, .bzl the loaders
    out += _table_case("BUCK change selects the package and dependents", ["src/b/BUCK"], AFFECTED, ["t//src/b:b", "t//src/c:c"])
    out += _table_case("bzl change selects every loader and dependents", ["src/lib.bzl"], AFFECTED, _A_AND_DEPENDENTS)
    out += _table_case("a bzl no BUCK loads widens", ["orphan.bzl"], WIDENED, reason = "loaded by no BUCK file")
    out += _table_case("a bzl also selects the targets that list it", ["src/data.bzl"], AFFECTED, ["t//docs:doc_tree", "t//src/b:b", "t//src/c:c"])

    # a widen row widens, whatever else is in the change
    out += _table_case("a file under a dir/** widen row widens", ["tools/build/mojo/defs.bzl"], WIDENED, reason = "tools/build/**")
    out += _table_case("a file under another widen row widens", ["third_party/zlib/pin.txt"], WIDENED, reason = "third_party/**")
    out += _table_case("an exact widen row widens", [".buckconfig"], WIDENED, reason = ".buckconfig")
    out += _table_case("a widening file beside a leaf change widens", ["src/a/a.mojo", "tools/build/x.zig"], WIDENED)

    # docs only: owned by the doc tree, so selected (not vacuous)
    out += _table_case("docs-only change selects the doc tree", ["docs/x.md"], AFFECTED, ["t//docs:doc_tree"])
    out += _table_case("inert unowned files alone are vacuous", ["README.md", ".github/CODEOWNERS"], VACUOUS)
    out += _table_case("an inert file beside a leaf change is ignored", ["README.md", "src/b/b.mojo"], AFFECTED, ["t//src/b:b", "t//src/c:c"])

    # no owner and no inert row: widens (never silently dropped)
    out += _table_case("an existing file no target owns widens", [".hidden"], WIDENED, reason = "no target owns '.hidden'")

    # deleted files: the package above them, a deleted BUCK widens
    out += _table_case("deleted file selects its package and dependents", ["src/a/old.mojo"], AFFECTED, _A_AND_DEPENDENTS)
    out += _table_case("a file deleted two directories below its package selects the package", ["src/a/sub/deeper/old.mojo"], AFFECTED, _A_AND_DEPENDENTS)
    out += _table_case("deleted BUCK widens", ["src/a/deleted/BUCK"], WIDENED, reason = "its package is gone")
    out += _table_case("deleted file in no package, not inert, widens", ["nowhere/old.txt"], WIDENED, reason = "no package holds it")
    out += _table_case("deleted inert file in no package is ignored alone (vacuous)", ["gone/NOTES.md"], VACUOUS)

    # the aggregate's own list changing is not a selection: it widens
    out += _table_case("a change to the aggregate's package widens", ["ci/targets.bzl"], WIDENED, reason = "aggregate's own package")
    out += _table_case("a change to a shard of the aggregate's list widens", ["ci/targets/shard_3.bzl"], WIDENED, reason = "aggregate's own package")
    out += _table_case("the aggregate's BUCK widens", ["ci/BUCK"], WIDENED, reason = "aggregate's own package")

    # a seed that reaches nothing widens (the universe does not hold it)
    nothing = struct(exists = lambda p: True, owners = lambda p: ["t//elsewhere:x"], package_targets = lambda d: [], including = lambda p: [], rdeps = lambda s: [])
    v = select(_RULES, ["src/a/a.mojo"], nothing, "ci")
    if v.kind != WIDENED or "answered nothing" not in v.reason:
        out.append("select: reverse query answering nothing: kind {} ({}), wanted {}".format(v.kind, v.reason, WIDENED))

    # a deleted file with no package between it and the root BUCK seeds the root package
    rooted = struct(
        exists = lambda p: p == "BUCK",
        owners = lambda p: [],
        package_targets = lambda d: ["t//:root"] if d == "" else [],
        including = lambda p: [],
        rdeps = lambda s: list(s),
    )
    v = select(_RULES, ["x/y/z.txt"], rooted, "ci")
    if v.kind != AFFECTED or v.targets != ["t//:root"]:
        out.append("select: a deleted file under the root package only: kind {}, targets {}, wanted AFFECTED [t//:root]".format(v.kind, v.targets))

    # empty
    out += _table_case("no changed file is EMPTY, not a pass", [], EMPTY)
    out += _table_case("blank lines are no file", ["", ""], EMPTY)

    # patterns
    for pattern, path, wanted in [
        ("tools/build/**", "tools/build/a/b.zig", True),
        ("tools/build/**", "tools/buildx/a", False),
        ("tools/build/**", "tools/build", False),
        ("tools/buck2*", "tools/buck2.toml", True),
        ("tools/buck2*", "tools/buck", False),
        ("*.md", "docs/a/b.md", True),
        ("*.md", "docs/a/b.mdx", False),
        ("buck2", "buck2", True),
        ("buck2", "tools/buck2", False),
    ]:
        if pattern_matches(pattern, path) != wanted:
            out.append("pattern {} on {}: wanted {}".format(pattern, path, wanted))
    return out

# ---- holds ---------------------------------------------------------------
#
# The marker's basename is a parameter; these cases name it `held_marker`.

_MARKER_NAME = "held_marker"

def _held(changed, lines, package_stays = True, buck = "src/a/BUCK"):
    """`package_stays`: whether the BUCK file of the marker's package (`buck`, the only path the check may ask about) is there."""
    base, head = parse_held_lines(lines, "HEAD")
    g = struct(exists = lambda p: package_stays and p == buck)
    return held_refusals(changed, base, head, g, _MARKER_NAME)

def _held_cases():
    out = []
    marker = "src/a/" + _MARKER_NAME

    def case(name, changed, lines, wanted, package_stays = True):
        got = _held(changed, lines, package_stays)
        if got != wanted:
            out.append("held: {}: {}, wanted {}".format(name, got, wanted))

    base = ["abc123:{}:1:# held".format(marker), "abc123:{}:2:line".format(marker), "abc123:{}:3:branch".format(marker)]
    case("a metric taken out is refused", [marker], base + ["HEAD:{}:1:line".format(marker)], [marker + ": branch is no longer held"])
    case("every metric taken out, marker emptied, is refused", [marker], base, [marker + ": branch is no longer held", marker + ": line is no longer held"])
    case("a reordered marker passes", [marker], base + ["HEAD:{}:1:branch".format(marker), "HEAD:{}:2:line".format(marker)], [])
    case("a gained metric passes", [marker], ["abc123:{}:1:line".format(marker), "HEAD:{}:1:line".format(marker), "HEAD:{}:2:branch".format(marker)], [])
    case("a comment taken out passes", [marker], base + ["HEAD:{}:1:line".format(marker), "HEAD:{}:2:branch".format(marker)], [])
    case("a new marker passes", [marker], ["HEAD:{}:1:line".format(marker)], [])
    case("a marker deleted with its package stays refused", [marker], base, [marker + ": branch is no longer held", marker + ": line is no longer held"])
    case("a marker deleted with its package's BUCK passes", [marker], base, [], package_stays = False)
    case("a marker the change does not name is not read", ["src/a/a.mojo"], base, [])
    case("another package's marker is its own", [marker], base + ["HEAD:src/b/{}:1:line".format(_MARKER_NAME), "HEAD:{}:1:line".format(marker), "HEAD:{}:2:branch".format(marker)], [])

    # a metric is the line's text without surrounding blanks; blank lines and comments (indented too) are no metric
    case(
        "blanks, empty lines and an indented comment are no metric",
        [marker],
        ["abc123:{}:1:line ".format(marker), "abc123:{}:2:".format(marker), "abc123:{}:3:  # a comment".format(marker), "HEAD:{}:1:line".format(marker)],
        [],
    )

    # the root package's marker: its package is the root BUCK
    root_base = ["abc123:{}:1:line".format(_MARKER_NAME)]
    if _held([_MARKER_NAME], root_base, buck = "BUCK") != [_MARKER_NAME + ": line is no longer held"]:
        out.append("held: a root marker emptied is refused: {}".format(_held([_MARKER_NAME], root_base, buck = "BUCK")))
    if _held([_MARKER_NAME], root_base, package_stays = False, buck = "BUCK") != []:
        out.append("held: a root marker deleted with the root BUCK passes")

    # the marker's basename is the parameter, matched as a whole basename
    for path, name, wanted in [
        (_MARKER_NAME, _MARKER_NAME, True),
        ("src/a/" + _MARKER_NAME, _MARKER_NAME, True),
        ("src/a/" + _MARKER_NAME + ".md", _MARKER_NAME, False),
        ("src/a/x" + _MARKER_NAME, _MARKER_NAME, False),
        ("src/a/" + _MARKER_NAME, "another_marker", False),
    ]:
        if is_held_file(path, name) != wanted:
            out.append("held: is_held_file({!r}, {!r}): wanted {}".format(path, name, wanted))

    # with another marker name, this marker is not a hold
    other = parse_held_lines(base, "HEAD")
    if held_refusals([marker], other[0], other[1], struct(exists = lambda p: True), "another_marker") != []:
        out.append("held: a file of another basename is not read as a marker")
    return out

# ---- the heavy rows ------------------------------------------------------
#
#     src/a/a.mojo  -> t//src/a:a         t//src/a:a_test tests it
#     src/h/h.mojo  -> t//src/h:heavy     depends on a:a; t//src/h:h_root depends on heavy
#     src/g/g.mojo  -> t//src/g:heavy2    depends on a:a; t//src/g:g_root depends on heavy2
#     src/r/r.mojo  -> t//src/r:r         depends on heavy (a check of its own that needs it)
#
# Two rows: heavy owned by `src/h/**` and `ci/**` with roots h_root and r, heavy2 owned by `src/g/**` with root g_root.

_H_FILES = {
    "src/a/a.mojo": True,
    "src/h/h.mojo": True,
    "src/g/g.mojo": True,
    "src/r/r.mojo": True,
    "tools/build/x.zig": True,
    "ci/BUCK": True,
    "ci/targets.bzl": True,
}
_H_OWNERS = {
    "src/a/a.mojo": ["t//src/a:a"],
    "src/h/h.mojo": ["t//src/h:heavy"],
    "src/g/g.mojo": ["t//src/g:heavy2"],
    "src/r/r.mojo": ["t//src/r:r"],
    "ci/targets.bzl": ["t//ci:pr"],
}
_H_DEPENDENTS = {
    "t//src/a:a": ["t//src/a:a_test", "t//src/h:heavy", "t//src/g:heavy2"],
    "t//src/h:heavy": ["t//src/h:h_root", "t//src/r:r"],
    "t//src/g:heavy2": ["t//src/g:g_root"],
}

_H_GRAPH = struct(
    exists = lambda p: p in _H_FILES,
    owners = lambda p: _H_OWNERS.get(p, []),
    package_targets = lambda d: [],
    including = lambda p: [],
    rdeps = lambda seeds: _reverse_closure(_H_DEPENDENTS, seeds),
)

_H = ("t//src/h:heavy", ["src/h/**", "ci/**"], ["t//src/h:h_root", "t//src/r:r"], "one compile")
_G = ("t//src/g:heavy2", ["src/g/**"], ["t//src/g:g_root"], "another compile")

_H_WIDEN = [("tools/build/**", "the build system")]

_AGG = "t//ci:pr"
_DEFAULT = "t//ci:pr_default"

def _labels(heavy, changed):
    rules = struct(widen = _H_WIDEN, inert = [], heavy = heavy)
    v = select(rules, changed, _H_GRAPH, "ci")
    if v.kind not in [AFFECTED, WIDENED]:
        return "the verdict is " + v.kind
    return sorted(plan(rules, changed, _H_GRAPH, v, _AGG, _DEFAULT)[0])

def _plan_cases():
    out = []
    a_all = ["t//src/a:a", "t//src/a:a_test"]
    reach_of_a = a_all + ["t//src/h:heavy", "t//src/h:h_root", "t//src/r:r", "t//src/g:heavy2", "t//src/g:g_root"]

    def case(name, heavy, changed, wanted):
        got = _labels(heavy, changed)
        if got != sorted(wanted):
            out.append("heavy: {}: {}, wanted {}".format(name, got, sorted(wanted)))

    # a change that owns nothing of a row loses the row's target and everything above it
    case("a change outside both rows loses both and what depends on them", [_H, _G], ["src/a/a.mojo"], a_all)
    case("a change that owns one row keeps that row only", [_H, _G], ["src/g/g.mojo"], ["t//src/g:heavy2", "t//src/g:g_root"])
    case("a change of both rows' own keeps what each reaches", [_H, _G], ["src/g/g.mojo", "src/h/h.mojo"], ["t//src/g:heavy2", "t//src/g:g_root", "t//src/h:heavy", "t//src/h:h_root", "t//src/r:r"])
    case("a leaf and an own file keep every target of the leaf's reach that the owned row reaches", [_H], ["src/a/a.mojo", "src/h/h.mojo"], reach_of_a)
    case("a check that depends on the heavy target is left out with it", [_H], ["src/r/r.mojo"], [_DEFAULT])

    # no row, or every row owned: the verdict as it was
    case("with no rows the verdict is unchanged", [], ["src/a/a.mojo"], reach_of_a)
    case("with no rows a widening is the full aggregate", [], ["tools/build/x.zig"], [_AGG])

    # a widening, whichever file made it
    case("a widening that owns nothing is the default aggregate", [_H, _G], ["tools/build/x.zig"], [_DEFAULT])
    case("a widening with one row's own file is the default and that row's roots", [_H, _G], ["tools/build/x.zig", "src/g/g.mojo"], [_DEFAULT, "t//src/g:g_root"])
    case("a widening with the roots of a row with two of them", [_H, _G], ["tools/build/x.zig", "src/h/h.mojo"], [_DEFAULT, "t//src/h:h_root", "t//src/r:r"])
    case("a widening that owns every row is the full aggregate", [_H, _G], ["tools/build/x.zig", "src/h/h.mojo", "src/g/g.mojo"], [_AGG])
    case("a change to the aggregate's own files owns the row that names ci/**, not the other", [_H, _G], ["ci/targets.bzl"], [_DEFAULT, "t//src/h:h_root", "t//src/r:r"])

    # the note of a left-out row names where the rows live: `heavy_where`, "HEAVY" by default
    rules = struct(widen = _H_WIDEN, inert = [], heavy = [_G])
    v = select(rules, ["src/a/a.mojo"], _H_GRAPH, "ci")
    _, notes = plan(rules, ["src/a/a.mojo"], _H_GRAPH, v, _AGG, _DEFAULT)
    if notes != ["left out of the pull request's set (the change owns nothing of them, HEAVY): t//src/g:heavy2"]:
        out.append("heavy: the note of a left-out row, by default: {}".format(notes))
    _, notes = plan(rules, ["src/a/a.mojo"], _H_GRAPH, v, _AGG, _DEFAULT, heavy_where = "the rows file HEAVY")
    if notes != ["left out of the pull request's set (the change owns nothing of them, the rows file HEAVY): t//src/g:heavy2"]:
        out.append("heavy: the note of a left-out row names heavy_where: {}".format(notes))
    return out

def _split_cases():
    out = []
    wanted, left = heavy_split(struct(heavy = [_H, _G]), ["src/h/h.mojo", "docs/a.md", ""])
    if [r[0] for r in wanted] != ["t//src/h:heavy"] or [r[0] for r in left] != ["t//src/g:heavy2"]:
        out.append("heavy split: wanted [heavy] and left [heavy2], got {} and {}".format([r[0] for r in wanted], [r[0] for r in left]))
    wanted, left = heavy_split(struct(heavy = [_H]), [])
    if wanted or len(left) != 1:
        out.append("heavy split: no changed file owns nothing, got wanted {}".format(wanted))
    for path in ["src/h", "src/hx/h.mojo", "src/g/g.mojo"]:
        wanted, _ = heavy_split(struct(heavy = [_H]), [path])
        if wanted:
            out.append("heavy split: '{}' is not under src/h/**".format(path))
    return out

# ---- affected_answer: the run without its printing ----------------------------------

_HELD_MESSAGE = "a held metric stays held"

def _config(**kwargs):
    return affected_config(**dict(dict(
        universe = ["t//..."],
        aggregate = _AGG,
        widen = _RULES.widen,
        inert = _RULES.inert,
    ), **kwargs))

def _keep_all(targets):
    return list(targets)

def _answer_cases():
    out = []

    def check(name, r, **wanted):
        for field, want in wanted.items():
            got = getattr(r, field)
            if got != want:
                out.append("answer: {}: {} is {!r}, wanted {!r}".format(name, field, got, want))

    table = _table()

    # AFFECTED: the labels, the log line with its counts, nothing excluded
    r = affected_answer(_config(), ["src/b/b.mojo", ""], table, _keep_all)
    check(
        "a leaf change",
        r,
        kind = AFFECTED,
        reason = "",
        labels = ["t//src/b:b", "t//src/c:c"],
        notes = [],
        warnings = [],
        log = "AFFECTED: 1 file(s), 2 target(s), 0 left out (EXCLUDED), 0 left out (HEAVY)",
        files = 1,
        reached = ["t//src/b:b", "t//src/c:c"],
        kept = ["t//src/b:b", "t//src/c:c"],
        excluded = 0,
    )

    # AFFECTED with one target excluded: counted in the log, dropped from the labels; an inert file's warning is carried
    r = affected_answer(_config(), ["src/b/b.mojo", "README.md"], table, lambda ts: [t for t in ts if t != "t//src/c:c"])
    check(
        "a leaf change with an excluded dependent",
        r,
        kind = AFFECTED,
        labels = ["t//src/b:b"],
        warnings = ["no target owns (inert): README.md"],
        log = "AFFECTED: 2 file(s), 1 target(s), 1 left out (EXCLUDED), 0 left out (HEAVY)",
        excluded = 1,
    )

    # WIDENED by a widen row: the aggregate, the reason in the log
    r = affected_answer(_config(), ["tools/build/x.zig"], table, _keep_all)
    check(
        "a widening",
        r,
        kind = WIDENED,
        reason = "'tools/build/x.zig' matches widen rule tools/build/**: the build system",
        labels = [_AGG],
        log = "WIDENED: 'tools/build/x.zig' matches widen rule tools/build/**: the build system",
        notes = [],
        warnings = [],
    )

    # --aggregate overrides the configuration's: the label a widening names and the package that widens
    r = affected_answer(_config(), ["src/b/b.mojo"], table, _keep_all, aggregate = "t//src/b:all")
    check("an aggregate given on the command line", r, kind = WIDENED, labels = ["t//src/b:all"])
    if "aggregate's own package" not in r.reason:
        out.append("answer: an aggregate given on the command line: its package widens, reason {!r}".format(r.reason))

    # every target reached is excluded: the aggregate, with the configuration's name for the rows
    r = affected_answer(_config(), ["src/b/b.mojo"], table, lambda ts: [])
    check(
        "every target excluded",
        r,
        kind = WIDENED,
        reason = "every target reached is left out of the aggregate (EXCLUDED)",
        labels = [_AGG],
        log = "WIDENED: every target reached is left out of the aggregate (EXCLUDED)",
        reached = ["t//src/b:b", "t//src/c:c"],
        kept = [],
        excluded = 2,
    )
    r = affected_answer(_config(where = struct(excluded = "the rows file EXCLUDED", heavy = "the rows file HEAVY")), ["src/b/b.mojo"], table, lambda ts: [])
    check("every target excluded, `where` named", r, reason = "every target reached is left out of the aggregate (the rows file EXCLUDED)")

    # heavy rows through the answer: a widening that owns none is the default set, with the note naming `where.heavy`
    heavy = _config(widen = _H_WIDEN, inert = [], heavy = [_G], default = _DEFAULT, where = struct(excluded = "E", heavy = "the rows file HEAVY"))
    r = affected_answer(heavy, ["tools/build/x.zig"], _H_GRAPH, _keep_all)
    check(
        "a widening with a heavy row left out",
        r,
        kind = WIDENED,
        labels = [_DEFAULT],
        notes = ["left out of the pull request's set (the change owns nothing of them, the rows file HEAVY): t//src/g:heavy2"],
    )
    r = affected_answer(heavy, ["src/a/a.mojo"], _H_GRAPH, _keep_all)
    check(
        "an affected answer with a heavy row left out",
        r,
        kind = AFFECTED,
        labels = ["t//src/a:a", "t//src/a:a_test", "t//src/h:h_root", "t//src/h:heavy", "t//src/r:r"],
        log = "AFFECTED: 1 file(s), 5 target(s), 0 left out (EXCLUDED), 2 left out (HEAVY)",
    )

    # every target excluded with heavy rows: the default set, the left-out row's note naming `where.heavy`, the reason `where.excluded`
    r = affected_answer(heavy, ["src/a/a.mojo"], _H_GRAPH, lambda ts: [])
    check(
        "every target excluded, a heavy row left out",
        r,
        kind = WIDENED,
        reason = "every target reached is left out of the aggregate (E)",
        labels = [_DEFAULT],
        notes = ["left out of the pull request's set (the change owns nothing of them, the rows file HEAVY): t//src/g:heavy2"],
    )

    # every target reached depends on a left-out row: the default set, with the note saying so
    r = affected_answer(_config(widen = _H_WIDEN, inert = [], heavy = [_H], default = _DEFAULT), ["src/r/r.mojo"], _H_GRAPH, _keep_all)
    check(
        "every reached target depends on a left-out row",
        r,
        kind = AFFECTED,
        labels = [_DEFAULT],
        notes = [
            "left out of the pull request's set (the change owns nothing of them, HEAVY): t//src/h:heavy",
            "every target reached depends on a left-out target: the default set",
        ],
        log = "AFFECTED: 1 file(s), 1 target(s), 0 left out (EXCLUDED), 0 left out (HEAVY)",
    )

    # a widening by an unowned file carries its warning; a path named twice is one file
    r = affected_answer(_config(), [".hidden", ".hidden", "src/b/b.mojo"], table, _keep_all)
    check("an unowned file widens with its warning", r, kind = WIDENED, labels = [_AGG], warnings = ["no target owns: .hidden"], files = 2)

    # EMPTY and VACUOUS: the verdict's kind and reason, no labels
    r = affected_answer(_config(), ["", ""], table, _keep_all)
    check("no file", r, kind = EMPTY, reason = "the change names no file", labels = [], files = 0)
    r = affected_answer(_config(), ["README.md", "gone/NOTES.md"], table, _keep_all)
    check(
        "inert files alone",
        r,
        kind = VACUOUS,
        reason = "the 2 changed file(s) reach no target: README.md, gone/NOTES.md",
        labels = [],
        warnings = ["no target owns (inert): README.md", "deleted file no package holds (inert): gone/NOTES.md"],
    )

    # VACUOUS names at most five files, and says so when there are more
    five = ["gone/{}.md".format(i) for i in range(5)]
    r = affected_answer(_config(), five, table, _keep_all)
    check("five inert files", r, kind = VACUOUS, reason = "the 5 changed file(s) reach no target: " + ", ".join(five))
    r = affected_answer(_config(), five + ["gone/5.md"], table, _keep_all)
    check("six inert files", r, kind = VACUOUS, reason = "the 6 changed file(s) reach no target: " + ", ".join(five) + " ...")

    # BROKEN: a dropped hold, before any selection (no warning, no label), with the configuration's message
    marker = "src/a/" + _MARKER_NAME
    lines = ["abc123:{}:1:line".format(marker), "abc123:{}:2:branch".format(marker), "HEAD:{}:1:line".format(marker)]
    held = _config(held = held_config(file = _MARKER_NAME, message = _HELD_MESSAGE))
    r = affected_answer(held, [marker, "README.md"], table, _keep_all, lines)
    check(
        "a dropped hold",
        r,
        kind = BROKEN,
        reason = "a coverage hold was dropped (a held metric stays held): src/a/held_marker: branch is no longer held",
        labels = [],
        warnings = [],
        files = 2,
    )

    # the hold check reads `head`: with another head name every line is the base's, so the marker reads as deleted while its package stays
    r = affected_answer(held, [marker], table, _keep_all, lines[:2] + ["tip:{}:1:line".format(marker), "tip:{}:2:branch".format(marker)], head = "tip")
    check("a hold kept, head named", r, kind = AFFECTED, labels = _A_AND_DEPENDENTS)
    r = affected_answer(held, [marker], table, _keep_all, lines[:2] + ["tip:{}:1:line".format(marker), "tip:{}:2:branch".format(marker)])
    check("a hold read with the wrong head name", r, kind = BROKEN)

    # with no `held`, the held lines are not read: the same change is a selection (the marker is gone from the table, so its package), not BROKEN
    r = affected_answer(_config(), [marker], table, _keep_all, lines)
    check("no hold configured: the lines are ignored", r, kind = AFFECTED, labels = _A_AND_DEPENDENTS)
    r = affected_answer(_config(), ["src/b/b.mojo"], table, _keep_all, ["not a held line"])
    check("no hold configured: a malformed line is not read", r, kind = AFFECTED)
    return out

def _json_cases():
    out = []
    r = struct(kind = AFFECTED, reason = "", labels = ["t//a:a", "t//b:b"], notes = [], warnings = ["w"], files = 3)
    got = answer_json(r)
    want = '{"schema":1,"verdict":"AFFECTED","reason":"","labels":["t//a:a","t//b:b"],"notes":[],"warnings":["w"],"files":3}'
    if got != want:
        out.append("json: an affected answer: {}, wanted {}".format(got, want))
    r = struct(kind = WIDENED, reason = "a \"quoted\" reason", labels = [_AGG], notes = ["n"], warnings = [], files = 1)
    got = answer_json(r)
    want = '{"schema":1,"verdict":"WIDENED","reason":"a \\"quoted\\" reason","labels":["t//ci:pr"],"notes":["n"],"warnings":[],"files":1}'
    if got != want:
        out.append("json: a widened answer: {}, wanted {}".format(got, want))
    if json.decode(answer_json(affected_answer(_config(), ["src/b/b.mojo"], _table(), _keep_all))) != {
        "schema": 1,
        "verdict": AFFECTED,
        "reason": "",
        "labels": ["t//src/b:b", "t//src/c:c"],
        "notes": [],
        "warnings": [],
        "files": 1,
    }:
        out.append("json: the answer of a leaf change does not decode to its fields")
    return out

# ---- affected_output: what a run prints ----------------------------------------------

def _output_cases():
    out = []

    def check(name, got, log, failure, stdout):
        want = struct(log = log, failure = failure, stdout = stdout)
        if got != want:
            out.append("output: {}: {}, wanted {}".format(name, got, want))

    table = _table()
    labels = ["t//src/b:b", "t//src/c:c"]
    affected = affected_answer(_config(), ["src/b/b.mojo", "README.md"], table, _keep_all)
    affected_log = [
        "affected: warning: no target owns (inert): README.md",
        "affected: AFFECTED: 2 file(s), 2 target(s), 0 left out (EXCLUDED), 0 left out (HEAVY)",
    ]

    # the log in its order (warnings, the verdict's line, the notes); stdout the labels, or one line of JSON
    check("affected, labels", affected_output(affected, "labels"), affected_log, "", labels)
    check("affected, json", affected_output(affected, "json"), affected_log, "", [answer_json(affected)])
    heavy = _config(widen = _H_WIDEN, inert = [], heavy = [_G], default = _DEFAULT)
    widened = affected_answer(heavy, ["tools/build/x.zig"], _H_GRAPH, _keep_all)
    check("widened with a note, labels", affected_output(widened, "labels"), [
        "affected: WIDENED: 'tools/build/x.zig' matches widen rule tools/build/**: the build system",
        "affected: left out of the pull request's set (the change owns nothing of them, HEAVY): t//src/g:heavy2",
    ], "", [_DEFAULT])

    # EMPTY, VACUOUS and BROKEN fail in either format, after their warnings, and print nothing on stdout
    for format in ["labels", "json"]:
        check("empty, " + format, affected_output(affected_answer(_config(), [], table, _keep_all), format), [], "EMPTY: the change names no file", [])
        check(
            "vacuous, " + format,
            affected_output(affected_answer(_config(), ["README.md"], table, _keep_all), format),
            ["affected: warning: no target owns (inert): README.md"],
            "VACUOUS: the 1 changed file(s) reach no target: README.md",
            [],
        )
        marker = "src/a/" + _MARKER_NAME
        broken = affected_answer(
            _config(held = held_config(file = _MARKER_NAME, message = _HELD_MESSAGE)),
            [marker],
            table,
            _keep_all,
            ["abc123:{}:1:line".format(marker)],
        )
        check("broken, " + format, affected_output(broken, format), [], "BROKEN: a coverage hold was dropped (a held metric stays held): src/a/held_marker: line is no longer held", [])

    # --format: labels and json, nothing else
    for format, want in [
        ("labels", ""),
        ("json", ""),
        ("yaml", "affected: --format is `labels` or `json`, not `yaml`"),
        ("", "affected: --format is `labels` or `json`, not ``"),
        ("JSON", "affected: --format is `labels` or `json`, not `JSON`"),
    ]:
        if format_refusal(format) != want:
            out.append("output: format_refusal({!r}) is {!r}, wanted {!r}".format(format, format_refusal(format), want))
    return out

def table_problems():
    """Every case that answered otherwise, one line each; [] when all hold."""
    return _table_cases() + _held_cases() + _plan_cases() + _split_cases() + _answer_cases() + _json_cases() + _output_cases()
