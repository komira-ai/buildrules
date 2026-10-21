# Refusal tests

Every rule that refuses says so in a message that names what to change. A refusal that nobody tests can be deleted without a build going red, so each family has
tests that go red when the rule stops refusing. They live in `rules/<family>/tests` and are collected by `//rules/<family>/tests:all`, which `//ci:refusals` (and so
`//ci:all`) builds.

| family | analysis tests (the rule's checks, `checks.bzl`) | process tests (the tool, run over files the test writes) |
|---|---|---|
| core (shared) | `pinned_file`, `[buildrules] rerun`, `buildrules.url_map`, a test's data and environment | `proc.zig`, the module the process tests share |
| zig | target triple, optimize mode, module names, import names, `exec_tools`, the target and tests of a cross-built program | |
| cxx | `archive_files` | `prefix_tool`, `elfsyms`, `glibc_floor`, `hermetic`, `zig_cc_launcher` |
| node | `npm_package` (path, table, schema, node, srcs, actions), `npm_modules`, `node_tree_run`, `npm_tarball`, `node_test`, `jest_test` | `node_tools` |
| coverage | a coverage target with no test | `cov_floor` (a malformed or unmet floor), `cov_summary` |
| gate | | `rules/gate/refusal_test.zig` (through `gate.entry`) |
| kpin | | `rules/kpin/refusal_test.zig` (through `main.run`) |

The checks of the first column are functions of plain values that take `refuse`. A rule calls them with `fail`, so the build stops at the first refusal; a test calls them with
the recorder of `rules/rust/refusal.bzl` and `refuses(...)` is green only if the check refused and its message holds every string listed (`accepts(...)` is green only if it
did not, so a check that refuses everything is red too).

What a tool prints cannot be recorded that way. The process tests run the built tool with an empty environment in a directory of their own and read the exit status and
the whole message on stderr (`proc.expectRefusal`: the status, every fragment, and nothing on stdout). `gate` and `kpin` are tested through their entry points in the same way.

Refusals only a graph shows are planted in `ci/negative/BUCK` and held red by `buck2 bxl //ci:completeness.bxl:check` (`ci/negative.bzl`, `CASES`): a dependency of the wrong
kind for a Zig, C/C++ and Node rule (Buck2 refuses it before the rule runs), a coverage target with no test, and a cross-built program that waits for other tests. The same
list asserts the Mojo coverage fixture that has no test.

To add a refusal: put it in the family's `checks.bzl` (or the tool), call it from the rule, and add `refuses` beside its `accepts`. To see a test go red, make the check a
no-op and build the test: `./buck2 build //rules/zig/tests:zig_target_with_a_space_is_refused` fails with "expected a refusal and there was none".
