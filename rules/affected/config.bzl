"""The configuration of the selector: the rows of a consumer repository, as one value.

`affected_config(...)` checks each field and refuses a bad one (the message starts `affected_config: `). It goes on after a refusal, so a
recorder (rules/rust/refusal.bzl) sees every message, and it never fails on a bad value itself: the default `refuse` is `fail`, which
stops at the first. Every field but `universe` and `aggregate` is optional, so a field added later breaks no consumer.
"""

load(":select.bzl", "affected_rules")

_WHERE = struct(excluded = "EXCLUDED", heavy = "HEAVY")

def held_config(file, message):
    """A hold check: `file` is the marker's basename, `message` the text of `BROKEN: a coverage hold was dropped (<message>): ...`."""
    return struct(file = file, message = message)

def _is_str(x):
    return type(x) == "string"

def _is_label(x):
    """`<cell>//<package>:<name>`: a `//` and a `:` after it."""
    return _is_str(x) and "//" in x and ":" in x.split("//", 1)[1]

def _is_str_list(x):
    return type(x) == "list" and all([_is_str(e) for e in x])

def _rows(name, rows, refuse):
    """Refuses `rows` unless it is a list of (pattern, reason), both strings."""
    if type(rows) != "list":
        refuse("affected_config: {} is a list of (pattern, reason), not {!r}".format(name, rows))
        return
    for row in rows:
        if type(row) != "tuple" or len(row) != 2 or not _is_str(row[0]) or not _is_str(row[1]):
            refuse("affected_config: {} row {!r} is not (pattern, reason), two strings".format(name, row))

def _heavy_rows(heavy, refuse):
    if type(heavy) != "list":
        refuse("affected_config: heavy is a list of (target, own, roots, reason), not {!r}".format(heavy))
        return
    for row in heavy:
        ok = type(row) == "tuple" and len(row) == 4 and _is_str(row[0]) and _is_str_list(row[1]) and _is_str_list(row[2]) and row[2] != [] and _is_str(row[3])
        if not ok:
            refuse("affected_config: a heavy row is (target, own, roots, reason): a string, a list of strings, a non-empty list of strings and a string, not {!r}".format(row))

def _has_strings(x, fields):
    return type(x) == "struct" and all([hasattr(x, f) and _is_str(getattr(x, f)) for f in fields])

def affected_config(
        universe,
        aggregate,
        default = "",
        excluded = [],
        heavy = [],
        widen = [],
        inert = [],
        held = None,
        where = None,
        refuse = fail):
    """The configuration `affected_impl` and `affected_answer` read.

    universe  list of target patterns: the check set. Not empty.
    aggregate `cell//package:name`: the target that holds the whole check set; its package is left out of the reverse-dependency universe.
    default   label of the aggregate without the roots of the `heavy` rows. Required when `heavy` is not empty.
    excluded  [(pattern, reason)]: targets dropped from every answer.
    heavy     [(target, own, roots, reason)]: checks left out of a change that owns none of the `own` patterns (select.bzl, `plan`).
    widen     [(pattern, reason)]: a changed file matching one widens.
    inert     [pattern]: files that build nothing; alone they are VACUOUS.
    held      None (no hold check: the held lines are ignored), or held_config(file, message).
    where     None, or struct(excluded, heavy): the names of the `excluded` rows in the reason of an answer whose every target is excluded,
              and of the `heavy` rows in the note of a left-out row (default "EXCLUDED", "HEAVY"); the AFFECTED counts line always says
              EXCLUDED and HEAVY.
    refuse    how a bad value is refused (`fail`; a test passes a recorder).

    Patterns: `dir/**` and `text*` match by prefix, `*text` by suffix, anything else exactly."""
    if type(universe) != "list" or not universe:
        refuse("affected_config: universe is a non-empty list of target patterns, not {!r}".format(universe))
    elif not _is_str_list(universe):
        refuse("affected_config: universe holds target patterns (strings), not {!r}".format(universe))
    if not _is_label(aggregate):
        refuse("affected_config: aggregate is a label `<cell>//<package>:<name>`, not {!r}".format(aggregate))
    if not _is_str(default):
        refuse("affected_config: default is a label (a string), not {!r}".format(default))
    _rows("widen", widen, refuse)
    _rows("excluded", excluded, refuse)
    if type(inert) != "list":
        refuse("affected_config: inert is a list of patterns, not {!r}".format(inert))
    else:
        for p in inert:
            if not _is_str(p):
                refuse("affected_config: an inert entry is a pattern (a string), not {!r}".format(p))
    _heavy_rows(heavy, refuse)
    if heavy and not default:
        refuse("affected_config: heavy rows need default, the aggregate without their roots")
    if held != None and not _has_strings(held, ["file", "message"]):
        refuse("affected_config: held is None or held_config(file, message) with two strings, not {!r}".format(held))
    elif held != None and not held.file:
        refuse("affected_config: held names its marker file: held_config(file = ...) is empty")
    if where != None and not _has_strings(where, ["excluded", "heavy"]):
        refuse("affected_config: where is None or struct(excluded, heavy) with two strings, not {!r}".format(where))
    return struct(
        universe = universe,
        aggregate = aggregate,
        default = default,
        excluded = excluded,
        heavy = heavy,
        widen = widen,
        inert = inert,
        held = held,
        where = where if where != None else _WHERE,
        rules = affected_rules(widen, inert, heavy),
    )
