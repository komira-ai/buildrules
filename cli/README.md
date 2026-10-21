# buildrules CLI

Zig, built by the pinned zig behind its unit tests (`buildrules//cli:buildrules`). It writes and reads exactly what
`docs/contract.md` (branch `contract` of the buildrules repository) says; `src/contract.zig` holds the file names and the
generated texts as constants, and `src/contract_test.zig` checks them against a real generator run (`src/fixture/`).

| command | what it does |
|---|---|
| `init [DIR] (--path RELPATH \| --git ORIGIN --commit SHA)` | `.buckconfig` (buildrules cell, pinned; `--git` takes https or `file:///abs`), `toolchains/BUCK`, `platforms/BUCK`, `.buckconfig.local.example`, `rust-toolchain.toml` (exact), a virtual-workspace `Cargo.toml` with the policy, `.gitignore` lines; never overwrites |
| `cargo new PATH` / `cargo init [PATH]` `[--cargo CARGO] [--lib]` | the pinned cargo (`new --vcs none`), then adopt |
| `cargo adopt [PATH...]` | for packages that already build with cargo: `[package.metadata.buildrules]`, a BUCK file with `cargo_package(path = ".")`, the workspace `members` entry; no PATH = every member |
| `sync [--check]` | pinned cargo captures `--unit-graph` per member and verb; the generator (part of this program: `unitgen.zig`, `buckgen.zig`) writes `buildrules.lock.bzl` and `third_party/buildrules/`; this command writes `buildrules.bzl` and the root `BUCK` |
| `check` | offline, read-only; exit 1 when `rust-toolchain.toml`, `Cargo.lock` or any `Cargo.toml` differ from what `sync` recorded, or a generated file is hand-edited; also the Mojo check below when the repository has Mojo packages |
| `mojo sync [--check] [--mopm M] [--buck2 B] [PKG...]` | for each package whose BUCK file calls `mojo_package(`: the pinned mopm's `plan --unit-graph --locked` (mopm-toolchain.toml gives mopm and Mojo) written verbatim as `buildrules.mojo.lock.bzl` beside `mopm.toml`, with `buildrules.mojo.bzl`; `toolchains/mojo_pins.bzl` (mopm's toolchain section) and `toolchains/mopm_pins.bzl` (`buildrules-pins.toml` `[mopm."V"]`) |
| `mojo check` | offline, read-only; exit 1 when a manifest, a source, a new test or library file, a toolchain version or a generated file is not what the table was made from |

Exit codes of every command: 0 ok, 1 failed or stale, 2 usage.

`sync` runs the generator in process (`unitgen.zig` turns the graphs, `Cargo.lock` and the manifests into the table; `buckgen.zig` turns the table into the
registry package and writes the sizes; `toml.zig` and `val.zig` read and write the formats). Its content ids are byte for byte the Python generator's it replaced, so no committed table
changed. It gets the pinned cargo, the pinned rustc and the Rust version table by building `toolchains//:cargo_<v>`, `:sysroot_<v>` (`<v>` = the version of
`rust-toolchain.toml`, `_` for `.`) and `buildrules//rules/rust:pins.bzl` with `buck2` unless `--cargo`, `--rustc`, `--pins` are given. Nothing needs an interpreter.

Reused from kpin: `diag.zig`, `valid.zig`, `cargo_lock.zig`. kpin's crates generator (`cargo.zig`,
`cargo_trim.zig`) belongs to the other Rust engine and is retired here: the contract's engine is `cargo_unit`.
`rules/zig/zig.bzl` is a stand-in `zig_exe`/`zig_test` until the seed track's Zig rules land.

## Tests and coverage

Every `src/*_test.zig` is a `zig_test` (`:<name>_unit`) that the executable is built behind. `src/testkit.zig` runs `main.run` in a temporary directory the way the binary
does, and replays every command line a test runs on copies of that directory: once with output streams that fail (the exit code must not change), and then with the
allocator failing at each place of the code that allocates (once per place, as `Harness.run` says): the command must end, and leave no half-written file. Functions
that take an allocator are swept the same way (`testkit.sweepOom`, `sweepRefusal`), over inputs of many sizes (`growth_test.zig`), because a buffer that grows by half
again fails at a different line for each size of its input.

`:all_unit` is all the test files in one program. Coverage (`:coverage`, held to `coverage_floor.txt`) is measured on it: for the instantiations of a generic function
(`Diag.add`, `Ctx.say`, one per call site) the figure keeps the largest count of blocks that ran in any one test program, so the tests of several files count together only
as one program.

A coverage build counts how often each block ran in one byte that wraps, so a block that ran 256 times reads as one that did not (`zig_cov_runner.zig` writes the byte as it is). `testkit.saturateCounters`
sets every non-zero counter to one between the runs of a loop; without it the figure differs by a few blocks from one run of the same tests to the next, and an exact floor would fail at random.
The replays and sweeps allocate from one fixed buffer, reset for each run: from a heap whose addresses change, the runs of one command line did not allocate the same things in the same order, and
the allocation that was failed was not the one that was meant.

What the figure cannot reach, and why (the floor is the number reached, not 99): the error exit of a `try` on an append that always fits in the capacity the previous append
made (no input makes it allocate); the safety-check blocks Zig's debug build appears to emit for an index or an unwrapped optional that cannot fail; code that no input reaches
(the array arm of `val.pyDumps`, which only a flat table reaches; the line after a successful https download in `buckgen` and `npm_cmd`, which needs a server with a certificate
the program trusts); a child that is killed by a signal (`Ctx.spawn`, `Ctx.execReal`).
