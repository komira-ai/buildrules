# rules/affected: the affected-target selector

The selector maps the files a change touches to the targets a pull request check must build and test: the targets that own the files and everything that depends on them within the check set.
It answers "the whole check set" (the aggregate) when a file cannot be mapped, and it fails, naming why, rather than answer something it cannot stand behind.

The library is generic. A consumer repository keeps its own data (the check set, the aggregate, the `widen`, `inert`, `heavy` and `excluded` rows, the name of its hold marker) and a thin `affected.bxl` that passes them in as one configuration value.
Nothing in this repository runs the selector except its own tests (`tests/`, `ci/affected.bzl`).

    load("@buildrules//rules/affected:defs.bzl", "affected_config", "affected_impl", "held_config")

## The wrapper

The script that is run must live in the repository whose files are asked about: `ctx.cell_root()`, `exists` and the owner query answer for the cell of the `.bxl` script that was run, not for the cell of the `.bzl` that calls them.
So each consumer keeps its own `affected.bxl`, and the library uses the `ctx` it is handed and never takes or guesses a cell root.
`bxl_main` and `cli_args` belong in the `.bxl`. A template:

```
load("@buildrules//rules/affected:defs.bzl", "affected_config", "affected_impl", "held_config")
load(":rules.bzl", "AGGREGATE", "UNIVERSE", "WIDEN", "INERT")

_CONFIG = affected_config(
    universe = UNIVERSE,            # ["root//...", ...]
    aggregate = AGGREGATE,          # "root//ci:pr"
    widen = WIDEN,                  # [("tools/build/**", "the build system"), ...]
    inert = INERT,                  # ["*.md", ...]
    held = held_config(file = "coverage_held", message = "a package that reached the target stays held"),
)

def _impl(ctx):
    affected_impl(ctx, _CONFIG)

affected = bxl_main(
    impl = _impl,
    cli_args = {
        "aggregate": cli_args.string(default = ""),
        "changed": cli_args.list(cli_args.string(), default = []),
        "format": cli_args.string(default = "labels"),
        "head": cli_args.string(default = "HEAD"),
        "held": cli_args.list(cli_args.string(), default = []),
        "scope": cli_args.list(cli_args.string(), default = []),
    },
)
```

`affected_impl` reads exactly these six names from `ctx.cli_args`, so the wrapper declares all six.
A BXL script reads no file: the changed paths come in as arguments. Buck2's client expands `@file` (one argument per line) only before the subcommand's `--`, so a consumer keeps two small argument files on disk, one holding the lines `--` and `--changed`, the other `--held`, and runs:

    buck2 bxl root//ci/affected.bxl:affected @ci/affected_changed.args @changed.txt @ci/affected_held.args @held.txt

where `changed.txt` is `git diff --no-renames --name-only <base>...HEAD` and `held.txt` is `git grep -n '' <base> HEAD -- '*<marker>'`.

## Configuration

`affected_config(...)` refuses a bad field with a message starting `affected_config: `; the refusal is `fail` unless the caller passes another `refuse` (tests pass a recorder and see every refusal of one call).
Every field except `universe` and `aggregate` is optional, so a field added later breaks no consumer.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `universe` | list of target patterns | required, not empty | The check set: the universe of the reverse-dependency query. |
| `aggregate` | label `cell//package:name` | required | The target that holds the whole check set. Its package is left out of the reverse-dependency universe; a change that seeds it widens. |
| `default` | label | `""` | The aggregate without the roots of the `heavy` rows. Required when `heavy` is not empty. |
| `excluded` | list of `(pattern, reason)` | `[]` | Targets dropped from every answer (target patterns). |
| `heavy` | list of `(target, own, roots, reason)` | `[]` | A check left out of a change that owns none of the `own` path patterns (see below). `roots` is not empty. |
| `widen` | list of `(pattern, reason)` | `[]` | A changed file matching one widens. |
| `inert` | list of patterns | `[]` | Files that build nothing: an unowned inert file is skipped with a warning; inert files alone are VACUOUS. |
| `held` | `None` or `held_config(file, message)` | `None` | The hold check. `None`: the `--held` lines are not read. |
| `where` | `None` or `struct(excluded, heavy)` | `struct(excluded = "EXCLUDED", heavy = "HEAVY")` | The names given to the `excluded` rows in the reason "every target reached is left out of the aggregate (<excluded>)" and to the `heavy` rows in the note of each left-out row. The `AFFECTED: ...` counts line always says `EXCLUDED` and `HEAVY`. |

Path patterns: `dir/**` and `text*` match by prefix, `*text` by suffix, anything else exactly.

## The mapping

For each changed file (paths relative to the cell root, as `git diff --name-only` prints them), the first rule that applies:

1. it matches a `widen` row: WIDENED at once;
2. it is gone at the head: a deleted `BUCK` widens (its package is gone); otherwise it seeds every target of the nearest package above it, or widens when no package holds it and no `inert` row names it;
3. a `BUCK` file seeds every target of its package;
4. a `.bzl` file seeds every target of every package whose `BUCK` file loads it, directly or through another `.bzl`, and the targets that list it; a `.bzl` no `BUCK` file loads widens;
5. any other file seeds the targets that own it; a file no target owns widens, unless an `inert` row names it.

No file is EMPTY. Files that seed nothing are VACUOUS. A seed in the aggregate's own package widens. A reverse-dependency query that answers nothing widens.
The aggregate's package is subtracted from the universe of the reverse-dependency query, but Buck2 answers `rdeps` over the universe's dependency closure: a target of the universe that depends on the aggregate brings it back. Keep such targets out of `universe`.
Otherwise the answer is AFFECTED: every target of the universe that depends on a seed, sorted and unique, without the `excluded` targets; if none is left it is WIDENED.
The `heavy` rows then apply to both: a row whose `own` patterns no changed file matches is left out. A WIDENED answer becomes `default` plus the roots of the rows the change does own (`aggregate` when it owns them all); an AFFECTED answer loses every target that depends on a left-out row's target, and is `default` if nothing is left.

## The command line

| Option | Type | Default | Meaning |
|---|---|---|---|
| `--changed` | list | `[]` | Changed paths, relative to the cell root. Blank elements are ignored. |
| `--held` | list | `[]` | `rev:path:lineno:text` lines of the hold markers, both revisions. Not read when `held` is `None`. A line with fewer than four `:` parts fails. |
| `--head` | string | `HEAD` | The revision name that marks the head's lines in `--held`. |
| `--scope` | list | `[]` | Target patterns; empty means the configuration's `universe`. |
| `--aggregate` | string | `""` | The aggregate label; empty means the configuration's `aggregate`. |
| `--format` | string | `labels` | `labels` or `json`; anything else fails. |

## Output

stdout, `--format labels` (the default): one label per line and nothing else.

- AFFECTED: the labels after the `excluded` and `heavy` filtering.
- WIDENED: the aggregate, or with `heavy` rows left out, `default` plus the roots of the rows the change owns.

stdout, `--format json`: exactly one line, and no label lines:

    {"schema":1,"verdict":"AFFECTED","reason":"","labels":[...],"notes":[...],"warnings":[...],"files":N}

`verdict` is `AFFECTED` or `WIDENED`; `reason` is `""` for AFFECTED and the widening's reason for WIDENED; `labels` is what `--format labels` prints; `files` is the number of distinct changed paths.
New keys may be added; `schema` changes only when a key is removed or changes meaning.

The log (Buck2 prints it on stderr), each line prefixed `affected: `, in this order: `warning: ...` lines, then `WIDENED: <reason>` or `AFFECTED: <n> file(s), <n> target(s), <n> left out (EXCLUDED), <n> left out (HEAVY)`, then the notes of the `heavy` rows.

## Failures

The command fails (Buck2 exits non-zero; the exact value is Buck2's and not part of this contract) in either format, with the kind as the message's prefix:

| Kind | Message starts | When |
|---|---|---|
| EMPTY | `EMPTY: ` | no non-blank changed path |
| VACUOUS | `VACUOUS: ` | the files seed nothing (all inert, or deleted and inert) |
| BROKEN | `BROKEN: a coverage hold was dropped (<message>): ` | a hold marker the change names lost a metric while its package stays (only with `held`) |
| Buck2's own error | (Buck2's text) | a query fails, a `--held` line is malformed, or `--format` is neither `labels` nor `json` |

A failed query is never caught: a broken graph must not widen or pass.

## Platforms

The selector reads the unconfigured graph (`uquery`) and the files of the checkout, and nothing else:

1. The output is a function of the changed paths, the files of the working tree at the head, the unconfigured graph of the scope, and the configuration. It does not depend on the host, the execution platform or `--target-platforms`.
2. Run it once: the same labels (and with `--format json` the same verdict) serve every platform, each built with its own `--target-platforms`.
3. The list is a superset across platforms: the unconfigured graph holds targets that are incompatible with a given platform, and a `select()` contributes the dependencies of all its branches. `buck2 build` fails on a label it is given that is incompatible with the target platform; `buck2 build --skip-incompatible-targets` skips it and names it in the log. A per-platform build of the list passes that flag (or filters the list).
4. A `-c` or `--config-file` that changes which targets a BUCK file declares must be given to the selector as well as to the builds; one that only registers execution platforms need not.
5. WIDENED names the aggregate, a target of the consumer's graph. Mapping it to a platform's own check set is the consumer's.
6. `exists` reads the checkout it runs in: a stage that runs the selector again needs the same commit checked out, or reuses the first stage's output.

## Tests

- `tests/BUCK`: the refusals of `affected_config` (analysis tests, `rules/rust/refusal.bzl`), and `tests/cases.bzl` `table_problems()` over graphs written out in that file (the mapping, the holds, the `heavy` rows, `affected_answer`, `answer_json`, and `affected_output`: what a run prints and fails with, in either format), failing the load of the package with the name of each case that answers otherwise. `//ci:refusals` builds them.
- `ci/affected.bzl`: the same functions over Buck2's real answers for the fixture `ci/affected_fixture` (owners, build files, the loaders of a `.bzl`, reverse dependencies, `without_left_out`), run by `buck2 bxl //ci:completeness.bxl:check` and alone by `buck2 bxl //ci:affected.bxl:check`.
