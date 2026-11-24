"""The mapping: the files of a change -> the targets it affects.

A pure function over a graph facade `g`, so the cases (tests/cases.bzl) answer it from tables and ci/affected.bzl from the real graph.
The rules, in this order, for each changed file (paths are relative to the cell, as `git diff --name-only` prints them from the
repository root):

  1. a file matching a `widen` row widens: the answer is the whole check set;
  2. a file the change no longer has seeds every target of the nearest package above it (a deleted BUCK file widens: its package
     is gone);
  3. a `BUCK` file seeds every target of its package;
  4. a `.bzl` file seeds every target of every package whose BUCK file loads it (and the targets that list it);
  5. any other file seeds the targets that own it; a file no target owns widens, unless an `inert` row names it (it builds
     nothing).

The answer is the seeds and everything that depends on one of them within the check set, minus the aggregate package (the aggregate
depends on everything, so it would be selected for every change). It never under-approximates: a file the rules above cannot map
widens, with the reason; a change that seeds the aggregate package itself (its list) widens; a change whose files reach no target is
VACUOUS and a change of no file is EMPTY, never a pass.

A failed query is not caught here: it fails the script with Buck2's own error, so a broken graph never widens or passes.

The facade `g` has: exists(path) -> bool (at the head); owners(path) -> [label]; package_targets(dir) -> [label]; including(bzl) ->
[label]; rdeps(seeds) -> [label]. Labels are strings `cell//package:name`.
"""

AFFECTED = "AFFECTED"
WIDENED = "WIDENED"
VACUOUS = "VACUOUS"
EMPTY = "EMPTY"
BROKEN = "BROKEN"

def affected_rules(widen, inert, heavy):
    """The rows `select` and `plan` read: struct(widen, inert, heavy)."""
    return struct(widen = widen, inert = inert, heavy = heavy)

def pattern_matches(pattern, path):
    """`dir/**` and `text*` match by prefix, `*text` by suffix, anything else exactly."""
    if pattern.endswith("/**"):
        return path.startswith(pattern[:-2])
    if pattern.endswith("*"):
        return path.startswith(pattern[:-1])
    if pattern.startswith("*"):
        return path.endswith(pattern[1:])
    return path == pattern

def widen_reason(rules, path):
    """`<pattern>: <reason>` of the first `widen` row `path` matches, or ""."""
    for row in rules.widen:
        if pattern_matches(row[0], path):
            return row[0] + ": " + row[1]
    return ""

def is_inert(rules, path):
    for pattern in rules.inert:
        if pattern_matches(pattern, path):
            return True
    return False

def dirname(path):
    i = path.rfind("/")
    if i < 0:
        return ""
    return path[:i]

def basename(path):
    return path[path.rfind("/") + 1:]

def label_package(label):
    """`cell//package:name` -> `package`."""
    rest = label.split("//", 1)[1] if "//" in label else label
    return rest.split(":", 1)[0]

def nearest_package(g, path):
    """The directory of the nearest BUCK file above `path` at the head, or None."""
    d = dirname(path)
    for _ in range(64):
        buck = d + "/BUCK" if d else "BUCK"
        if g.exists(buck):
            return d
        if not d:
            return None
        d = dirname(d)
    return None

def _unique(xs):
    return sorted({x: True for x in xs}.keys())

def _widened(reason, files, warnings):
    return struct(kind = WIDENED, reason = reason, targets = [], files = files, warnings = warnings)

def select(rules, changed, g, aggregate_package):
    """The verdict for the changed files: struct(kind, reason, targets, files, warnings).

    `rules` is struct(widen, inert); `targets` is sorted and unique, only for
    AFFECTED; a WIDENED answer is the whole check set, which the caller names.
    """
    files = _unique([f for f in changed if f])
    warnings = []
    if not files:
        return struct(kind = EMPTY, reason = "the change names no file", targets = [], files = 0, warnings = warnings)
    seeds = []
    for f in files:
        why = widen_reason(rules, f)
        if why:
            return _widened("'{}' matches widen rule {}".format(f, why), len(files), warnings)
        if not g.exists(f):
            if basename(f) == "BUCK":
                return _widened("'{}' was deleted: its package is gone".format(f), len(files), warnings)
            d = nearest_package(g, f)
            if d == None:
                if is_inert(rules, f):
                    warnings.append("deleted file no package holds (inert): " + f)
                    continue
                return _widened("'{}' was deleted and no package holds it".format(f), len(files), warnings)
            seeds += g.package_targets(d)
            continue
        if basename(f) == "BUCK":
            seeds += g.package_targets(dirname(f))
            continue
        if f.endswith(".bzl"):
            including = g.including(f)
            if not including:
                return _widened("the .bzl file '{}' is loaded by no BUCK file".format(f), len(files), warnings)
            seeds += including
            seeds += g.owners(f)
            continue
        owners = g.owners(f)
        if owners:
            seeds += owners
        elif is_inert(rules, f):
            warnings.append("no target owns (inert): " + f)
        else:
            warnings.append("no target owns: " + f)
            return _widened("no target owns '{}' and no inert row names it".format(f), len(files), warnings)
    if not seeds:
        shown = files[:5]
        return struct(
            kind = VACUOUS,
            reason = "the {} changed file(s) reach no target: {}{}".format(len(files), ", ".join(shown), " ..." if len(files) > 5 else ""),
            targets = [],
            files = len(files),
            warnings = warnings,
        )
    seeds = _unique(seeds)
    for s in seeds:
        if label_package(s) == aggregate_package:
            return _widened("'{}' is in the aggregate's own package: its list changed".format(s), len(files), warnings)
    reached = g.rdeps(seeds)
    if not reached:
        return _widened("the reverse-dependency query of {} seed(s) answered nothing".format(len(seeds)), len(files), warnings)
    return struct(kind = AFFECTED, reason = "", targets = _unique(reached), files = len(files), warnings = warnings)

# ---- holds -------------------------------------------------------------
#
# A hold is a marker file (its basename is `held.file` of the configuration) whose non-blank, non-comment lines are metrics a package
# must keep. A change may add a marker or a metric; it may not take one away while the package stays.

def is_held_file(path, name):
    """Whether `path` is a hold marker: its basename is `name`."""
    return path == name or path.endswith("/" + name)

def _metrics(lines):
    return {l.strip(): True for l in lines if l.strip() and not l.strip().startswith("#")}

def parse_held_lines(lines, head_rev):
    """`git grep -n '' <base> <head_rev> -- '*<marker>'` lines
    (`rev:path:line number:text`) -> (base, head): path -> [text]."""
    base = {}
    head = {}
    for l in lines:
        parts = l.split(":", 3)
        if len(parts) < 4:
            fail("the held input has a line that is not `rev:path:number:text`: '{}'".format(l))
        into = head if parts[0] == head_rev else base
        into.setdefault(parts[1], []).append(parts[3])
    return base, head

def held_refusals(changed, base, head, g, name):
    """One message per hold the change drops: a metric the base held that the
    head's marker no longer has, or a marker deleted while its package stays.
    A marker that is new, gains a metric, or is deleted together with its
    package's BUCK file passes. Each only for a marker the change names;
    `name` is the marker's basename."""
    out = []
    for path in _unique([c for c in changed if is_held_file(c, name)]):
        if path not in base:
            continue
        was = _metrics(base[path])
        now = _metrics(head.get(path, []))
        if path not in head and not g.exists(dirname(path) + "/BUCK" if dirname(path) else "BUCK"):
            continue
        for m in sorted(was.keys()):
            if m not in now:
                out.append("{}: {} is no longer held".format(path, m))
    return out

# ---- the heavy checks ---------------------------------------------------

def heavy_split(rules, changed):
    """(wanted, left_out): the `heavy` rows of the configuration a changed file
    matches the `own` paths of, and the rows none does."""
    files = [f for f in changed if f]
    wanted = []
    left_out = []
    for row in rules.heavy:
        owned = False
        for f in files:
            for pattern in row[1]:
                if pattern_matches(pattern, f):
                    owned = True
        if owned:
            wanted.append(row)
        else:
            left_out.append(row)
    return wanted, left_out

def plan(rules, changed, g, verdict, aggregate, default, heavy_where = "HEAVY"):
    """The labels to build for an AFFECTED or WIDENED `verdict`, as (labels, notes).

    A `heavy` row of the configuration the change owns nothing of is left out: a
    WIDENED answer is `default` (the check set without the roots of every row)
    plus the roots of the rows the change does own, or `aggregate` when it owns
    all; an AFFECTED answer loses every target that depends on a left-out row's
    target (a row's own target and the checks above it), and is `default` if
    nothing is left. With no rows, or every row owned, the answer is the
    verdict's own. `heavy_where` names the rows in the note of each left-out row."""
    wanted, left_out = heavy_split(rules, changed)
    if not left_out:
        return ([aggregate] if verdict.kind == WIDENED else list(verdict.targets)), []
    notes = ["left out of the pull request's set (the change owns nothing of them, " + heavy_where + "): " + r[0] for r in left_out]
    if verdict.kind == WIDENED:
        labels = [default]
        for row in wanted:
            labels += row[2]
        return _unique(labels), notes
    gone = {}
    for row in left_out:
        for t in g.rdeps([row[0]]):
            gone[t] = True
    labels = [t for t in verdict.targets if t not in gone]
    if not labels:
        return [default], notes + ["every target reached depends on a left-out target: the default set"]
    return labels, notes

# ---- the answer ---------------------------------------------------------

def _answer(kind, reason, files, warnings, labels = [], notes = [], log = "", reached = [], kept = []):
    return struct(
        kind = kind,
        reason = reason,
        labels = labels,
        notes = notes,
        warnings = warnings,
        log = log,
        files = files,
        reached = reached,
        excluded = len(reached) - len(kept),
        kept = kept,
    )

def affected_answer(config, changed, g, drop_excluded, held_lines = [], head = "HEAD", aggregate = ""):
    """What a run of the selector answers, without printing or failing:
    struct(kind, reason, labels, notes, warnings, log, files, reached, excluded, kept).

    `kind` is AFFECTED, WIDENED, EMPTY, VACUOUS or BROKEN; `labels` are what stdout carries (AFFECTED and WIDENED only); `log` is the
    verdict's line of the log (without the `affected: ` prefix); `reached` the targets `select` reached, `kept` those `drop_excluded`
    kept, `excluded` how many it dropped. `drop_excluded(targets)` returns the targets that are not excluded. `aggregate` (empty: the
    configuration's) is the label a WIDENED answer names. A malformed `held_lines` entry fails (parse_held_lines): it is never read as
    no hold."""
    aggregate = aggregate or config.aggregate
    changed = [c for c in changed if c]
    rules = config.rules
    where = config.where
    if config.held:
        base, head_map = parse_held_lines(held_lines, head)
        dropped = held_refusals(changed, base, head_map, g, config.held.file)
        if dropped:
            return _answer(BROKEN, "a coverage hold was dropped (" + config.held.message + "): " + "; ".join(dropped), len(_unique(changed)), [])
    verdict = select(rules, changed, g, label_package(aggregate))
    if verdict.kind in [EMPTY, VACUOUS]:
        return _answer(verdict.kind, verdict.reason, verdict.files, verdict.warnings)
    if verdict.kind == WIDENED:
        labels, notes = plan(rules, changed, g, verdict, aggregate, config.default, where.heavy)
        return _answer(WIDENED, verdict.reason, verdict.files, verdict.warnings, labels, notes, "WIDENED: " + verdict.reason)
    kept = drop_excluded(verdict.targets)
    if not kept:
        # Every target the change reaches is left out of the aggregate on purpose: nothing to build but the aggregate itself, which
        # holds the rest of the check set.
        reason = "every target reached is left out of the aggregate (" + where.excluded + ")"
        labels, notes = plan(rules, changed, g, struct(kind = WIDENED, targets = []), aggregate, config.default, where.heavy)
        return _answer(WIDENED, reason, verdict.files, verdict.warnings, labels, notes, "WIDENED: " + reason, verdict.targets, kept)
    labels, notes = plan(rules, changed, g, struct(kind = AFFECTED, targets = kept), aggregate, config.default, where.heavy)
    log = "AFFECTED: {} file(s), {} target(s), {} left out (EXCLUDED), {} left out (HEAVY)".format(
        verdict.files,
        len(labels),
        len(verdict.targets) - len(kept),
        len(kept) - len(labels),
    )
    return _answer(AFFECTED, "", verdict.files, verdict.warnings, labels, notes, log, verdict.targets, kept)

JSON_SCHEMA = 1

def answer_json(r):
    """The one line `--format json` prints for an AFFECTED or WIDENED answer `r` (EMPTY, VACUOUS and BROKEN fail instead). Keys may be
    added; `schema` changes only when a key is removed or changes meaning."""
    return json.encode({
        "schema": JSON_SCHEMA,
        "verdict": r.kind,
        "reason": r.reason,
        "labels": r.labels,
        "notes": r.notes,
        "warnings": r.warnings,
        "files": r.files,
    })

FORMATS = ["labels", "json"]

def format_refusal(format):
    """"" for a `--format` the selector prints, else the message it fails with."""
    if format in FORMATS:
        return ""
    return "affected: --format is `labels` or `json`, not `{}`".format(format)

def affected_output(r, format):
    """What a run prints for the answer `r`: struct(log, failure, stdout). `log` are the lines of the log in order (the warnings, the
    verdict's line, the notes); `failure` is the message the run fails with ("" for AFFECTED and WIDENED, then `log` holds only the
    warnings); `stdout` are the lines of stdout: the labels, or with `format` `json` the one line of `answer_json`."""
    log = ["affected: warning: " + w for w in r.warnings]
    if r.kind in [EMPTY, VACUOUS, BROKEN]:
        return struct(log = log, failure = r.kind + ": " + r.reason, stdout = [])
    log.append("affected: " + r.log)
    log += ["affected: " + n for n in r.notes]
    return struct(log = log, failure = "", stdout = [answer_json(r)] if format == "json" else list(r.labels))
