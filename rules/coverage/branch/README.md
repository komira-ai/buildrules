# Branch coverage of Mojo tests

kcov records lines for a Mojo executable and no branches. The branch figure of `mojo_package`'s `:coverage` (`branches` rows, `:coverage[branches]`,
the `branches` figure of `coverage_floor.txt`; docs/contract.md section 12.4) is made from the compiler's own IR instead. Each test is compiled to LLVM
bitcode, instrumented with IR profile counters by the LLVM the Mojo compiler is built on, linked with the LLVM profile runtime and run. What the run
writes is the count of every branch the test's code took, as an indexed profile; that profile is then applied to the bitcode, and each branch of the
library's own sources is classified (a source decision, or a branch the compiler made) and written as lcov `BRDA` records. `cov_summary --branch-lcov`
folds the records of all the tests into the `branches` rows. linux x86_64 only, like the kcov coverage it sits beside.

The rules are in [`rules/mojo/unit.bzl`](../../mojo/unit.bzl) and [`defs.bzl`](../../mojo/defs.bzl); the LLVM pieces are unpacked by
[`llvm_branch.bzl`](llvm_branch.bzl) and declared per Mojo version in [`rules/mojo/toolchain.bzl`](../../mojo/toolchain.bzl).

```sh
buck2 build //pkg:coverage                                # coverage.txt, lines then branches
buck2 build //pkg:coverage[branches] --show-full-output   # the branch records, one file per test
buck2 build //pkg:test_x__info --show-full-output         # one test's records
```

## What is here

| target | what |
|---|---|
| `:cov_branch` | the tool of the link, run and annotate actions: [`cov_branch.zig`](cov_branch.zig) importing [`cov_branch_link.zig`](cov_branch_link.zig), [`cov_branch_run.zig`](cov_branch_run.zig), [`cov_branch_annotate.zig`](cov_branch_annotate.zig), [`cov_branch_common.zig`](cov_branch_common.zig) and [`proc.zig`](proc.zig) (a command run with an exact environment, waited for, its output in files). A static executable built with the pinned zig 0.15.2 behind its unit tests (`:cov_branch_unit`: the three subcommands in-process over stand-in steps, and what they share); handed out only with its process tests passed (`:cov_branch_exe_test`, `:cov_branch_link_exe_test`, `:cov_branch_run_exe_test`, `:cov_branch_proc_test`), which run the executable as a child over stand-in programs and are validations of it |
| `:cov_branch_classify` | [`cov_branch_classify.zig`](cov_branch_classify.zig) (importing [`cov_branch_andor.zig`](cov_branch_andor.zig), [`cov_branch_source.zig`](cov_branch_source.zig), [`cov_branch_ir.zig`](cov_branch_ir.zig) and [`cov_branch_records.zig`](cov_branch_records.zig)), a static executable, handed out only with its seven groups of cases passing ([Tests](#tests)) |
| `:llvm23`, `:llvm23_check` | `bin/llvm-profdata`, `bin/llvm-nm` of LLVM 23.1.3 with the libraries they load under `lib/`, and `runtime/libclang_rt.profile-x86_64.a`, the compiler-rt 23.1.3 profile runtime, unpacked from pinned conda-forge packages ([`pins.bzl`](../pins.bzl), `LLVM_BRANCH_PINS`); and the check that the directory holds exactly those files, that `llvm-profdata --version` prints 23.1.3 and that the runtime defines `__llvm_profile_runtime` and `__llvm_profile_write_file` |
| `toolchains//:mojo_<v>_lld24`, `_lld24_check` | `bin/lld` of the pinned Mojo compiler package of version `<v>` (LLD 24, the LLVM the compiler is built on) with the C++ runtime libraries it loads; the check that the directory holds exactly those files and that `lld -flavor gnu --version` prints `LLD 24.` |
| `toolchains//:mojo_<v>_raw_version_check` | the version coupling ([below](#the-version-coupling)) |
| `toolchains//:mojo_<v>_cov_branch` | `CovBranchInfo` ([`llvm_branch.bzl`](llvm_branch.bzl)): the two directories, with the three checks as validations, so no build that uses them succeeds unless the checks pass |
| `:llvm_branch_bin` | [`llvm_branch.zig`](llvm_branch.zig): `unpack` (members of `.conda` packages, each a regular file) and `check` (the modes above), behind its unit tests |

The tools do not read the environment of the build: `cov_branch` takes every path as a flag, and `cov_branch_classify` reads none.

## The actions of one test

Per test of the package (`tests/test_x.mojo` is `test_x`), after the compile of the test as bitcode, five actions. Each is a target of the package, and the
last is `:coverage[branches]`'s file:

| target | action category | output | what it does |
|---|---|---|---|
| `:test_x__bc` | `mojo_unit` | `test_x` | the test built by `mopm unit build` as `mojo build --emit llvm-bitcode --debug-level line-tables`, with the profile `{opt: 0, assert: all, debug: false}`, the same ISA flags, the same closure and the same source root as its coverage binary `:test_x__cov_bin`: the program the test runs, as bitcode |
| `:test_x__pgo` | `mojo_cov_pgo_link` | `test_x__pgo` | [cov_branch link](#cov_branch_link) |
| `:test_x__profdata` | `mojo_cov_branch_run` | `test_x__profdata.profdata` | [cov_branch run](#cov_branch_run) |
| `:test_x__ir` | `mojo_cov_branch_annotate` | `test_x__ir.ll` | [cov_branch annotate](#cov_branch_annotate) |
| `:test_x__info` | `mojo_cov_branch_classify` | `test_x__info.info` | [cov_branch_classify](#cov_branch_classify) |

`:coverage` waits for every `__info`, so a test that fails instrumented, a profile that does not fit its bitcode, or a branch the classifier refuses fails `:coverage`
(and `:coverage_floor`), and nothing else: `:lib`, `:build` and `:test` do not wait for these actions. A package whose test links native libraries has the same
actions: the instrumented link is given those libraries ([native libraries](#native-libraries)).

## cov_branch link

`cov_branch link` ([`cov_branch_link.zig`](cov_branch_link.zig)), with `--compiler`, `--zig` (the Mojo toolchain's zig directory), `--target`, `--lld`, `--runtime`,
`--bitcode`, `--out`, `--nm` (`llvm-nm` of the LLVM 23 tools) and one `--native <library>` for each native library of the test's unit.

0. The scratch directory's `bin`, `home` and `tmp` are made (exit 2 if not). Then lld, the runtime, the compiler's `lib/libKGENCompilerRTShared.so`, zig, the bitcode, `llvm-nm` and
   each native library, in this order, must be files that are not empty (a usage error, exit 2), and the bitcode must start with the bitcode magic `BC 0xC0DE`.
1. `lld` reads the bitcode as an LTO link with `-r`, `--lto-O0`, the pass pipeline `pgo-instr-gen,instrprof,default<O0>` and `-mllvm -instrprof-atomic-counter-update-all`: a
   relocatable object whose code counts its edges, each counter updated atomically ([below](#atomic-counters)). Only this LLVM 24 reads the bitcode ([why LLVM 23 tools are safe
   next to it](#why-llvm-23-tools-are-safe-next-to-llvm-24)).
1b. With native libraries, `llvm-nm` lists the global symbols the object defines and, for each library in turn, those it defines (weak ones left out; a shared object by its dynamic
   table). A library that defines a symbol the object defines too fails the link, naming the library and the first five symbols: the linker takes one definition and says nothing
   (an archive member is pulled in only for a symbol still undefined), so the binary would not be the program the test links ([native libraries](#native-libraries)).
2. The Mojo toolchain's zig links it as `mojo_compile`'s `cc` shim links a release test ([`cc_shim.zig`](../../mojo/tools/cc_shim.zig): the compiler's `libKGENCompilerRTShared.so`,
   `--gc-sections`, `-lm`, `--strip-debug`, the one run path `$ORIGIN/lib`), with the profile runtime as a whole archive. The native libraries stand right after the object, each by
   its path, in the order of the `--native` flags.
3. The binary must be an ELF file holding no path of the action (its working directory, then its scratch directory).

lld and zig run with the tool's environment but for `PATH` (an empty directory of the scratch), `HOME`, `TMPDIR` and zig's cache directories (in the scratch directory) and `LC_ALL=C`; their
output goes to a log whose last 40 lines a failure prints after `BRANCH COVERAGE LINK FAILED: <step>`. Exit status: 1 when a step fails; 2 for a usage error, a missing or empty
input, or a scratch directory or program it cannot set up or start.

**Why no debug info.** The binary's debug info is stripped, as in a release link. Nothing reads it: what each counter means in the source is read later from the bitcode (the IR the
profile is applied to, which keeps the line tables, with each branch's line and column), never from the binary. The strip also removes the only directory of the action in the link, the
compilation directory zig's C runtime objects record, so no relocation is needed, and step 3 shows it: with `--strip-debug` left out, the link fails with `the binary holds this action's directory`.

### Atomic counters

The link asks LLVM's `instrprof` lowering for atomic counter updates. Each counter increment is then an `atomicrmw add`, which x86-64 emits as a `lock`-prefixed `add` or `inc` on the
counter; without it, it is the same instruction with no `lock`, a read, an add and a write that two threads can interleave, so one thread's increment overwrites another's.

A lost increment does more than lower a count. IR profile counters sit on the edges outside a spanning tree of each function's control flow, and `pgo-instr-use` derives the other edges'
counts from them by sums and differences, saturating at 0: a counted edge that lost increments can make a derived arm that never ran read above 0 (covered), or one that ran read 0 (not
covered). Any test that runs the measured code on several threads at once could flip an arm of the records from one run to the next. `cov_branch_link_test.zig` holds the option in the
command line (`-mllvm` and `-instrprof-atomic-counter-update-all`, adjacent, once).

### Native libraries

A test whose unit links native libraries (a registry package's static archives, a `natives = {...}` shared object) is linked instrumented with the same libraries as its ordinary
link, and `mojo_package` gives `__pgo` nothing else to decide from:

- **The same libraries, the same order.** `__pgo` takes `native_sonames`, the unit's list from the graph, and `natives`, the target of each: the very wiring of `__bin` (`native_wiring`,
  [`defs.bzl`](../../mojo/defs.bzl)). Mopm gives the ordinary link one `-Xlinker <path>` per library in that order, which the compiler's `cc` shim passes to zig as a bare path; the
  instrumented link passes the same paths in the same order, after the object. A library the unit links that `natives` does not provide, a library `natives` has that the unit does not
  link, and an order in which a library stands before one that needs it are each refused when the target is analysed, naming the library
  (`cov_link_natives`, [`unit.bzl`](../../mojo/unit.bzl); `ci/negative` holds the missing library and the wrong order as must-fail fixtures).
- **`needs` and the order.** The graph lists a static archive before every archive it needs (`needs` in the graph's entry for it): a static archive resolves only what is still
  undefined when the linker reaches it, so the archive that needs `libbase_sys.a` stands before it. `__pgo` checks the order the graph gave against `needs` and refuses a graph in
  which an archive stands after one that needs it, or needs a library the unit does not link.
- **Static and shared.** A static archive (`lib<stem>.a`) is linked into the binary. A shared object is linked by path too, and the binary then loads it by its soname at run time: an
  ordinary test finds it in the `lib/` beside it (the run path `$ORIGIN/lib`, which `mopm unit build` fills), so `__pgo` has a sub-target `[libs]`, a directory of the unit's shared
  objects by soname, which `__profdata` passes as `cov_branch run --lib-dir`. A unit with only static archives has no `[libs]`.
- **A symbol both define.** An archive member is taken only for a symbol that is still undefined, so a library that defines a symbol the instrumented object defines too is passed over
  without a message, and the run measures a program that is not the test (the object's copy of the symbol runs, or the library's, whichever the linker found first). `cov_branch link`
  lists both with `llvm-nm` and fails, naming the library and the first five symbols. Weak definitions are left out: a weak symbol is meant to be replaced.
  Limits of the check, each a difference from the ordinary link or a case it does not cover:
  - a strong definition in a native against a weak definition in the object is not flagged (the ordinary link does not flag it either);
  - a shared native that defines a symbol the object defines too is refused, which is stricter than the ordinary link (the executable's definition simply wins there);
  - a thin archive is not supported: its members live in other files, which `llvm-nm` on the archive may not list as the linker would read them.
  The wiring itself is held by `ci/negative.bzl` (`native_link_problems`): for `ws`, `sys_app` and the two members of `member_native` (an archive a member builds), `__pgo`'s `native_sonames` and `native_needs` are the committed graph's, and the
  link action's `--native` flags are in the graph's order.

## cov_branch run

`cov_branch run` ([`cov_branch_run.zig`](cov_branch_run.zig)), with `--compiler`, `--share`, `--label`, `--profdata`, `--raw-version`, `--binary`, `--out`, a `--lib-dir <directory>` for each
directory of shared native libraries ([above](#native-libraries)), the test's `--env NAME=VALUE`s and, when the test has staged data, `--data-env NAME` (the variable that names `--share`, made absolute: `mojo_package`'s `test_data` is copied into that tree, which is the test's working directory here as under kcov).

1. The test runs in `--share`, the tree of copies of the test source and the library's sources at the relative names the line tables use (the tree `cov_run` gives kcov), with exactly this
   environment: `PATH=/usr/bin:/bin`, `LD_LIBRARY_PATH=<compiler>/lib` followed by each `--lib-dir` (made absolute), the `--env` entries, `--data-env`'s variable, and `LLVM_PROFILE_FILE=<scratch>/prof/%p.profraw` (`%p`, the pid: a child the test starts writes
   a profile of its own; setting it by `--env` is a usage error). Nothing of the tool's own environment reaches the test. The test must pass; when it fails, so does the action, with the
   test's output and `BRANCH COVERAGE RUN FAILED`.
2. At least one `.profraw` was written there; otherwise `The test passed but wrote no .profraw` (the runtime was not linked, the variable did not reach the test, or the test left without
   running its exit handlers).
3. Each raw profile starts with the 64-bit raw magic, has version `--raw-version` and carries the IR-instrumentation flag `0x01000000`, read as `raw_version_check` reads its fixture's.
4. `llvm-profdata merge` writes the indexed profile; a refusal that is LLVM's `raw profile version mismatch` says which version it expected. `llvm-profdata show` must report IR
   instrumentation and one count of functions, above 0.

It waits for the test alone: a child still running when the test exits writes its profile after the merge, or never. It has no time limit of its own: a test that hangs holds its action until
the executor's timeout, which reaches it because it stays in the action's process group. Exit status: the test's when it fails (128 + N for a signal N); 1 when no profile was written or one is
refused; 2 for a usage error or a program it cannot start.

## cov_branch annotate

`cov_branch annotate` ([`cov_branch_annotate.zig`](cov_branch_annotate.zig)), with `--lld`, `--profdata`, `--bitcode` (the test's bitcode), `--profile` (the merged profile), `--binary`
(the instrumented binary that wrote it) and `--out`. lld and llvm-profdata run with the action's environment, `PATH` an empty directory of the tool's scratch, `TMPDIR` one of its scratch and
`LC_ALL=C`.

0. The bitcode must hold no branch weights of its own (the bytes of a `branch_weights` metadata string): `pgo-instr-use` keeps a `!prof` it finds on a branch whose block never ran, which
   would then read as counts. Mojo's bitcode at -O0 holds none (`llvm.expect` is not lowered there). Nor may it hold entry counts (`function_entry_count`), which step 3 counts.
1. The profile holds exactly the functions the binary links. Every function of the bitcode is instrumented, but the link (`--gc-sections`, as a release test's) drops a function nothing live
   calls, with its counters and its profile data record. Mojo leaves such calls in the bitcode: an `assert_equal` of two values it knows are equal compiles to `br i1 false` into the
   failure path, which calls the standard library's `_assert_cmp_error`, `String(...)` of both values and their `write_to`; LLVM's code generation folds that branch and deletes the path, so
   nothing calls those functions and the link drops them. A run writes the record of every function its binary links, zeros included, and of no other. So the (name MD5, hash) pairs of the
   binary's `__llvm_prf_data` records (72 bytes each, whose counter counts must add up to `__llvm_prf_cnts`) and of the profile's functions (`llvm-profdata show --all-functions`, each name's
   MD5 computed by the tool) must be one multiset. A record the profile lacks is a profile of another binary, or a merge that lost records; one it holds besides, a profile of another binary.
2. `lld` reads the test's bitcode as `cov_branch link` does (`-r`, `--lto-O0`) with the one pass `pgo-instr-use`, given the merged profile (`-pgo-test-profile-file`), and prints the module
   after it (`-print-after=pgo-instr-use -print-module-scope`, on stderr): every `br i1`, `select i1` and `switch` of a function that ran carries `!prof !{!"branch_weights", ...}`, the counts of
   its arms; one that never ran carries none. Before the dump, LLVM names each function of the bitcode the profile does not hold (`no profile data available for function`,
   `-pgo-warn-missing-function`). Such a function is not in the binary, by step 1 and step 3's entry-count check together, so it never ran: its branches carry no weights and read as never
   run, zero counts, as those of a function that ran no time do. A measured one is recorded, every arm `-`.
3. Any other line of lld's own (`lld: `, `warning: `, `error: `), or anything before the dump that is not one of those lines, fails the action. The one LLVM prints when the profile does not
   fit the control flow, `function control flow change detected (hash mismatch)`, means that function's counts were dropped, and passing it on would read as branches that never ran. In the
   dump, `pgo-instr-use` must have given an entry count (`!prof` on the `define`) to as many functions as the profile holds: fewer is a binary made from other bitcode, or a hash mismatch LLVM
   does not warn about (a comdat function's, by default).
4. lld must write nothing on its standard output, and what it printed is then exactly one dump, starting with `; *** IR Dump After PGOInstrumentationUse on [module] ***`; it is the output,
   unchanged (each line ending in a newline). `-print-after` output is LLVM's debug text, not an interface: the classifier parses it strictly and fails on what it does not expect.

Exit status: 1 when a step fails (`BRANCH COVERAGE ANNOTATE FAILED: ...`, naming it), lld or llvm-profdata fails (a program that cannot be started among them), or the dump cannot be written;
2 for a usage error, an input that is missing or empty, or a process it cannot create.

## cov_branch_classify

Reads the annotated IR and writes the records ([`cov_branch_classify.zig`](cov_branch_classify.zig), the branch walk; [`cov_branch_andor.zig`](cov_branch_andor.zig), the `and`/`or` rules;
[`cov_branch_source.zig`](cov_branch_source.zig), the source side; [`cov_branch_ir.zig`](cov_branch_ir.zig), the metadata, one function's index and the instruction shapes;
[`cov_branch_records.zig`](cov_branch_records.zig), the output). Flags: `--ir`, `--out`, `--map <import>/=<repository directory>/`, `--src <directory>/`, `--stdlib <prefix>/`, `--gen <path>`
(repeatable), `--exclude <prefix>/` (repeatable) and `--exclude-file <name>` (repeatable). It reads no environment variable.

**Files.** Each branch is attributed to its innermost `!dbg` location (an inlined instruction's own file, line and column, not its call site's). A package's `.mojoc` records its sources as
`<import>/<file>`, so the library's are named so in the IR of a test that imports it: given as `--map <import>/=<repository dir>/` and read in `--src`, a directory holding them at those
names, so a record names `examples/mojo/partial/src/partial/__init__.mojo`; a generated source (`--gen`) is not measured. The standard library (`oss/modular/`), the closure's other
packages (`<their import>/`, an `--exclude` each), the test itself (`--exclude-file`) and `<unknown>` are left out by name; **any other name fails the action**, so a library whose sources
the IR names by the path of a build directory is refused instead of read as measured with nothing in it. `--stdlib oss/modular/` says where the standard library's sources are named (a
String's last-reference test, below, is its code). Every `.mojo` file of `--src` is read for the functions it declares `@always_inline("nodebug")` (below).

**String lifetime.** Mojo 1.0's `String` destructor and copy are `nodebug` inline code: their branches carry the location of whatever token used or consumed the String (`==`, `!=`, `+=`,
`+`, `.`, `[`, `^`, a name, `self`, `out`, a call's `(`, and an `if`, `while`, `and`, `or` or loop head where a String dies). Each destroy gives four branches (the standard library's
`_drop_ref`: the refcounted flag, bit 62 of the capacity word; the last reference, `fetch_sub(1) == 1`; the inline flag, bit 63; the negated bit-62 test) and the capacity computation gives
selects. A br or select whose condition is one of these is compiler-made at any token, checked before the token:

- (a) `icmp ne i64 (and i64 W, M), 0`, M bit 62 or bit 63, the `and` and the `icmp` at one `!dbg`, W the flags word: a `load i64` of field 2 of a `{ ptr, i64, i64 }`, or a web of `phi i64` (a
  raising callee inlined at a call carries its error String in values) whose leaves are such loads, i64 constants and `undef`, one leaf at least such a load or a static String's flags (1 << 61);
- (b) `xor i1 (a), true`;
- (c) `icmp eq i64 X, 1`, X an `atomicrmw sub ptr _, i64 1` (directly or through a one-incoming `phi i64`) whose location is under `--stdlib`, inlined at the branch's own `!dbg`.

The tested instruction (the `icmp` of a and c, the `xor` of b) carries the branch's own `!dbg`; only (a)'s may sit at another location, and only at a token that is no decision (a call's branch
reusing an earlier destructor's test). So a decision on such a test is recorded, never dropped: user code computes its test at its own tokens, not at the `if`. A user mask of a List's
capacity (`if ys.capacity() & (1 << 62):` gives the `and` and an `icmp ne` both at the `&`, shape (a) whole) is kept a decision by this location check alone.

**Classes.** Then the source token at the branch's line and column decides the class, and each class takes only the instruction kinds in its row; any other kind at its token fails the
action. A compiler-made class takes only the kinds and shapes it has shown, as it drops what it takes. A source decision also takes kinds it has not shown where its meaning allows them (an
`if` or `elif` as a `switch`, an `elif` as anything an `if` is): that is safe because a decision is recorded, never dropped, so a wrong guess shows as a record, not as a branch missing from
the count:

| class | tokens | kinds | notes |
|---|---|---|---|
| source decision | `if` (statement or ternary) | br, select, switch | every `if` statement; a ternary (`String("a") if flag else ...` is a br, `1 if flag else 2` a select); the `if` of a plain `@always_inline` helper, a select at its own line with `inlinedAt`; a statement both branched on and selected on is one decision (below) |
| source decision | `elif` | br, select, switch | Mojo gives an `elif`'s branch its `if`'s location, so none shows at an `elif` column; allowed as a decision by its meaning |
| source decision | `while` | br | a select at a `while` is a String's capacity (above) |
| source decision | `or`, `and` | br, select | a select at the token, a chain `a or b or c` (the first select's result is the second's condition), a br at the token (short-circuit, whose result is a phi at the token) |
| source decision | the head of a `for <targets> in <iterable>:` line's iterable: a call's `(` when it ends in `)` (`range(`, `reversed(`, `x.items(`, `f[T](`), an attribute's last `.`, a name's first character, a list literal's `[` (one running over lines too); a chain may start at a string literal. Any other iterable (a subscript, an operator, a tuple) has no head | br | two branches on one value per loop (one decision, below); arm 0 is the iterator's end (the loop exits), arm 1 an iteration. A raising call's error check at the head is a decision too, so a raise never taken reads as an arm not covered, never as a pass. A select at the head is refused |
| compiler-made | `+` | br | a String temporary's destructor before the String-lifetime rule read it |
| compiler-made | `//`, `//=`, `%` | select | the selects of floor division and modulo. `%=` has shown none and is refused |
| compiler-made | a subscript's `[` (after a name, `]` or `)`) | br on a raising call's error flag: the `i1` a `[tail] call i1 @...` at the branch's location returns, or field 0 of the `{ i1, ... }` one returns | `Dict.__getitem__`'s KeyError. Any other branch at `[` is refused (no user decision sits there). In a `try:` body the error check is a decision ([try](#try)) |
| compiler-made | the `(` of a call off a `for` line's head: `name(`, or `name[...](` (the name before the `[`, which may be lines above; brackets in one-line string literals and comments are skipped; a `"""` or `'''` between the `[` and `]`, which can open a string running over lines, refuses the branch) | br; select on a raising call's error flag (field 0 of a `{ i1, ... }`) or on a value a br at the same location with the same weights tests | code that carries the call's location: a raising call's error check, and the code of standard-library functions declared `@always_inline("nodebug")` (no location of their own). A select between the constants 0 and 1 is a Bool converted to an Int ([below](#bool-to-int)). Any other select at a call is refused. The error check of a call whose error goes to its caller (outside a `try:` body) is one; in a `try:` body it is a decision ([try](#try)), and any other br at the call is refused there |

A branch at the `(` of a call to a function the library's own sources declare `@always_inline("nodebug")` is refused, whatever its shape: that function's code has no location of its own, so
its decisions land on the call, where they cannot be told from the compiler's. A plain `@always_inline` keeps its locations (with `inlinedAt`), and its decisions are recorded where they are
written. A library source declaring an operator, constructor or destructor (`__<name>__`) `@always_inline("nodebug")` refuses the run: its code lands on any token.

Anything else fails the action naming `file:line:col`, the instruction and the token: another word or operator, `%=`, a `(` not after a name or a `name[...]`, a `(` on a `for` line off the
head (another iteration), a column outside the line, a class with a kind or shape it has not shown (a select at `+`, a br at `[` on a comparison, a br at a call in a `try:` body on anything
but the call's error flag). The list grows only with evidence. A branch with no `!dbg` fails too, and so does an `indirectbr`, `callbr` or `invoke` in a measured file (Mojo emits none).

**Records.** Compiler-made branches are counted on stderr, not written. Each source decision gives one `BRDA:<line>,<col>:<kind>:<n>/<N>,<arm>,<count>` per arm: `<kind>` is `br`, `select`,
`switch`, `try` or `rhs`; `<N>` is how many decisions of that kind one copy of a function (one LLVM function, or one inlined copy of it) holds at that location, and `<n>` which one, in IR
order: Mojo puts `if` and `elif` on one location (`4,5:br:0/3`, `1/3`, `2/3` for an `if` and two `elif`s). Arms are numbered 0, 1, ... in the order of LLVM's weights (true first for `br` and
`select`, the default first for a `switch`), not named true and false; a `try` decision's are returned (0) and raised (1). The `<n>`-th of every copy (generic instances, inlined copies) is
summed arm by arm; every copy must hold as many, and where both are known, compute the condition of its `<n>`-th at the same line and column, or, for a decision at an `if`, `elif` or `while`
statement's keyword, inside its header (from the keyword to the `:` closing it, over continuation lines): a copy may fold part of the condition away (`if index < 0 or index >= self.length:`,
whose copies inlined with a constant index compute the condition at the `>=`, the others at the `or`). An instance that folded away one `elif` and another that folded away another would
otherwise be summed crosswise, and an `elif` has a header of its own, so it is still refused. A count of a branch that never ran is `-`, counted and not taken (lcov's "never reached"),
never 0.

One decision tested twice, two branches or selects on the same condition value with the same weights node at the same location (a loop's two at its head; an `if` whose test is both
branched on and selected on), is one record: the br is kept.

**And, or.** A bool `and`/`or` is a decision where the user wrote it: its left operand's branch or select at its token, two arms, the right operand skipped or evaluated (for `or`, arm 0 is the
left operand true, the right operand skipped; for `and`, arm 0 is the left operand true, the right operand evaluated). That holds wherever the result goes: tested by an `if` or `while`,
returned (`return a or b`), stored (`var r = a and b`) or passed on (`f(a or b)`); a test must take both arms, which line coverage cannot see (every line run, one arm of `return a or b`
never taken).

When a source decision tests the result, the right operand's own outcomes are counted as well: `rhs`, derived from the left operand's counts (the and/or's own select or br) and the whole
condition's (the first branch or select of a source decision that tests the result: the select's result directly, the short-circuit form's phi at the token, either through `xor ..., true`,
its arms swapped, through a phi forwarding that one value, or as the condition of the next select of a chain). For `or`, the whole's true count less the left's, and the whole's false count;
for `and`, the whole's true count, and the left's true count less it. An `and`/`or` that is itself the right operand of a short-circuit one and that no branch tests takes the outer one's
derived right operand as its whole condition, swapped through each `xor`: the inner value is computed exactly when the outer right operand is. A select LLVM gave no weights never ran; with a
whole of zero counts, neither did its right operand.

A test is the result's only when it ran as many times as the left operand, and its counts can be the whole's (an `or` true at least as often as its left operand, an `and` at most as often): a
test of the value that runs another number of times reads it on some paths only, or elsewhere, and one that never ran while the left operand did (or the reverse) is not its test either.
Matching counts are necessary, not sufficient: a test whose counts happen to match is read as the result's, and the derived right operand is then wrong. A known limit; a structural check (the
test in the block the result is computed in, or one only it reaches) would close it. Such a test gives no `rhs` (a later test may), and the and/or is then its two arms alone, as one whose
result is returned. Which tests count depends on the counts, so one test's run of a function may give an `rhs` and another's not: `cov_summary` sums what each gives, and an arm a test did not
give is never a pass. A result merged with other values in a phi and tested after the merge is not followed: the and/or alone.

The phi of a short-circuit form is at the and/or's token and joins one value arriving under the `br`'s target for the deciding left value (its true target for `or`, its false target for `and`)
and one under the other target: every path from the `br` to the incoming block passes through that target, which only the `br` jumps to (the walk follows LLVM's `; preds =` backwards and never
past the target; reaching the `br`'s own block or the entry refuses). The value under the deciding target must be the constant that decides (`true` for `or`, `false` for `and`), or a reload of
the left operand: `load i1, ptr P` of the pointer the left operand's load reads, the first instruction of the target (lifetime markers and `nop` asm aside) after a left operand loaded last
before the `br`, so no write can fall between. A constant under the other target is the phi of another expression (`not a or b`) and is refused, and so is one arriving straight from the
`br`'s own block. A short-circuit br with no such phi at its token is refused, tested or not: the phi is the evidence that the br is the and/or's left operand. Several phis may join the
targets: a raising right operand's error flag beside the result. For an `and` the flag has the result's shape, and each phi of that shape is a candidate: the result is the one a source
decision's branch tests (a call's error check testing the flag is no such test, nor is a `try` decision). For an `or` the flag is `false` under the deciding target and field 0 of the `{ i1, ... }`
the right operand's call returns under the other, which is no result. Any other `i1` phi at the token (but a forward of one value), joining the targets in another shape or not joining them,
refuses an and/or whose result no test reads: which phi its result is cannot be told, so it is not read as untested. A value `and`/`or` (not `i1`) has no right operand that decides. Since an
`elif` carries its `if`'s location, its records name the `if`'s line.

Known shapes, with what each gives:

- `if c: return True` then `return False`: Mojo folds it into `return c` (`ret i1`), so the `if` has no branch and no record, as the same function written `return c` would have none.
  Accepted. An `and`/`or` in such a condition is then never tested, and is its own two arms (above).
- `<n>/<N>` numbers the decisions of one kind at one location in IR order. It cannot tell an `elif` (Mojo gives it the `if`'s location) from a second copy of one decision the optimizer made
  inside one function (jump threading, an optimizer's unrolling; the unrolled body of a `comptime for` is read from the source instead, [above](#unrolled-loops)). Such a copy gets its own `<n>` and its own counts, so the original's arms look less taken than they are: the error is a false "arm not
  covered", never a silent pass. If two copies of a function disagree on `<N>` the action fails (above).
- A String's destructor or copy at a decision's token whose tested instruction sits at another location (a destroy reusing an earlier destroy's flags test) is recorded as a decision of that
  token (the rule above reads only the tested instruction's location there): a false "arm not covered" at worst, never a dropped decision.

**What stays refused** (the classifier fails the action naming `file:line:col`; none is read as a pass): copies holding different numbers of decisions at a location (but not those of a `comptime for` body, which are one decision, [unrolled loops](#unrolled-loops); a `comptime for` whose
unrolled calls share one `inlinedAt`); a br at a call in a `try:` body on something else than the call's flag; a short-circuit and/or with no result phi (an `if` folded away when both arms
return alike; a `debug_assert` condition; a non-`Bool` `and` whose result goes through memory); a select at a call on something else than a raising call's flag or a select between 0 and 1; a phi at an and/or that is no
short-circuit one's (a reload of the left operand after String destructor code); copies computing a condition in different headers; zero branches parsed in a file with a branch-like instruction on a decision line (a decision line the build folded to straight-line code is 0/0);
a `with` in measured code, whose branches (the `__exit__(err)` result that suppresses the error, and the context manager's state) no rule reads. The refusal of a library is a failed
`:coverage`, not a figure: a package that hits one has the line figure from its `[reports]` and no branch figure until the classifier learns the shape, from evidence, in a test.

**Silent-miss limits** (a limit, not a check; each shows as a false "arm not covered" or is documented above, never as a false pass): `rhs` attribution matches by count and is not structural;
two tests' copies that hold as many decisions at a location but different ones are summed crosswise by `cov_summary` (it refuses a different `N` or a different number of arms, not a different
decision); an `<n>/<N>` miscount from an optimizer-duplicated decision.

**Output.** Per measured file the IR holds code of, `SF:<repository path>`, its records sorted by line, column, kind, `<n>` and arm, `end_of_record`; files sorted bytewise. A file with code and no
source decision is named with no record (`SF:` then `end_of_record`), so `cov_summary` counts its package's branches as measured with none to take, rather than not measured. A test whose IR
holds no code of the library writes an empty file. Every measured file with code on a line holding a decision word (`if`, `elif`, `while`, `for`, `and`, `or`, outside strings and comments)
must have a branch parsed, or the action fails (the branches were not read). The block field `<col>:<kind>:<n>/<N>` of the `BRDA` lines is read by `cov_summary` only: upstream lcov and
genhtml take a block number there, and these files are not for them.

```
SF:examples/mojo/partial/src/partial/__init__.mojo
BRDA:5,5:br:0/1,0,0
BRDA:5,5:br:0/1,1,1
end_of_record
```

### Bool to Int

`Int(flag)`, `UInt8(flag)` and `String(Int(flag))` convert a Bool: Mojo writes the conversion as `select i1 %flag, iN 1, iN 0` (or `0, 1`) at the `(` of the call, and the select carries weights like any other.
The source has no decision there, so a select at a call whose two values are the constants 0 and 1 is compiler-made: counted with the `call(` class, not written. A select at a call with any other values (a value
that is not a constant, 2 and 0, 1 and 1) is refused as before; a ternary `1 if flag else 0` is a select at its `if` and stays a decision. The decision, if there is one, is where the Bool was computed
(`Int(a < b)` has the `<`'s own code, and an `and` in it its own record).

### Unrolled loops

The body of a `comptime for` is unrolled by the compiler: one copy of each decision in it per iteration, all at the one source location, and a function generic in the trip count (`comptime for k in range(W)`)
has a different number of copies in each instance. The decisions of such a body, found from the source (the line is indented under a `comptime for` line, or a `for` line after `@parameter`, of its own function),
are **one record**, `<n>/<N>` = `0/1`: the iterations of every copy and instance are summed arm by arm. The choice is one aggregated pair of arms, not one pair per iteration: per-iteration records could not be
matched across instances of other widths, and an iteration number is no source location. The pair is covered when some iteration, in some test, took each arm; it cannot say that every lane did. An `if`
with an `elif` clause in the body keeps its records one per copy (its copies are told apart by their order, as an `if` chain's are), so instances of different trip counts are still refused there. A file
whose brackets do not balance has no unrolled loops read.

### Folded conditions

A br or select on a condition the build decided is no decision of the run: the literal `true` or `false`, or the `i1` returned by a call of the standard library's target queries, a function named
`std::sys::info::...` and specialised on the target of the module (`,value=#kgen.target<...>`: `CompilationTarget.is_x86()`, `is_linux()`, ...). Mojo folds `simd_width_of[DType.uint32]() == 16` into a
constant but keeps the call of such a query, so `return CompilationTarget.is_x86() and CompilationTarget.is_linux()` has a br at the `and` on the call's result, one arm of which no run can take. Such a br or
select is not written and not refused, at any token; it is counted on stderr (`N branch(es) or select(s) on a condition the build decided`). The `and`/`or` rules never see it, so the operand that remains is
tested where it is used; an `if` that tests the whole condition is still a decision. Only a call named so is read: any other call's flag, or a query without the specialisation, is a decision as before.

### try

A raising call lexically in the body of a `try:` of its own function is a source decision of two arms, of kind `try`: arm 0, the call returned; arm 1, it raised into the handler (an `except`, or
the `finally` before the error goes on). A test must take both: a call in a `try:` body that never raises leaves its handler path untested for that call, even when the `except` body runs
(another call raising) and line coverage is full. The arms are not LLVM's order (true, the call raised, comes first there).

What Mojo 1.0 emits is the same at a call in a `try:` body and outside one: a `br i1` at the call's `(` (a subscript's `[`), on the call's error flag, its raised target the handler or the
propagation to the caller. So the scope is read from the source, and the shape from the IR:

- Scope. From the call's line back, over the lines indented less than the last one met (blank, comment and triple-quoted-string lines skipped, and continuation lines, which start inside an open
  bracket: the `) raises:` closing a nested `def`'s signature over lines has the `def`'s indentation, and read as a statement it would hide the `def`; a file whose brackets do not balance,
  outside strings and comments, is refused at its first such branch, naming the line that opens the last bracket never closed or closes one never opened), a `try` line met before a `def`, `fn`,
  `struct`, `trait` or `class` line (another function: a `def` nested in a `try:` body is one), or the call's own line `try: <statement>`. An `except`, `else` or `finally` clause has its
  `try`'s indentation, so a call in its body is in that `try`'s body only if the whole `try` is in another's: a call in an `except` body of an inner `try` counts for the outer one; one in
  an `else` or `finally` body, or after the `try`, does not (its error goes to the caller), nor does one in a `with` body outside a `try:` body.
- Shape, at a call, a subscript or a `+` in the scope: the br must test the call's flag at its own location (the `i1` of `call i1`: `touch(x)`, a raising constructor `Box(x)`; field 0 of the
  `{ i1, ... }` one returns: `checked(x)`, a method `b.get(x)`, `d[key]`), or a `phi i1` of such flags, of `true`/`false` and of the code of a callee inlined at the call (whose `inlinedAt` chain
  holds the br's location: a plain `@always_inline` raising callee, the `phi i1` of its `if`'s condition; `Int(s)`, a phi of `String.__int__`'s flag; the raising right operand of an `and`, a phi
  of its flag and `false` at the `and`), with one such value at least, or one constant arriving from a block of the inlined callee's code. A phi of constants alone says which arm is which by its
  constants only, so each one from the callee's code must match its block: `true` from the raise path (the block calling `__mojo_debugger_raise_hook`, which Mojo emits at every `raise`),
  `false` from any other; a phi saying `true` from the return (with `false` or `true` from the raise path) would swap or blur the arms, and is refused. Any other br there is refused: whether it
  is the call's error check is not known. A String's destructor at the call (the handler destroying the error's String) is the String's, as anywhere; a select on the flag stays compiler-made
  (the br is the decision).
- A `try` decision is no test of an `and`/`or` result: a raising right operand's flag beside the result is tested by the call's error check, and the `if` is the and/or's test.

Not decisions: a `raise` statement (a jump to the handler, no branch); a call outside a `try:` body, whose error goes to the caller (Mojo returns the callee's `{ i1, ... }` as its own, no branch at
all); a `for` loop's end (`__next__`'s StopIteration flag at the head is the loop's decision, in a `try:` body or not). A `with` block keeps its own branches at the `with` keyword, which no
rule reads: a library with a `with` in measured code is refused there. A branch at the `try`, `except`, `else` or `finally` keyword is refused (none has been seen).

## The LLVM pieces

### Why LLVM 23 tools are safe next to LLVM 24

Only the LLVM 24 `lld` ever reads or writes Mojo's bitcode: it instruments it, and it reads the counts back in. The LLVM 23 pieces never see bitcode: the profile runtime only writes out the
counters and data the instrumented code laid out, into the raw profile file; `llvm-profdata` only reads that raw profile and writes an indexed profile, which the LLVM 24 `pgo-instr-use`
reads (a newer LLVM reads the indexed profiles of older ones). What couples them is the raw profile format. The Mojo package ships `lld` but no profile runtime and no `llvm-profdata`, so
those come from an LLVM release that conda-forge publishes.

### The version coupling

The instrumented module defines `__llvm_profile_raw_version`: the raw profile version of the LLVM that instrumented it (the low 32 bits; the high 32 bits are variant flags, `0x01000000` for
IR instrumentation). The runtime writes that value into the raw profile's header, and `llvm-profdata` accepts a raw profile only when its version is exactly its own. LLVM changes the version
whenever it changes the raw format, so equal versions mean the runtime's layout is the one the reader expects.

The runtime defines `__llvm_profile_raw_version` too, weakly, as its own version with no variant flags, so that a program without instrumented code still links. If the instrumenter's
definition were lost, the runtime's would be written instead, and a version check would compare the runtime with `llvm-profdata` and say nothing about LLVM 24.

`toolchains//:mojo_<v>_raw_version_check` ([`fixtures/profile_fixture.c`](fixtures/profile_fixture.c), compiled to bitcode by zig, instrumented by that version's `lld` with the passes above, linked
with the runtime and run) measures, on every build in which an input changed, that the raw profile has version 11 with the IR flag (`RAW_PROFILE_VERSION` of [`llvm_branch.bzl`](llvm_branch.bzl)), that
the instrumented object defines the symbol strongly and the runtime only weakly, that `llvm-profdata` merges it, that `show` reports 3 functions and the counters 2 and 3, and that the same
profile with its version raised by one is refused as LLVM's `raw profile version mismatch`, with `llvm-profdata` expecting the measured version. When they part, it fails, naming both versions:

```
llvm_branch raw_version RED: raw profile version 12 not accepted by llvm-profdata 23.1.3, which expects 11: warning: .../pg.profraw: raw profile version mismatch: ...
```

Updating: **a new Mojo** is a new `lld`; `lld24_check` requires `LLD 24.` (a Mojo built on another LLVM fails it). Before changing it, build `raw_version_check`: if it fails, pin the profile runtime
and `llvm-profdata` of an LLVM release whose raw version is the one the new `lld` writes (`LLVM_BRANCH_PINS` in [`pins.bzl`](../pins.bzl), the `llvm23` unpack and `libs23` of `llvm_branch.zig`),
set `RAW_PROFILE_VERSION` to that version (every branch coverage run requires it of each raw profile), and run the branch coverage of a Mojo test end to end.

### What is pinned

`LLVM_BRANCH_PINS` of [`pins.bzl`](../pins.bzl), all from conda-forge, each a sha256-pinned download: `llvm-tools-23` (`bin/llvm-profdata-23`, `bin/llvm-nm-23`), `libllvm23`
(`lib/libLLVM.so.23.1`), `libxml2-16` (`lib/libxml2.so.16`, which `libLLVM` loads), `libiconv` (`lib/libiconv.so.2`, which `libxml2` loads), `zstd` (`lib/libzstd.so.1`), `libzlib` (`lib/libz.so.1`)
and `compiler-rt23` (`lib/clang/23/lib/linux/libclang_rt.profile-x86_64.a`); with the repository's own `libgcc` and `libstdcxx` pins for `lib/libgcc_s.so.1` and `lib/libstdc++.so.6`, and the
pinned Mojo compiler package of the version for `bin/lld`. `libxml2.so.16` holds a conda install-prefix placeholder in one string, the default path of its XML catalog; neither program reads
an XML catalog. The `llvm-tools` package of the same build is not pinned: it holds only links.

`llvm_branch unpack` writes the named members of the packages, each a regular file (a member that is a link in its package is followed within the package; a link to an absolute path or out
through `..` fails the action, as does a missing or empty member). `bin/lld` is taken this way, not through the compiler closure `mopm` checks: that closure's hash is the toolchain's and is
not changed.

The checks read the unpacked directories and run the programs on the farm; they do not read the ELF files for the libraries the loader would map. Both programs find their libraries through
their `DT_RPATH` `$ORIGIN/../lib`, which the loader searches before `LD_LIBRARY_PATH`, so a test runner's `LD_LIBRARY_PATH` does not change what they load, but a library missing from the
directory that a worker happens to have would not be noticed.

### Licences

LLVM, of which `lld`, `llvm-profdata`, `llvm-nm`, `libLLVM` and the compiler-rt profile runtime are parts, is Apache-2.0 WITH LLVM-exception. The licence text is in each conda package's
`info/licenses/`. The profile runtime is linked into instrumented test binaries; the LLVM exception covers that, and no product links it. `libxml2` is MIT, `zstd` BSD-3-Clause, `zlib` Zlib,
`libiconv` LGPL-2.1 (loaded as a shared library by the tools, linked into nothing), and `libstdc++`/`libgcc_s` GPL-3.0 with the GCC Runtime Library Exception. Nothing here is packed into a
release artifact: these are build tools.

## Cost

Per test, a compile to bitcode, a link, a run, an annotation and a classification. The annotation is the long one: the IR text of a test that imports the standard library is several megabytes
(about 10 MB for a test of a small library), and lld prints it. The run is as fast as the test, except where the test spends its time in instrumented loops: atomic counters add a `lock`ed
instruction to every counted edge.

## Tests

By behaviour, each run as a build action on the farm, and a defect each catches:

- **The classifier** ([`cov_branch_classify_*_test.zig`](.), with [`cov_branch_classify_harness.zig`](cov_branch_classify_harness.zig) over [`fixtures/`](fixtures)). Each case runs the executable
  `:cov_branch_classify` hands out (its path in the test's environment as `COV_BRANCH_CLASSIFY`, the `zig_test`'s `env_tools`; a case fails, never passes, without it) as a child process with an
  empty environment, in a directory of its own holding the library's sources (`fixtures/*.src`, staged under a made-up directory the fixtures' IR names) and the case's IR, a fixture or a line edit of
  one (an edit that changes nothing fails the case). It checks the exit status, the output file byte for byte or by line, the messages on stderr and that nothing is written to stdout.
  `case`, 1 to 9c on `fixtures/case.ll`: the golden output, the metadata order, a second test's counts, unknown tokens, file names, `--gen`, zero branches, a name no prefix covers, sources named by
  import name with `--src` (8d to 8g), malformed IR, copies, and/or shapes refused. `andor`, 9j and 9k: and/or results no test reads, error flags, three on one line. `files`, 9d to 9i: nodebug
  callees, kinds, invokes, decision-free and twice-spelled files. `rules`, 11 to 11f on `fixtures/rules.ll`: the shape rules. `try`, 12 to 12c on `fixtures/try.ll`. `fold`, 13 to 15, on IR written in the test file: a Bool converted to an Int, an unrolled loop in instances of two widths (and a chain with an `elif`, still refused), and a condition the build decided (a target query, a literal; a runtime flag and an unspecialised query still decisions). `main`: bad usage (exit 2, the
  message and the usage line) and an output whose write fails (a file size limit in the child: exit 1, nothing written, no temporary file left).
- **The tool.** `cov_branch_unit`: link (the exact lld and zig command lines and environments, each input missing or empty, a bitcode without the magic, an lld or zig that fails with the last
  lines of its log, an output that is no ELF file or that holds a directory of the action; with native libraries: the libraries after the object in the order given, `llvm-nm` run on the
  object and on each library with the flags for an archive and for a shared object, a library that defines a symbol of the object refused by name, five symbols named and the rest counted, an
  `llvm-nm` that fails or cannot start, each library missing or empty, and every allocation of the link failing in turn), run (the test's working directory and exact environment, each `--lib-dir` after the compiler's lib in order and made absolute, no profile, a profile of another magic,
  version or without the IR flag, a merge that fails, a show that is not an IR profile of a function), annotate (every refusal with its message and the order they are checked in: the bitcode,
  the binary's records against the profile's, lld's diagnostics, the dump) and the flags of each. The process tests run the shipped executable over stand-in programs.
- **The records and the summary** (`rules/coverage/tools/branch_lcov_test.zig`): the format and each refusal, the sum by id across tests (an arm is hit when any test took it, `-` adds nothing, an
  arm one test did not give is never a pass), the disagreement of two tests about a location's decisions or a decision's arms, the listing (0/0 for a source with no code or no decision, a source
  with lines and no record refused), and every allocation failing.
- **On real Mojo** (`examples/mojo`): `partial`'s one `if` with one arm run gives `BRDA:5,5:br:0/1,0,0` and `BRDA:5,5:br:0/1,1,1` and the rows `branches ... 1/2 50%` (`:coverage_records`), `reexport`'s `if` and `for` give
  `select` and `br` records with their exact counts, `testdata`'s code with no decision gives `SF:` and `end_of_record` and `0/0`, the rows and the records agree file by file, and the floor of
  `partial` is held as a minimum for lines and for branches (`coverage_floors`: a figure above the coverage is red, for its reason, in `ci/negative.bzl`; one below it is green; a floor with no
  `branches` figure is red; a `branches` figure for code with no decision is red; a `branches` figure the tests do not record is refused by `coverage_tools_refuse`). `sys_app`, whose test links two static archives, gives `BRDA:18,5:select:0/1,0,1` and `BRDA:18,5:select:0/1,1,1` for the `if` of `clamped_answer`, whose test takes
  both arms (rows `branches ... 2/2 100%`, a floor of `lines 100.00` and `branches 100.00` that holds); `ws`, whose test loads a shared object, gives `SF:` and `end_of_record` and `0/0` (its
  library has no decision): the records and the rows agree for both. That every example, those two included, has the five branch targets of its test and that its `:coverage` waits for them
  is held by `ci/negative.bzl` (`BRANCH_PACKAGES`); a unit's library missing from the instrumented link, and two archives in an order the linker would leave symbols undefined in, are must-fail
  fixtures there (`CASES`), and `rules/mojo/tests` holds `cov_link_natives` by its messages.
