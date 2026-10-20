"""One target's test actions, run again: `-c buildrules.rerun=<label>#<n>`.

A cached result is a pass on identical inputs, so a test is never re-run
just because it was asked to be (and `--no-remote-cache` would re-run every
action of the build). To run one target's tests fresh, a single buckconfig
value names it:

    ./buck2 build //src/foo:foo -c buildrules.rerun='//src/foo:foo#1'

Every test action of the named target (the actions that run a test, below)
gets one more environment variable, `BUILDRULES_RERUN=<n>`. The environment is
part of an action's key, so those actions miss the cache and run; every other
action, of that target and of every other, keeps its key and stays a cache
hit. A new `<n>` runs them again; the same `<n>` is a cache hit of that run.
Users never set it; the bisect tool does, and a person may by hand.

The value is a comma-separated list of `<cell>//<package>:<name>#<n>`: the
target's label with its cell, without a configuration or sub-target, and
`<n>` a whole number from 1. A label matches the target of that cell,
package and name in every configuration. A value that is not of that form,
or that names a label twice, fails the analysis of every rule that reads it,
with the reason. Whether a label names a target that runs tests is not
something one target's analysis can know: check.bxl (README.md) refuses
one that does not.

The rules that call `rerun_env` (README.md lists them) declare
`RERUN_ATTRS`, whose default is the value of the root cell's `[buildrules]
rerun` (`[buildrules] rerun` is accepted as an alias), read when this file is loaded: the attribute is part of each
target, so a new value re-analyses every target that declares it, and
changes the actions only of the targets it names.
"""

RERUN_ENV = "BUILDRULES_RERUN"

# `[buildrules] rerun`.
_RAW = read_root_config("buildrules", "rerun", "")

# The value, for check.bxl.
RERUN_CONFIG = _RAW

# Every rule that calls rerun_env declares this attribute. Hidden: a BUCK
# file cannot set it.
RERUN_ATTRS = {"_rerun": attrs.string(default = _RAW)}

# The rules that call rerun_env return this provider too, so check.bxl can
# refuse a label that names a target running no test action.
RerunInfo = provider(
    doc = "Returned by every rule whose test actions take `BUILDRULES_RERUN`.",
    fields = {"label": provider_field(str)},
)

_LABEL = "^[A-Za-z0-9_][A-Za-z0-9_.-]*//[^:#,()\\[\\] ]*:[^:#,()\\[\\] ]+$"

def parse_rerun(raw):
    """`[buildrules] rerun` as {label: n}; fails, naming the entry and why,
    unless every entry is `<cell>//<package>:<name>#<n>`."""
    runs = {}
    raw = raw.strip()
    if not raw:
        return runs
    for entry in raw.split(","):
        entry = entry.strip()
        where = "[buildrules] rerun = {}: the entry {}".format(repr(raw), repr(entry))
        if not entry:
            fail("[buildrules] rerun = {}: an empty entry; give `<cell>//<package>:<name>#<n>`, comma-separated".format(repr(raw)))
        if "#" not in entry:
            fail("{} has no `#<n>`; give `<cell>//<package>:<name>#<n>`".format(where))
        i = entry.rfind("#")
        label, n = entry[:i].strip(), entry[i + 1:].strip()
        if not regex_match("^[1-9][0-9]*$", n):
            fail("{}: `{}` is not a whole number from 1".format(where, n))
        if label.startswith("//"):
            fail("{}: name the cell, as `buildrules{}` or `<cell>{}`".format(where, label, label))
        if "[" in label or "(" in label:
            fail("{}: name the target, without a sub-target or a configuration".format(where))
        if not regex_match(_LABEL, label):
            fail("{}: `{}` is not a target label `<cell>//<package>:<name>`".format(where, label))
        if label in runs:
            fail("[buildrules] rerun = {}: {} is named twice".format(repr(raw), label))
        runs[label] = n
    return runs

def rerun_env(ctx):
    """The environment every test action of `ctx`'s target adds:
    `{"BUILDRULES_RERUN": n}` when `[buildrules] rerun` names this target (its
    label without the configuration), else nothing. The rule declares
    RERUN_ATTRS."""
    n = parse_rerun(ctx.attrs._rerun).get(str(ctx.label.raw_target()))
    return {RERUN_ENV: n} if n != None else {}

def rerun_info(ctx):
    return RerunInfo(label = str(ctx.label.raw_target()))

