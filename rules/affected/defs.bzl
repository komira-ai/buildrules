"""The affected-target selector: the files of a change -> the targets to build and test (README.md in this directory).

    load("@buildrules//rules/affected:defs.bzl", "affected_config", "affected_impl", "held_config")

A consumer repository keeps a thin `affected.bxl` (the template is in README.md) that builds its configuration with `affected_config` and
calls `affected_impl(ctx, config)` from its `bxl_main`. The other names are here for a consumer's own cases. This file loads nothing but
its siblings: a selector run does not depend on any execution-platform configuration.
"""

load(":config.bzl", _affected_config = "affected_config", _held_config = "held_config")
load(":graph.bzl", _make_graph = "make_graph", _without_left_out = "without_left_out")
load(
    ":select.bzl",
    _AFFECTED = "AFFECTED",
    _BROKEN = "BROKEN",
    _EMPTY = "EMPTY",
    _VACUOUS = "VACUOUS",
    _WIDENED = "WIDENED",
    _affected_answer = "affected_answer",
    _affected_output = "affected_output",
    _answer_json = "answer_json",
    _format_refusal = "format_refusal",
    _heavy_split = "heavy_split",
    _held_refusals = "held_refusals",
    _is_held_file = "is_held_file",
    _is_inert = "is_inert",
    _label_package = "label_package",
    _parse_held_lines = "parse_held_lines",
    _pattern_matches = "pattern_matches",
    _plan = "plan",
    _select = "select",
    _widen_reason = "widen_reason",
)

AFFECTED = _AFFECTED
WIDENED = _WIDENED
VACUOUS = _VACUOUS
EMPTY = _EMPTY
BROKEN = _BROKEN
affected_config = _affected_config
held_config = _held_config
affected_answer = _affected_answer
affected_output = _affected_output
answer_json = _answer_json
select = _select
plan = _plan
heavy_split = _heavy_split
pattern_matches = _pattern_matches
widen_reason = _widen_reason
is_inert = _is_inert
label_package = _label_package
is_held_file = _is_held_file
parse_held_lines = _parse_held_lines
held_refusals = _held_refusals
make_graph = _make_graph
without_left_out = _without_left_out

def affected_impl(ctx, config):
    """The body of a consumer's `bxl_main`. Reads `ctx.cli_args`: changed, held, head, scope, aggregate, format (README.md).

    stdout: with `--format labels`, one label per line; with `--format json`, one line (`answer_json`). The log (`print`, prefix
    `affected: `): the warnings, the verdict's line, the notes. EMPTY, VACUOUS and BROKEN fail with `<KIND>: <reason>` in either format;
    a failed query fails with Buck2's own error."""
    a = ctx.cli_args
    refusal = _format_refusal(a.format)
    if refusal:
        fail(refusal)
    scope = a.scope or config.universe
    aggregate = a.aggregate or config.aggregate
    g = _make_graph(ctx, scope, aggregate.split(":")[0] + ":")
    left_out = [p for p, _ in config.excluded]
    r = _affected_answer(
        config,
        [c for c in a.changed if c],
        g,
        lambda targets: _without_left_out(ctx, targets, left_out),
        [l for l in a.held if l],
        a.head,
        aggregate,
    )
    out = _affected_output(r, a.format)
    for line in out.log:
        print(line)
    if out.failure:
        fail(out.failure)
    for line in out.stdout:
        ctx.output.print(line)
