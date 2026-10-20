# The buildrules contract (v0, Rust and Mojo, Linux x86_64)

One document for the three things that must agree: the **rules** (this repository: `rules/rust/cargo.bzl`,
`cargo_unit.bzl`), the **generator** (`cli/src/unitgen.zig`, `buckgen.zig`, part of the command line) and the **command line**
(`buildrules`, Zig). If the three disagree, this file is the arbiter and the
disagreement is a bug. Everything below was exercised end to end on the farm (see "Status").

Decisions are marked **[p7]** when the earlier front-door prototype (`cargo_workspace` / `cargo_package`)
had already made them and this document only records them, and **[chosen]** when that prototype had not decided and
this document does.

## 1. What a user sees

```
buildrules init . --git <origin> --commit <40 hex>      # once per repository
buildrules cargo new crates/hello                       # or: cargo init PATH / cargo adopt [PATH...]
buildrules sync                                         # after every change to Cargo.toml, Cargo.lock, rust-toolchain.toml
buck2 build //crates/hello:test //crates/hello:debug
buildrules check                                        # offline, read-only; the pull-request gate
```

A member's BUCK file is two lines **[chosen]**:

```python
load("//:buildrules.bzl", "cargo_package")

cargo_package(path = ".")
```

Nothing else is hand-written. Starlark cannot read TOML, so cargo's files are read by `sync`, which bakes
the result into one generated table; the macros read that table. A table that no longer matches cargo's
files is red (section 8), never silently used.

## 2. Public load paths and macros

| load | symbols | who loads it |
|---|---|---|
| `@buildrules//rules/rust:defs.bzl` **[chosen]** | `cargo_workspace`, `cargo_package`; `rust_library`, `rust_binary`, `rust_test` (the hand-written rules, unchanged) | the generated `buildrules.bzl` (and anyone writing rules by hand) |
| `//:buildrules.bzl` **[chosen]** | `cargo_workspace`, `cargo_package` bound to the generated table; `CARGO`, `THIRD_PARTY` | every BUCK file the CLI writes |
| `@buildrules//rules/rust:cargo.bzl` **[p7]** | the unbound macros (`table` and `third_party` are required arguments) | `defs.bzl` |
| `@buildrules//rules/rust:cargo_unit.bzl` **[p7]** | `cargo_unit`, `crate_src`: one compile / build-script / test / lint action each | the generated `third_party/buildrules/BUCK` |
| `@buildrules//rules/rust:toolchain.bzl` | `rust_toolchains()` | the `toolchains` cell, one call |

`defs.bzl` re-exporting the two macros is the one change this contract makes to p7's tree; `cargo.bzl`
keeps p7's names and signatures.

### `cargo_workspace(path = ".", table)` **[p7]**
Called once, in the package of the workspace root (v0: the repository root). Declares `:check`, the
`Cargo.toml` / `Cargo.lock` / `rust-toolchain.toml` (and `clippy.toml` if present) exports, one aggregate
target per step (`:lint :debug :test :release`) and one per action named in the policy. Each aggregate
depends on the same-named target of every member listed in the table.

### `cargo_package(path = ".", table, third_party, check = None, extra_srcs = [], refuse = fail)` **[p7]**
Called once per member, in the member's own package. `path` is the member directory relative to the BUCK
file (`.`). `table` is the generated table as a dict; `third_party` is the package holding registry
units; `check` overrides the label of the workspace `:check` (default `//:check`); `extra_srcs` are files outside the package that its sources read at
compile time; `refuse` is what a refused table calls with the reason (default `fail`, which stops the load; the tests of the refusal pass a recorder,
`rules/rust/refusal.bzl`). Through `//:buildrules.bzl` the table and the third-party package are bound and the call is `cargo_package(path = ".")`. Every
member package also has `:sources`, a `filegroup` of its files (a glob of the root package cannot cross into a member's package), and the generated
`third_party/buildrules` has `:files` (its `BUCK`, `crate_sizes.tsv` and `overrides.json` when there is one); `cargo_sync` (`rules/rust/sync.bzl`) stages a
workspace from them.

Targets of a member **[p7]**: `:lib`, `:bin` (only when the member has a binary), `:debug`, `:release`,
`:test` (one `.passed` marker per cargo test target; doctests are out of v0), `:lint` (clippy-driver with
the member's `[lints]` as flags, `clippy.toml` as an input, `-D warnings` when the policy says so),
`:coverage` (refuses until P8), and one target per action in the policy. Every `:debug :release :test
:lint` carries the workspace `:check` as a validation. No compile action takes a `Cargo.toml` as an
input, so a policy edit re-runs the check and nothing else. The `cargo_unit` targets themselves are named
by content id (`<crate>-<version>_<hash>`).

Refused at load (the rule `fail`s with the fix): a table whose `RUSTC` is neither a version of `rules/rust/pins.bzl`
`RUST_VERSIONS` nor one the table records as pinned by the repository (`TOOLCHAIN.origin`, section 6), or whose recorded
`TOOLCHAIN` hashes are not the pinned ones; a path that is not a member in the table; lto, a codegen backend, rpath, incremental or
split-debuginfo profile fields (v0).

## 3. The files and who writes them

Everything is relative to the repository root, which is also the Buck2 root cell and the Cargo workspace
root (v0). "Committed" means the file belongs in git.

| file | written by | when | committed | loaded / read by |
|---|---|---|---|---|
| `.buckconfig` | `init` | once, never overwritten | yes | Buck2 (section 7) |
| `toolchains/BUCK` | `init` | once | yes | the `toolchains` cell: `rust_toolchains(extra = EXTRA_RUST_VERSIONS)` |
| `buildrules-pins.toml` | you | when you need a Rust version `pins.bzl` does not pin (section 6) | yes | `sync`, `check` |
| `toolchains/rust_pins.bzl` | `init` (empty), `sync` | every sync | yes | `toolchains/BUCK`, the generator |
| `platforms/BUCK` | `init` | once | yes | `buildrules_execution_platforms` (remote by default; section 14) |
| `.buckconfig.local.example` | `init` | once | yes | people (the real `.buckconfig.local` is gitignored and holds the endpoint) |
| `rust-toolchain.toml` | `init` if absent | once | yes | cargo, `sync`, `check`, the rules (section 6) |
| `Cargo.toml` (virtual workspace) | `init` if absent; `cargo new/init/adopt` add `members` | once, then cargo's | yes | cargo, `sync`, `check` |
| `<member>/Cargo.toml` metadata table | `cargo new/init/adopt` | once | yes | `sync` (policy) |
| `<member>/BUCK` | `cargo new/init/adopt` | once; never rewritten, other rules in it are kept | yes | Buck2 |
| `buildrules.lock.bzl` | `sync` (the generator) | every sync | yes | `buildrules.bzl`, `check` |
| `buildrules.bzl` | `sync` | every sync (rewritten only if different) | yes | every BUCK file |
| `BUCK` (root) | `sync`, only if absent | once; yours after that, but it must keep the `cargo_workspace` call | yes | Buck2 |
| `third_party/buildrules/BUCK` | `sync` (the generator, `buckgen.zig`) | every sync | yes | member packages (registry units) |
| `third_party/buildrules/crate_sizes.tsv` | `sync` (`buckgen.zig`, sizes) | every sync | yes | the generator; each row's sha256 was checked against `Cargo.lock` |
| `buck-out/buildrules/` | `sync` | scratch: cargo home, unit graphs, the `--check` output | no (under `buck-out/`) | `sync` |

Generated files say "Do not edit" in their first line. `check` fails on a hand-edited `buildrules.bzl`;
`sync --check` fails on any hand-edited generated file.

## 4. The table: `buildrules.lock.bzl`, schema 2 **[p7]**

Pure Starlark data (literals only), deterministic: a second `sync` on unchanged inputs is byte-identical.
The first lines, which readers outside Starlark (the Zig CLI) parse by line **[chosen]**:

```
SCHEMA = 2
RUSTC = "1.95.0"
TARGET = "x86_64-unknown-linux-gnu"
CARGO_LOCK_SHA256 = "<64 lower-case hex: the sha256 of Cargo.lock's bytes>"
MANIFEST_SHA256 = {
    "Cargo.toml": "<sha256>",
    "crates/hello/Cargo.toml": "<sha256>",
    "rust-toolchain.toml": "<sha256>",
}
```

`MANIFEST_SHA256` is written one entry per line, sorted, closed by a `}` at column 0; its keys are the
root `Cargo.toml`, `rust-toolchain.toml`, `buildrules-pins.toml` (when there is one) and every member's `Cargo.toml`. Then: `TOOLCHAIN` (section 6), `WORKSPACE` (resolved
policy, `clippy_conf`), `PACKAGES` (one row per member: `path`, `version`, `check_cfg`, `lints.rust`,
`lints.clippy`, `actions`, `deny_warnings`, `default_action`), `GRAPHS` (whole-workspace graphs; empty from
the CLI), `MEMBERS` (per member and verb `build|test|release`: `roots`, `units`, `graph_units`) and
`UNITS` (one entry per distinct unit: `crate`, `version`, `source` = `path|registry`, `target_kind`,
`crate_types`, `target_name`, `mode`, `side`, `edition`, `crate_root`, `features`, `cfgs`, `profile`,
`deps` = `[extern name, unit id]`, `path` or `sha256`, `test_flags`). A unit id is
`<crate>-<version>:<10 hex>`, the hash of the unit's body (profile name excluded: rustc never sees it).

A reader refuses a table whose `SCHEMA` is not the one it understands (`2`). `sync` first lets cargo resolve: `cargo fetch` creates
`Cargo.lock` if there is none and changes it only as far as the manifests require (a new dependency adds its crates; nothing else is
upgraded), and downloads the sources into `buck-out/buildrules/cargo-home`. The unit graphs are then made by
`cargo build|test|build --release -p <member> --locked --offline --target x86_64-unknown-linux-gnu -Z
unstable-options --unit-graph` under `RUSTC_BOOTSTRAP=1` (nothing compiles).

`buildrules.bzl` (written by `sync`, verbatim in `cli/src/contract.zig`) loads the table's names and defines
`CARGO`, `THIRD_PARTY = "//third_party/buildrules"` and the two bound macros.

## 5. Metadata schema **[p7]**, defaults **[chosen]**

Policy only. Profiles, lints, features and dependencies stay in cargo's own tables; the generator reads
them from there. Allowed in `[workspace.metadata.buildrules]` and, overriding it per key, in
`[package.metadata.buildrules]`; any other key is refused by `sync`, naming the key and the file.

| key | type | meaning |
|---|---|---|
| `default-action` | string | an action or a step; recorded in the table (`WORKSPACE`, `PACKAGES`), no target is derived from it in v0 |
| `actions` | table: name -> non-empty list of steps | `ci = ["lint", "test"]`; a name may not be a step name |
| `lint.deny-warnings` | bool | clippy `-D warnings` for `:lint` |

Steps: `lint`, `debug`, `test`, `release`, `coverage` (`coverage` refuses until P8).

`init` writes this root manifest **[chosen]** (a virtual workspace: v0 refuses a root `[package]`):

```toml
[workspace]
resolver = "3"
members = []

[workspace.metadata.buildrules]
default-action = "ci"

[workspace.metadata.buildrules.actions]
ci = ["lint", "test"]

[workspace.metadata.buildrules.lint]
deny-warnings = true

[profile.dev]
incremental = false
```

`incremental = false` is required: an incremental profile cannot be built hermetically and `sync` refuses
it with this fix. `cargo new/init/adopt` add `[package.metadata.buildrules]` (an empty table with a
comment; absent keys inherit the workspace) to the member.

## 6. `rust-toolchain.toml`, the Rust version table and the toolchain lock

Required **[chosen]**: `sync` and `check` fail without it. Only `channel` is read, and it must be an exact
release `N.N.N` (`stable`, `1.95`, a beta, a dated nightly are refused: a floating channel is a different
compiler tomorrow); a `path` key is refused (a toolchain on this machine is not pinned). `init` writes
`channel = "1.95.0"`, `components = ["clippy", "rustfmt"]`, `profile = "minimal"` unless `--rust-version`.
Plain `cargo` (rustup) and Buck2 therefore use the same compiler, and `rust-toolchain.toml` is what **selects** the version.

**The version table** **[chosen]**: `rules/rust/pins.bzl` holds `RUST_VERSIONS`, a dict of exact version -> `rustc`, `rust_std`, `cargo`, `clippy`, each `{"sha256", "size"}` of the
`.tar.gz` of that component, fetched from the versioned URL `static.rust-lang.org/dist/<component>-<version>-x86_64-unknown-linux-gnu.tar.gz`
(no date anywhere). The toolchain refuses to exist unless `rustc --version` and `cargo --version` print the prefixes `rustc <version> (` and
`cargo <version> (`; plus `RUST_DEFAULT` (the version `toolchains//:rust` is) and `RUST_OLDEST` (the oldest supported).
Today: 1.95.0 (default) and 1.85.0 (oldest; edition 2024 needs 1.85). The default row also pins the `llvm-tools-preview`
component (`llvm_tools`, for `isa_audit`, section 11). Nothing is fetched without a hash.

`rust_toolchains()` declares one toolchain per version: `toolchains//:rust_<v>`, `:sysroot_<v>`, `:cargo_<v>`, `:clippy_<v>` and the
pins behind them (`<v>` is the version with `_` for `.`: `rust_1_85_0`). `:rust`, `:sysroot`, `:cargo`, `:clippy`
(and `:llvm_tools`) are aliases of the default's. A toolchain is an input of every compile, test and lint action of its
units, so **two versions never share an action key**.

**Which toolchain a target uses:** the table's `RUSTC` (the macros pass it as `rustc =`), or `RUST_DEFAULT` for the hand-written
`rust_library`/`rust_binary`/`rust_test`. A **target platform can override it** for a whole build with the `rust_version`
constraint (`buildrules//platforms:linux_x86_64_rust_1_85_0`): `rules/rust/select.bzl` is a `select` on it. That is how the CI matrix
(section 10) builds the same sources with the oldest compiler; it changes the configuration, so output paths and keys differ too.
A proc-macro and a build script follow their unit's version (they are dependencies in the same configuration), so rustc loads
only proc-macros it built.

**A version of your own: `buildrules-pins.toml`** at the repository root (optional, committed, hand-written). An unknown version
is **refused** (by `sync`, with this format in the message, and by the rules at load) unless this file supplies the hashes:

```toml
[rust."1.86.0"]
[rust."1.86.0".rustc]
sha256 = "<64 lower-case hex>" # the `hash` of rustc-1.86.0-x86_64-unknown-linux-gnu.tar.gz in the dist manifest
size = 122722040               # bytes of that file
[rust."1.86.0".rust-std]       # likewise rust-std, cargo and clippy (the `clippy-preview` manifest entry's tarball)
sha256 = "..."
size = 0
[rust."1.86.0".cargo]
...
[rust."1.86.0".clippy]
...
```

Only these tables and keys; `#` comments; no `date` key (the URLs are the versioned ones); all four components, each with sha256 and a positive size; a version
that `pins.bzl` already pins is refused (the reviewed hashes win). `sync` copies the file into `toolchains/rust_pins.bzl`
(`EXTRA_RUST_VERSIONS`, pure data in the shape of one `RUST_VERSIONS` row; `toolchains/BUCK` loads it:
`rust_toolchains(extra = EXTRA_RUST_VERSIONS)`; `init` writes it empty). The pin is therefore committed twice, in the file you wrote and
in the file generated from it, and a wrong hash fails the download (Buck2 checks it), never the build silently.
`rustc --version` of a user-pinned version must start with `rustc <version> (`.

**The toolchain lock** is where the choice is recorded **[chosen]**. `sync` writes into `buildrules.lock.bzl`, after
`MANIFEST_SHA256`:

```
TOOLCHAIN = {
    "version": "1.85.0",
    "origin": "builtin",            # or "buildrules-pins.toml"
    "default": False,               # is it RUST_DEFAULT: if not, every third-party unit names `rustc = "1.85.0"`
    "sha256": {"cargo": "...", "clippy": "...", "rust_std": "...", "rustc": "..."},
}
```

with `RUSTC` unchanged. The rules compare it with `pins.bzl` at load (a pin bumped under a table is red until `sync` rewrites it, as a visible
diff). Tables written before this field have none and are still read (no hash check; `default` is then assumed). The files that
must agree: `rust-toolchain.toml` (the channel), `RUSTC`/`TOOLCHAIN` in the table, `pins.bzl` or `rust_pins.bzl`;
`check` compares the first two and `rust_pins.bzl` with `buildrules-pins.toml` (`STALE:` when they differ, the file itself
is part of `MANIFEST_SHA256`); the rules compare the table with the pins. `sync` builds `toolchains//:cargo_<v>` and
`toolchains//:sysroot_<v>` for the chosen version (built on the farm; no host cargo, rustc or cc is read), and writes
`toolchains/rust_pins.bzl` first, because that build loads it.

## 7. The `.buckconfig` that `init` writes **[chosen]**

(`CELL` is `--cell`, default `root`.)

```
[cells]            CELL = .   prelude = prelude   toolchains = toolchains   none = none
                   buildrules = buildrules-ext          (--path: buildrules = <RELPATH>)
[cell_aliases]     config = prelude  ovr_config = prelude  fbcode = none  fbsource = none  fbcode_macros = none  buck = none
[external_cells]   prelude = bundled   buildrules = git                    (--git only)
[external_cell_buildrules]   git_origin = <ORIGIN>   commit_hash = <40 hex>   (--git only)
[buildfile]        name = BUCK
[parser]           target_platform_detector_spec = target:CELL//...->buildrules//platforms:linux_x86_64
                       target:toolchains//...->buildrules//platforms:linux_x86_64
                       target:buildrules//...->buildrules//platforms:linux_x86_64
[build]            execution_platforms = CELL//platforms:exec
[buck2]            materializations = deferred   sqlite_materializer_state = true   defer_write_actions = true
[project]          ignore = buck-out, .git
```

`--git` takes an https URL, or `file:///absolute/path` for a local clone (the proof of concept); `--commit`
must be a full 40-hex SHA (a branch or tag is not a pin). `--path` must be inside the repository and
normalized (Buck2 refuses `..`). An existing `.buckconfig` is never merged: `init` exits 1 and prints the
config it needs. The remote-execution endpoint and worker properties are **not** here: they live in
`.buckconfig.local` (gitignored, `[buck2_re_client]` and `[buildrules_re] linux_x86_64_properties`), and
the execution platform runs nothing locally unless `-c buildrules_re.mode=local` asks for it (section 14). `init` also adds `.buckconfig.local` and `buck-out/` to
`.gitignore`.

## 8. Commands, files touched, exit codes

Exit codes of every command **[chosen]**: `0` ok; `1` failed, stale or refused (every problem is printed,
with the fix); `2` usage error.

| command | does | runs |
|---|---|---|
| `init [DIR] (--path P \| --git O --commit S) [--cell N] [--rust-version V]` | section 3 rows marked `init`; idempotent | nothing |
| `cargo new PATH [--cargo C] [--lib]` | `cargo new --vcs none`, then adopt | the pinned cargo, if `--cargo` |
| `cargo init [PATH] [--cargo C] [--lib]` | same for an existing directory | same |
| `cargo adopt [PATH...]` | metadata table + BUCK + `members` for packages that already build with cargo; no PATH = every member | nothing |
| `sync [--check] [--cargo C --rustc R --pins F] [--buck2 B]` | section 3 rows marked `sync`; with no tool flags builds `toolchains//:cargo_<v>`, `:sysroot_<v>` (the version of `rust-toolchain.toml`) and `buildrules//rules/rust:pins.bzl` through `buck2`; the generator is part of the program | cargo |
| `check [--dir D]` | read-only comparison, below | nothing |

`cargo new/init/adopt` refuse (exit 1, nothing written) unless the root `Cargo.toml` is a virtual
workspace; `init PATH` and `adopt .` refuse the workspace root itself.

`check` exits 1 when any of these holds (each printed with `buildrules sync` as the fix, `STALE:` when the
table is out of date): `rust-toolchain.toml` missing / floating / has `path`; the table missing, or of
another `SCHEMA`; `Cargo.lock` missing or its sha256 differs from `CARGO_LOCK_SHA256`; the channel differs
from `RUSTC`; `toolchains/rust_pins.bzl` differs from what `buildrules-pins.toml` generates, or that file is invalid; the root or any member `Cargo.toml` differs from `MANIFEST_SHA256`, a member exists that the
table does not know, or the table lists one that is gone; `buildrules.bzl` differs from what `sync` writes;
the root `BUCK` has no `cargo_workspace` call; a member has no `cargo_package` call. It does not compare
the compiler with `pins.bzl` (that needs the cell; the rules do it at load).

`sync --check` is the heavier gate: it regenerates into `buck-out/` and exits 1 unless every generated
file is byte-identical to the committed one (it needs the pinned cargo, never the network for sizes).

On the build side the same staleness is red too: `:check` (the validation on `:test :lint :debug
:release`) compares the sha256 of `Cargo.lock`, `rust-toolchain.toml` and every `Cargo.toml` with the
table. Two layers on purpose: `check` is the cheap pull-request gate, `:check` is what makes a stale
table impossible to build.

## 9. Convergence with p7, and v0 limits

- The macros' `ws` handling (a workspace below the cell root) is p7's and works; the CLI does not
  produce it in v0.
- The generator is Zig, in the command line (`unitgen.zig`: graphs, Cargo.lock and the manifests to the table; `buckgen.zig`: the table to the
  registry package and the sizes; `toml.zig` and `val.zig`: the readers and writers). Its output is byte for byte what the Python generator
  it replaced wrote: the content ids are the hashes of the same canonical JSON. No interpreter is needed anywhere.
- Limits: Linux x86_64 only; crates.io registry only (git and alternate registries refused); a root
  `[package]` refused; `members` globs other than `dir/*` refused by `adopt`/`check`/`sync`; every
  workspace package must be listed in `members`; doctests and coverage out; lto / rpath / incremental refused;
  `sync` needs the network the first time a registry crate is fetched (cargo's own cache under
  `buck-out/buildrules/cargo-home`).

## 10. The CI matrix **[chosen]**

`ci/BUCK` is the matrix; each cell is a target, and the whole matrix is one command on the farm:

| target | builds and tests |
|---|---|
| `//ci:rust_default` | `examples/hello` (library welded to its tests, binary run by `run_check`), the p4ws cargo units that build (build scripts, `links`, tests), `examples/zig` on the default zig |
| `//ci:rust_oldest` | the same Rust targets with `RUST_OLDEST` (`rules/matrix.bzl` `rust_at`: the same sources under a configuration transition that sets the `rust_version` constraint) |
| `//ci:zig_next` | `examples/zig` on the other pinned zig. The zig rules default to 0.12.0, which is also the oldest pinned; `zig_next` is 0.15.2 |
| `//ci:isa_v1`, `//ci:isa_v3` | `examples/isa` at the baseline and at x86-64-v3 (`isa_at`): the machine code is audited (section 11) and the test runs on a worker of the level |
| `//ci:matrix` | all of the above |

A test of these examples is a build action that writes a `.passed` marker (welded into its library), so `buck2 build` is the test.
A developer reproduces one cell by hand with a target platform: `buck2 build --target-platforms
buildrules//platforms:linux_x86_64_rust_1_85_0 //examples/hello:hello_runs`. A Rust version added to `pins.bzl` needs its
`rust_version` constraint (platforms/BUCK builds it from the table) and a line in `rules/matrix.bzl` (refused at load otherwise).

`ci/negative` holds planted defects that must stay RED; it is compatible only with the platform it breaks on, so `//ci:matrix`
and wildcard builds skip it.

## 11. ISA levels and platforms **[chosen]**

`rules/isa.bzl` is the one table, `ISA_LEVELS`: `x86-64-v1..v4` and `armv8.0-a..armv8.4-a` (a farm's ladder may stop at 8.4), each with the
REAPI `ISA` value a farm matches workers on and the flags of every tool:

| level | `ISA` value | rustc | zig cc | Mojo (`mojo build`, verified for x86-64: section 12) |
|---|---|---|---|---|
| x86-64-v1 | `x86-64` | `-C target-cpu=x86-64` | `-mcpu=x86_64` | `--target-cpu x86-64` |
| x86-64-v2..v4 | `x86-64-vN` | `-C target-cpu=x86-64-vN` | `-mcpu=x86_64_vN` | `--target-cpu x86-64-vN` |
| armv8.0-a | `armv8.0-a` | `-C target-cpu=generic` | `-mcpu=generic` | `--target-cpu generic` |
| armv8.K-a | `armv8.K-a` | `-C target-cpu=generic -C target-feature=+v8.Ka` | `-mcpu=generic+v8_Ka` | `--target-cpu generic --target-features +v8.Ka` |

`native` is never passed: a farm matches "at least, within the family", so host-tuned code would be cached under a lower level's key.
The rustc and zig columns are exercised on the farm for x86-64 (`examples/isa`, `ci/negative`); the Arm rows are
data only (no Arm worker, no Arm exec platform: a test at an Arm level finds no execution platform and is refused).

**Target platforms** (`platforms/BUCK`): the `isa_level` constraint setting (values `isa_<id>`, ids like `x86_64_v3`, `armv8_2`) and one platform per
level, `linux_<id>` (`linux_x86_64_v3`, `linux_armv8_2`): `[linux, <family cpu>, isa_<id>]`, so an x86 level never meets an
aarch64 cpu. A platform without a level (`linux_x86_64`) passes no flag, and its action keys are what they were before.
The level reaches the compilers in argv (`rustc_isa_flags()` on units that run on the target; `cxx_toolchains(target_cpu = zig_cpu())`
for C), and is in the configuration, so a v1 and a v3 build differ in output path and in key.
A build script and a proc-macro run on the build host: they never get the flags.

**Execution platforms** (`platforms/exec`, `buildrules_execution_platforms(isa_platforms = ...)`): the first is ISA-agnostic
(the configured property set, `ISA=x86-64`) and takes every compile. One more per x86 level v2..v4, `exec_<id>`, has the same
properties with `ISA=<level>` and carries an `exec_isa` constraint in its configuration. They are separate platforms because Buck2
puts `remote_execution_properties` on an execution platform, not on an action. **`exec_compatible_with` can select on `isa_level`**
(verified: `buck2 audit execution-platform-resolution` picks `exec_x86_64_v3` for the v3 test and the agnostic platform for its
compile), so no per-level run rule is needed: `test_exec_compatible_with()` is a `select` from the target's level to its
`exec_isa` value. x86-64-v1 needs no platform of its own (any x86-64 worker).

**A test is two targets** (`test_run.bzl`): `<name>__bin` compiles on the agnostic platform, `<name>` runs it with
`exec_compatible_with = test_exec_compatible_with()`; `rust_test` and `cargo_unit` (mode `test`) do this. `test_run` also **checks while the build
graph is analysed** that the execution platform it was placed on reports at least the level the test was built for (`exec_isa`, an
`exec_dep`, reads it from the platform's configuration). A v3 test run left without the property fails with the fix:
`built for ISA x86-64-v3 but its execution platform reports ISA=x86-64 ... set exec_compatible_with = test_exec_compatible_with()`.
`//ci/negative:v3_test_without_isa_property` is that defect, kept red. The farm schedules on the property: a worker reports every level it
reaches, and `ISA=x86-64-v3` is served by v3 and v4 workers.

**`isa_audit`** (`rules/rust/isa_audit.bzl`) reads the machine code instead of the argv: the pinned `llvm-objdump` (from the
`llvm-tools-preview` pin, run as an action) disassembles a binary and the action fails unless it holds `ymm` (256-bit AVX2)
instructions when the level is v3 or v4, and none below. A flag that never reached rustc leaves a green, cached, wrong build; this is the
gate for it. `examples/isa` is the example: `sum` is vectorized with `vpaddd ymm` at v3, and one of its tests executes an AVX2 instruction.

Limits: C compiled by a crate's build script uses the zig default CPU (no ISA flag); only x86-64 runs. Mojo: the x86-64 flags are accepted and change the test binary (section 12); the Arm spellings are data only.

## 12. Mojo **[chosen]**

mopm owns what "build Mojo" means; buildrules runs mopm's answer as cached, remote Buck2 actions, as cargo decides and rustc runs.
There is no second Mojo driver here. The design is `mopm-unit.md` (v2); this section is what the rules, the command line and the
files do. Everything below was exercised on the farm with `local: 0` (see "Status" at the end).

### 12.1 What a user sees

```
mopm lock                                          # mopm's own: mopm.toml -> mopm.lock (needs the registry)
buildrules mojo sync                               # mopm's unit graph of every package -> buildrules.mojo.lock.bzl
buck2 build //pkg:lib //pkg:test //pkg:build //pkg:coverage
buildrules mojo check                              # offline, read-only; also run by `buildrules check` when a repository has Mojo packages
```

```python
# pkg/BUCK: one line per package; a workspace member (a path dependency) has a BUCK file of its own
load(":buildrules.mojo.bzl", "mojo_package")
mojo_package(path = ".", natives = {"libcnative.so.1": "//registry/cnative:libcnative"})   # natives only if the graph names some
```

Each package is a mopm project: its own `mopm.toml`, `mopm.lock` and graph (`mopm plan --unit-graph` describes the root package's `lib`,
`bin`s and tests, and the members and registry packages it imports; a member's tests are in the member's own graph).

| target | what |
|---|---|
| `:lib` | the package's `.mojoc` (`mopm unit build`, mode `lib`) |
| `:<stem>__bin`, `:<stem>` | one test file: the compile (agnostic platform) and the run (the target's ISA platform) |
| `:test` | every test run |
| `:bin_<name>`, `:build` | the `[targets] bins` of `mopm.toml`; `:build` is the library and the binaries |
| `:<stem>__cov_bin`, `:<stem>__cov` | the same test as a debug build, and its run under kcov: a Cobertura report in repository paths |
| `:coverage` | the package's line coverage from those reports (`coverage.txt`); red if a source of the library is in no report |
| `:ci` | `:build` and `:test` |
| `:check` | the validation every step above carries: the files the table was made from still hash to what it recorded, and `toolchains/mojo_pins.bzl` still holds the table's toolchain (12.6) |
| `:mopm.toml`, `:mopm.lock` | the package's own manifest and lock as targets, so a package that imports it as a member can name them in its `:check` |

`mopm.toml` rejects unknown top-level keys, so pipeline policy (a `[tool.buildrules]` table with a default action or coverage floor) cannot
live there; the targets above are fixed and `mojo_package` takes policy as arguments. (This is a mopm limit; see "Limits".)

### 12.2 Files

| file | written by | committed | read by |
|---|---|---|---|
| `mopm-toolchain.toml` | you | yes | `mojo sync`, `mojo check`, the `:check` of every package below |
| `BUCK` of the directory of `mopm-toolchain.toml` | `mojo sync`: created if the directory has none, else the `export_file` is appended once (not needed when the package is in that directory) | yes | the `:check` names the file as `//<dir>:mopm-toolchain.toml` |
| `buildrules-pins.toml` `[mopm."V"]` | you, only for a mopm version `rules/mopm/pins.bzl` does not pin | yes | `mojo sync`, `mojo check` |
| `<pkg>/buildrules.mojo.lock.bzl` | `mojo sync` | yes | `buildrules.mojo.bzl`, `mojo check` |
| `<pkg>/buildrules.mojo.bzl` | `mojo sync` | yes | the BUCK file |
| `toolchains/mojo_pins.bzl` | `mojo sync` | yes | `toolchains/BUCK` (`mojo_toolchains(MOJO_TOOLCHAINS)`) |
| `toolchains/mopm_pins.bzl` | `mojo sync` | yes | `toolchains/BUCK` (`mopm_toolchains(extra = EXTRA_MOPM_VERSIONS)`) |

`mopm-toolchain.toml` is found by walking up from the package directory to the nearest one, as rustup finds `rust-toolchain.toml`:

```toml
[toolchain]
mopm = "0.0.1"     # an exact release: a version of rules/mopm/pins.bzl, or one buildrules-pins.toml gives a URL, sha256 and size for
mojo = "1.0.0"     # an exact release mopm pins a toolchain for; the graph is made for it
```

**It is required**, like `rust-toolchain.toml`, and there is no implicit default: without it `mojo sync`, `mojo check` and the analysis of every
package stop, name `mopm-toolchain.toml`, and print a minimal example (`[toolchain]`, `mopm = "0.0.1"`, `mojo = "1.0.0"`). Required was chosen because
the Rust side is, and one rule is easier to teach; the other choice, a default in `sync`, would pick a compiler for a repository that never named one.

### 12.3 The table: `buildrules.mojo.lock.bzl`, schema 1

```python
SCHEMA = 1
MOPM = {"version": "0.0.1", "origin": "builtin"}          # origin: "builtin" or "buildrules-pins.toml"
MOJO = "1.0.0"
CLOSURE_SHA256 = "<mopm's hash of the toolchain closure>"  # a second copy of the graph's, see 12.6
MANIFEST_SHA256 = {"mopm.toml": "<sha256>", "mopm.lock": "...", "../../mopm-toolchain.toml": "...", "util/mopm.toml": "..."}
GRAPH_JSON = r'''<`mopm plan --unit-graph --locked --mojo M`, byte for byte>'''
GRAPH = json.decode(GRAPH_JSON)
```

The graph is mopm's text, so reviewing the diff of the table is reviewing mopm's output. `MANIFEST_SHA256` lists every file the graph was made
from that the graph does not hash itself: the package's `mopm.toml` and `mopm.lock`, the toolchain file (path relative to the package) and the
`mopm.toml` of every path dependency. The sources and their sha256 are in the graph.

`toolchains/mojo_pins.bzl` is the `toolchain` object of the graphs, copied (two packages' graphs for one Mojo version must agree):
`subdir`, `cc_target`, `closure_sha256`, `zig` (version, url, sha256, size) and `components` (`mojo-compiler`, `libgcc`, `libstdcxx`, each with url, sha256,
size). **buildrules has no Mojo pin of its own**: `toolchains//:mojo_<v>` fetches those packages by sha256 and the zig that links, unpacks them
(`conda_unpack`; busybox for the zig) and names the closure hash. A new Mojo version is a mopm release plus a `sync`.

### 12.4 How a unit becomes an action

`mopm unit build --unit ID --graph G --out O --toolchain T [--src S] [--deps D] [--natives N]` is the one compile entry (offline; it checks
every declared input, then executes `T/mojo_compile` with an empty environment). Each unit is one action of `rules/mojo/unit.bzl`:

- `--graph`: the unit's **slice**: the graph's header, the unit's entry without its `key`, and every unit it imports reduced to `id, package, version, kind, root, deps, outputs, mojoc`.
  mopm's `key` hashes every dependency's key, so it moves with any edit below the unit; Buck2's own key (the digests of the inputs) replaces it, and a
  dependency's sources, key and profile are not inputs of the unit that imports it. This is what makes unchanged `.mojoc` bytes stop a cascade.
- `--src`: the unit's sources at the paths the graph names; the target's `srcs` are the graph's, so a file the graph does not name is not an input.
- `--deps`: `<package>.mojoc` of every unit in the closure, flat: the outputs of the dependency targets (a member's `:lib`, a registry package's `prebuilt_<name>`),
  checked against the graph's closure at analysis.
- `--natives`: the native libraries by soname, the targets of `natives = {...}`. mopm checks each against the sha256 in the graph before it compiles anything.
  (mopm's graph names the natives of registry packages; a member's `[native.<id>]` is not in it yet. The example's library is the native of the registry package `cnative`.)
- `--toolchain`: a directory assembled from `mojo_launch` (as `mojo_compile`), the wrapper (`wrapper`), the compiler closure (`compiler`), the zig (`zig`), `CLOSURE_SHA256`
  and `toolchain.cfg`. `mojo_launch` puts the wrapper's options (where the closure and the zig are) in front of mopm's arguments, inserts the ISA flags after `build`,
  and rewrites mopm's `--source-root` for `precompile` (below). It runs no compiler and owns no policy.

A registry dependency is a `pinned_file` (URL, sha256, size of the `.conda` the graph names for this Mojo version) unpacked by `prebuilt_unpack`, never compiled.
`-c buildrules.url_map="<from>=<to> ..."` in the `.buckconfig.local` of the cell that declares the download (the toolchain downloads are in the `toolchains` cell, whose
`.buckconfig.local` is its own) changes where a download is fetched from and nothing else: the sha256 is still checked.

**Tests and ISA.** `<stem>__bin` is `mopm unit build` of the test unit on the agnostic platform (the ISA flags `--target-cpu x86-64-vN` are in `toolchain.cfg`, so a v3 and a v1
build are two keys); `<stem>` runs the binary with the compiler's `lib/` on `LD_LIBRARY_PATH` (the binary needs `libKGENCompilerRTShared.so`) and the platform's
`exec_compatible_with`, and checks at analysis that its platform has the level (as section 11). A `.mojoc` carries no ISA flag: libraries are shared by every level.
It is also a `buck2 test` target (`ExternalRunnerTestInfo`).

**Coverage** on mopm's units: the test unit's profile in the slice is replaced by `{opt: 0, assert: all, debug: true}` (mopm passes `-g`), the link goes
through `cov_zig` (it keeps the debug information and rewrites the action's directories out of it), kcov v42 built from source with the pinned zig (`rules/coverage`
`kcov_build`, `cov_zig`, `debug_relocate`, `cov_normalize`) runs the binary in a tree of copies of the test source and the library's sources at the relative names the line
tables use, and `cov_normalize` maps the report to repository paths. `cov_run` refuses a binary that names the library's sources by the directory they were staged in. Branch coverage,
`covcheck`'s policy and floors, and the census are not ported.

### 12.5 Versions: pinned mopm, the Mojo version

`rules/mopm/pins.bzl` is a table like Rust's: `MOPM_VERSIONS` (url, sha256, size, unpack directory) and `MOPM_DEFAULT`. `0.0.1` is a **stand-in**: built on the farm from a development tree
of mopm (`//:mopm-tarball`, with a `RELEASE-PENDING` file), at a URL where the release job will publish it; until then a machine points the download at its copy with `url_map`.
A version not in the table is refused by `mojo sync` (the message names `buildrules-pins.toml` and the table to add) unless `buildrules-pins.toml` has `[mopm."V"]` with `url`, `sha256`, `size`.
The mopm binary is an input of every unit action: a mopm bump re-keys every unit on purpose. The Mojo version comes from the graph: mopm pins one (`1.0.0`) today, so no package here
builds for two Mojo versions; `mopm lock` writes the lock for each version `[package] mojo` lists and `plan --mojo M` makes the graph for one, so two versions would be two units, two actions,
two cache entries, and the refusal `http_core 1.2.0 has no .mojoc for Mojo 1.1.0 (published for: 1.0.0). Build with mojo 1.0.0, ...` is mopm's.

### 12.6 What is checked, and where

| defect | caught by | how it reads |
|---|---|---|
| source, `mopm.toml`, `mopm.lock`, a member's `mopm.toml` or `mopm-toolchain.toml` edited without a sync | `mojo check` (offline); the unit action; `:check` for everything but a source (the build, on every step) | `STALE: <file> changed since `buildrules mojo sync` (the table has sha256 A, now B)`; mopm: `input src/x.mojo has sha256 B, but the graph declares A` (exit 4) |
| a new test file or library source | `mojo check` | `<file> is a test file that the table does not know` |
| a failing test | the test run; the coverage run (kcov exits with the test's status) | the test's own output |
| a prebuilt whose bytes are not the pinned ones | the download | `Invalid sha256 digest. Expected A, got B` |
| the toolchain's closure hash differs from the graph's | `mopm unit build` | `the toolchain at T is closure A, but the graph pins B` |
| the two copies of the closure hash in the table differ | analysis; `mojo check` | `the table records toolchain closure A but its unit graph pins B: the file was edited by hand` |
| the table's Mojo is not the graph's, or mopm-toolchain.toml names another | analysis; `mojo check`; `mojo sync` (mopm exit 4) | `the table says Mojo 1.1.0 but its unit graph is for Mojo 1.0.0`; `mopm has no pinned toolchain for mojo 1.1.0` |
| a native library other than the pinned one | `mopm unit build` | `native library X has sha256 B, but the graph declares A` |
| a library source no test compiled | `:coverage` | `<file> is in no report: no test compiled it, or kcov could not open it` |
| `toolchains/mojo_pins.bzl` edited without a sync (a `cc_target`, a hash, a component) | `:check` at analysis; `mojo check` | `toolchains/mojo_pins.bzl and the table's unit graph disagree about the Mojo 1.0.0 toolchain (cc_target)` |
| `mopm-toolchain.toml` says another Mojo than the table was made for | `:check` (the file's hash); `mojo check` | `examples/mojo/mopm-toolchain.toml is not what the Mojo table was made from (sha256 A, the table says B): run `buildrules mojo sync``  |
| a test at an ISA level on a platform without it | analysis | as section 11 |

### 12.7 Findings that shaped the rules

- **mopm's `precompile` source root.** mopm passes `--source-root=<stage>/src` and the package `<stage>/src/<name>`; the wrapper's contract is that the source root *is* the package
  directory (only then does the compiler run from the package's parent and record `<name>/<file>.mojo`). With mopm's arguments the `.mojoc` recorded the absolute staged path: the same
  package at two paths was two `.mojoc`s (measured: `9f32aa...` against `72e42a...` after the fix, byte-identical at two paths), and a test built against it named the library's sources by
  an absolute directory kcov could not open. `mojo_launch` rewrites the root for `precompile` until mopm passes the package directory. For `build` the root is `<stage>/src` and
  the wrapper strips it, which is right.
- **`mopm unit test` runs the binary with an empty environment**, so a test that needs `libKGENCompilerRTShared.so` cannot pass in that mode on a hermetic toolchain. The run here is its own action.
- **kcov needs `personality(ADDR_NO_RANDOMIZE)`**, which the farm's worker sandbox answers with ENOSYS. kcov is patched to go on (the binaries are not position independent and kcov runs `--skip-solibs`).
- **`mopm lock` contacts the registry even for a project of path dependencies**, so the examples' `mopm.lock` files are written by hand (their closure hash is mopm's own, read from its refusal).
- **`mopm pack` refuses a package with `[native.<id>]`**, and puts no native library in the `.conda`; a registry package's native library is declared in the consumer's `mopm.lock`, and its bytes come from buildrules.

### Status

The examples: `examples/mojo/ws` (`app` -> `util` -> `base`, three packages in a chain, plus the registry package `cnative` with a C library built by `rules/cxx`'s `c_shared`) and
`examples/mojo/registry/cnative` (the publisher's side: its `.mojoc`, `mopm pack`, the library). The proofs and their `Commands:` lines are in the commit message of the branch `mojo`.

Limits: linux x86-64 only; one Mojo version (mopm pins one); the coverage is line coverage of what the compiler emitted code for (a function no test reaches emits none, so the percentage is an
upper bound); workspace members' natives are not in mopm's graph; `mopm unit test` and the supervisor, a published mopm release, and Arm are not covered.

## 13. npm packages: `npm_package(path = ".")` **[chosen]**

The npm counterpart of `cargo_package`: one directory with a `package.json` and a `package-lock.json`
(`lockfileVersion` 3) becomes Buck2 targets, with the lockfile as the single source of what is installed
and package.json as the single source of what is run.

### User view

```
buildrules npm sync [PATH...]        # after npm install / npm update, or an edit of a script or of the "buildrules" key
buildrules npm check [PATH...]       # offline, read-only; the pull-request gate
buck2 build //pkg:typecheck //pkg:test //pkg:build //pkg:dist //pkg:ci
npm ci && npm test && npm run build  # still work, untouched: nothing here changes how npm reads its files
```

```python
# pkg/BUCK (written once by `sync` if absent)
load(":buildrules.bzl", "npm_package")            # generated: binds the table to the macro

npm_package(
    path = ".",                                    # v0: the BUCK file sits next to package.json
    node = "//tools/node:node",                    # optional: a node_dist of this cell (facebook/buck2#683)
    step_data = {"test": {"spec": "//:spec"}},     # files from elsewhere in the cell, at their cell-root paths
    step_tools = {"test": {"bzip2": "buildrules//rules/pins:busybox"}},   # commands a script may run
)
```

Other `npm_package` arguments: `srcs` (default: every file of the package except `node_modules/`, the dist
directory, `build/`, `coverage/`, `BUCK`, the generated files and `package-lock.json`), `exclude`, `data`,
`step_env`, `visibility`. package.json is never an input as written: the steps read a copy without the
`"buildrules"` key (`:package.json.steps`), so a policy edit does not re-run them.

### Files

| file | written by | content |
|---|---|---|
| `buildrules.lock.bzl` | `npm sync` | `SCHEMA = 1`, `NODE` (the pinned node it was made for), `PACKAGE_JSON_SHA256`, `PACKAGE_LOCK_SHA256`, `PACKAGE` (`name`, `version`, `scripts`, `buildrules` policy), `NPM` (one row per locked tarball) |
| `buildrules.bzl` | `npm sync` | the two-line binding of the table to `@buildrules//rules/node:npm.bzl`; `check` fails when it differs |
| `BUCK` | `npm sync`, once | `npm_package(path = ".")`; afterwards yours |

An `NPM` row is `key = "name@version"` with `name`, `version`, `url`, `sri512` (the lockfile's
`integrity`, sha512 only), `sha256` and `size` (what Buck2 keys the download on; learned once by
downloading the tarball, whose sha512 must equal the lockfile's), and `os`, `cpu`, `libc` when the
lockfile has them. Starlark cannot read JSON, which is why the table exists. `--seed FILE` reuses the
sha256 and size of a table or a kpin lock for the same integrity (no download).

### Policy: the `"buildrules"` key of package.json (npm ignores it)

```json
"buildrules": {
  "steps":   { "typecheck": "tsc-check" },
  "actions": { "ci": ["typecheck", "test", "build"] },
  "dist":    "dist"
}
```

`steps` renames the script a step runs (default: the script of the step's own name; `pre<script>` and
`post<script>` run around it, as under `npm run`); `actions` are named chains of steps; `dist` is the
directory the build script writes. Any other key is refused by `sync` and `check` (`default-action` is
reserved), as are an unknown step, a script that does not exist and an action named like a step or a
target.

### Targets

| target | is |
|---|---|
| `:node_modules` | the tree `npm ci --ignore-scripts` makes: one cached action per locked tarball (`:modules.npm-<name>_at_<version>`: download, sha512 check against the lockfile, unpack as npm does, name and version checked), then one assembly that copies each package to every path the lockfile gives it and links `.bin`. Packages whose `os`, `cpu` or `libc` exclude linux x64 glibc are not declared |
| `:typecheck :lint :test :build` | the package's script of that name, run by the pinned node in a copy of the package with `node_modules` linked in; a pass marker, or for `:build` the `dist` directory. A step the package has no script for fails when built by name with the reason, and is skipped by a wildcard |
| `:dist` | the `dist` directory, the output of `:build` (absent without the policy key) |
| `:check` | the table against package.json and package-lock.json; a validation of every step, so no step builds from a stale table |
| `:<action>` | one per `actions` entry |

No install script runs and nothing is fetched at build time. The environment of a step is a scratch
`HOME`, UTC and a `PATH` of node and `step_tools`. A script is read without a shell: commands joined by
`&&`, quotes, a backslash and leading `NAME=value` are understood; a pipe, redirection, `;`, `||`, `$`,
glob, `npm` or `npx` is refused with the fix (quote the argument, call the tool directly). The refusal
is raised when the step is built, not by `sync` (v0).

### What `npm check` and `:check` refuse

The sha256 of package.json or package-lock.json differs from the table; a locked tarball is not in the
table, or the table holds one the lockfile no longer has, or the integrity differs; `buildrules.bzl` differs
from what `sync` writes; the BUCK file has no `npm_package` call. `npm sync` additionally refuses: a lockfile
that is not version 3; a locked package without `resolved` (a git or file dependency) or `integrity`; an
integrity that is not sha512; a version already in the table whose integrity changed (unless
`--accept-changed`); tarball bytes whose sha512 is not the lockfile's (nothing is pinned); `workspaces` in
package.json.

### Limits (v0)

Linux x86_64 and glibc only; one package.json per `npm_package` (no workspaces); registry tarballs over
https only; scripts must fit the shell-free subset; the policy has one `dist` directory; a script step is
one action (a script of three `tsc` runs is one cache entry); the optional-dependency platform filter is
the lockfile's `os`/`cpu`/`libc` and nothing finer.

## 14. Where actions run: remote, or local on request **[chosen]**

`[buildrules_re] mode` (`-c buildrules_re.mode=...` or the root cell's `.buckconfig.local`) picks the executor of the execution platforms (`rules/platforms.bzl`).

| mode | meaning | refused when |
|---|---|---|
| `remote` (default, also when unset) | every action runs on the farm named by `[buck2_re_client]`; worker properties come from `[buildrules_re] linux_x86_64_properties` | the property set is missing (the platform fails to load, with a message naming the file to copy and the opt-in below) |
| `local` | every action runs on the machine running buck2: CI runners, people without a farm | `[buck2_re_client] engine_address` or `cas_address`, or `linux_x86_64_properties`, is also set (a machine that has a farm does not run locally); the value is neither `remote` nor `local` |

Local mode is hermetic in what it runs, not in where: the tools of every action are the pinned toolchains' (busybox, zig, rustc, cargo, the Node distribution, ...), downloaded by buck2
and checked against their sha256, with the same command lines and inputs as on a farm. The machine supplies buck2, its kernel and its CPU. The ISA platforms are registered too and run on the machine's CPU:
`x86-64-v3` tests need a CPU with AVX2, BMI1/BMI2, FMA and MOVBE (the CI workflow checks `/proc/cpuinfo` first). Action cache keys do not depend on the mode.

The public CI (`.github/workflows/ci.yml`) builds `//ci:all` this way on `ubuntu-latest`. `//ci:all` is every target of the tree except the ones `ci/all.bzl` lists with a reason each: the refusal fixtures
(`probe_env`, `probe_tree`, `probe_usr`, `cnative:coverage`, which are red by design) and `ci/negative` (a planted defect that a wildcard build skips). Before it builds, the workflow runs
`buck2 bxl //ci:completeness.bxl:check`, which fails and names every target of `//...` and `crates//...` that is in the closure of neither `//ci:all` nor `//ci:mojo` and is not excluded, so a new target cannot go unbuilt.
`//ci:mojo` is not built there: its packages need the pinned mopm tarball, a stand-in that is published nowhere yet (section 12.5), and a package channel for `cnative`; both are fetched
through `buildrules.url_map` from a mirror a public runner does not have. `//ci:mojo` is built on a farm that has the mirror.
