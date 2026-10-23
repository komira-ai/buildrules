# rules/coverage: kcov and the coverage path tools

Line coverage of Mojo tests (docs/contract.md, section 12),: the test is a debug build, linked through a `zig` that keeps
the line tables and rewrites the action's directories out of them, run under kcov, its Cobertura report mapped to repository paths. **linux x86_64 only.**

| target | what | origin |
|---|---|---|
| `:kcov` | kcov v42 built from source with the pinned zig 0.12: `bin/kcov`, `lib/libgcc_s.so.1` | `kcov_build`, `conda_payload`, `elf_rpath`, the curl shim |
| `:debug_relocate`, `:cov_zig` | the `real/zig`-fronting link directory of a coverage build (`cov_link`, one per Mojo version, in `toolchains//:mojo_<v>_cov_link`) | `cov_link` tools |
| `:cov_normalize` | a kcov report in repository paths, with bytes that do not depend on the run | same |
| `:cov_run` | runs one test binary under kcov in a tree of copies of its sources, then `cov_normalize` | new: the part a mopm unit needs |
| `:cov_summary` | the package's lines hit and recorded, from the reports; fails when a source of the library is in none | new |

Every tool is built behind its unit tests; the process cases of `cov_zig`, `debug_relocate` and `cov_normalize` are `zig_test`s that run the executable
and are validations of the public target.

Not included: kcov's own check suite (`kcov_check`, `loader_closure_check`, the identity and reproducibility checks), branch coverage of Mojo (kcov records none for a Mojo executable, and the
LLVM IR classifier behind `covcheck`'s branch records is not ported), `covcheck` (policy, holds, the census, the PR check run). The floors of the Zig, Node and Mojo packages are below.

## Mojo coverage

`mojo_package` (`rules/mojo/defs.bzl`, docs/contract.md section 12.4) builds each test again as a debug build and runs it under kcov (`:cov_run`, `:cov_normalize`); `cov_summary` folds the reports into `:coverage`.

| output | what |
|---|---|
| `:coverage` | `coverage.txt`: `<path> <hit>/<total> <n>%` per file, then `total`; a source with no executable line is `0/0`; red if a source of the library is in no report |
| `:coverage[reports]` | the per-line records the file was counted from: one Cobertura XML per test, `<line number hits>` per recorded line under a `<class filename>` in repository paths, branch attributes as kcov wrote them (none for Mojo today) |
| `:coverage_floor` | present only with a `coverage_floor.txt` beside the BUCK file; the check below |

`covcheck` takes the files of `:coverage[reports]` as `--cobertura` inputs, one per test: `buck2 build //pkg:coverage[reports] --show-full-output` prints their paths.

The floor is the file every package here uses (`coverage_floor.txt` next to the BUCK file, checked by `cov_floor`; a package with Zig tests names it in `zig_coverage`, a Node package in `jest_coverage_floor`),
so a Mojo package follows the Zig and Node ones and not an attribute: the figure sits in a file a reviewer sees change, the check is the one `cov_floor` already has, and no file means no check. A Mojo
floor file holds `lines NN.NN` only: a `branches` figure is refused ("the tests record no branches") because the reports hold none. It is a minimum (`coverage fell` below it; at or above it passes, and above it the check says the floor may be raised). kcov is GPL-2.0 and build-only: it runs in actions and is never packaged.

**No ASLR patch.** kcov disables address randomization with `personality(ADDR_NO_RANDOMIZE)` and stops when it fails. buildrules once let the run go on after a refusal (a farm sandbox answered ENOSYS); every farm node now allows the call, so kcov's own handling is kept. `kcov_build_test` fails if any patch touches that code.

## Zig coverage

Every package with Zig unit tests has a `zig_coverage(test_targets = [...], expect = [...])` and a `coverage_floor.txt` beside its BUCK file
(`zig_cover.bzl`). For each `zig_test` named it runs the same compile and the same environment again (the test's root, target, data and tools), but
built with LLVM's code generator and block counters, run under kcov, in one action (`zig_cover`, under `zig_launch run`); `:coverage` is the text of
`cov_summary` over all of them: lines hit and recorded per file, then the same for branches, then the totals over `expect`, the package's own sources.
`:coverage_floor` holds that text to the floor file (`cov_floor`), and `//ci:floors` groups every package's, so `//ci:all` builds them.

| target | what |
|---|---|
| `:zig_cover` | builds one test with `-fllvm -ffuzz` and `zig_cov_runner.zig` as its test runner, runs it under kcov, writes the Cobertura report (cov_normalize) and the block report |
| `zig_cov_runner.zig` | zig's own runner (every test, a fresh allocator each, a leak, a logged error or a failure fails the run), then writes one row per instrumented block |
| `:cov_summary` | with `--blocks`, the branch listing after the line listing; a block counts as hit when any test hit it |
| `:cov_floor` | the floor check; also `--jest-summary` for a jest `coverage-summary.json` (`jest_cover.bzl`) |

**Lines** are kcov's. They need `-fllvm`: with zig's own x86_64 backend kcov finds no line of the sources. The executable's debug information names the sources by
absolute path, so the build and the run are one action. kcov is told the directories of the included files, not the files: it refuses an option of more than a fixed
length ("Too long string!"), and a package of thirty files under a hosted runner's long working directory is longer. The report lists the files of those directories that the
executable holds code of; the summary counts only `expect`.

**Branches.** kcov records none for a Zig executable: its report has no `branch` attribute (a farm run of `cov_summary_test.zig` gave `grep -c 'branch="true"'`
= 0), the line table has no branch information. The figure comes from the compiler instead: `-ffuzz` has LLVM insert a counter in every basic block (sanitizer
coverage's inline 8-bit counters) and list the address of each; the runner resolves each address to a source position with the debug information of its own
executable and writes `<file> <line> <column> <blocks there that ran> <blocks there>` per position. A branch figure is blocks that ran over blocks there are.
What a block is: the entry of a function, each arm of an `if` or `switch`, the join after them, and the error return of every call made with `try` (that arm
is a block, as the `Err` arm of a Rust `?` is a branch in llvm-cov). Several blocks can share a position (both arms of a condition, or one block per
instantiation of a generic function); each is counted, so an arm that never ran is not hidden behind the arm that did. Blocks of the `test` blocks themselves
are left out (a passing test never runs the error exit of its assertions). zig 0.12 has no `-ffuzz`: the packages whose tests it builds (`ci`, and
`crate_patch` in `rules/rust`) have lines only, and their floor files have no `branches` line.

What both figures leave out:

- **Code the compiler emitted none for.** Zig analyses what is referenced, so a function no test reaches has no lines and no blocks, and the percentage is an
  upper bound. `expect` names a package's own sources; a file in it that no test compiled fails the summary (`... is in no report`), and the files a package
  leaves out of `expect` (an entry point no test imports, a file of constants) say why in its BUCK file. One exception, for Mojo: its report omits a source
  with no executable line, so `mojo_package` also gives `cov_summary` the text of each source (`--src <expected path>=<file>`), and an expected source that no
  report names but that holds nothing beyond comments, docstrings and `import` / `from ... import` statements (a re-export `__init__.mojo`) is listed as `0/0`
  instead of refused. Any other statement (a function, a struct, an assignment, a `;`, an indented line) leaves the source refused: a file the report merely
  missed is told from a file with nothing to run by reading it (`hasNoStatements` in `tools/cov_summary.zig`, strict by construction).
- **A block that one test runs exactly 255 more times (after an earlier test left its counter at 1).** The counters are one byte and wrap. The runner sets every non-zero counter to one between the tests, so a block that ran in
  one test is still a block that ran after the next tests run it (a counter that wrapped to zero used to read as a block that did not run); a single test that runs one block
  exactly 255 more times (the counter is 1 when the test starts, and 1 + 255 wraps to 0; 511 more, and so on) still reads it as unrun.
- **Code that runs in another process.** The counters are the test executable's own: a child it forks or executes keeps its own copy, written nowhere. kcov follows
  a fork, so the line figure has it; the branch figure does not. `rules/gate`'s tests run the code under test in forked children, so its branch figure is a floor far below the truth.
- **The process tests.** A test that runs a built executable (`*_exe_test`, `env_tools`) measures the executable's behaviour, not the sources it was built from; they are not in
  `test_targets`.
- The runner defines the callbacks instrumented code calls for a comparison, a switch and an indirect call as functions that do nothing: zig's own belong to its fuzzer,
  and a test that starts a thread crashed in them.

**The floor.** `coverage_floor.txt` holds `lines NN.NN` and `branches NN.NN` (hit over recorded, rounded down to a hundredth). A figure below its floor fails, naming the
fall; a figure at its floor passes; a figure above it passes too and the check prints `you may raise the floor to NN.NN` (to stderr and in the success output), which is optional. A figure the file has and the measurement lacks, or the other way,
fails. A figure that the tests do not reproduce (`rules/gate`'s tests race a clock and signals: the lines they reach differ by a few between machines) may be written
`lines 95.51 slack 1.00`: the hint to raise the floor is then given only above the floor plus the slack, and a fall below the floor fails. A pin bump of zig or kcov can move the numbers: raise or lower the floor in the same change and say why. The success output of `:coverage_floor` says how many more
hits the 99% target needs.

To add a package: `zig_coverage(test_targets = [":a_unit", ...], expect = ["pkg/a.zig", ...])` after its `zig_test` targets, a `coverage_floor.txt` with today's figures
(build `:coverage` and read its totals), and the package's `:coverage_floor` in `//ci:floors` (`ci/BUCK`; `ci/completeness.bxl` fails until it is).

## Jest coverage

`jest_test(coverage = True)` runs `jest --coverage` and its target is the `coverage` directory (the `coverage-summary.json` of the run, a text table on the log), which
exists only if the tests passed. The package's `jest.config.js` names its own code in `collectCoverageFrom`. `jest_coverage_floor()` (`jest_cover.bzl`) holds the `total`
lines and branches (istanbul's) to `coverage_floor.txt`, with the same check as above.
