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
[http]             connect_timeout_ms = 30000   read_timeout_ms = 120000   (buck2 defaults to 5 s to connect; a pinned download is retried by buck2 3 times, then fails)
[project]          ignore = buck-out, .git
```

`--git` takes an https URL, or `file:///absolute/path` for a local clone (for example in tests); `--commit`
must be a full 40-hex SHA (a branch or tag is not a pin). `--path` must be inside the repository and
normalized (Buck2 refuses `..`). An existing `.buckconfig` is never merged: `init` exits 1 and prints the
config it needs. The remote-execution endpoint and worker properties are **not** here: they live in
`.buckconfig.local` (gitignored, `[buck2_re_client]` and `[buildrules_re] linux_x86_64_properties`), and
the execution platform runs nothing locally unless `-c buildrules_re.mode=local` asks for it (section 14). `init` also adds `.buckconfig.local` and `buck-out/` to
`.gitignore`.

## 8. Commands, files touched, exit codes

Exit codes of every command **[chosen]**: `0` ok; `1` failed, stale or refused (every problem is printed,
with the fix); `2` usage error.

The runners that run a welded test in a build action (`check marker`, `gate mojo`) end with the test's own status, and add one: `125`, a test stopped by its hang
limit (section 12.8). It is not `124`, which is a killed compiler deadlock that is retried once (the compile watchdog), so a hang is never retried; no test of these rules exits with `125` by itself.

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

`ci/negative` holds known defects that must stay RED; it is compatible only with the platform it breaks on, so `//ci:matrix`
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
| `:lib` | the package's `.mojoc`, the copy of `:lib_ungated` that exists only once every test run has passed (the gate, below) |
| `:lib_ungated` | the `.mojoc` as compiled (`mopm unit build`, mode `lib`); the package's own tests import it |
| `:<stem>__bin`, `:<stem>` | one test file: the compile (agnostic platform) and the run (the target's ISA platform) |
| `:test` | every test run |
| `:bin_<name>`, `:build` | the `[targets] bins` of `mopm.toml`; `:build` is the library and the binaries |
| `:<stem>__cov_bin`, `:<stem>__cov` | the same test as a debug build, and its run under kcov: a Cobertura report in repository paths |
| `:<stem>__bc`, `__pgo`, `__profdata`, `__ir`, `__info` | the same test as LLVM bitcode, instrumented and linked, run for its profile (in the working directory and with the `test_data` and `test_env` its other runs have, 12.9), the profile applied to the bitcode, and the library's branches in that IR classified: the branch records (12.4). A test that links native libraries has them too: its instrumented link is given the same libraries in the same order |
| `:coverage` | the package's line and branch coverage from those reports and records (`coverage.txt`); red if a source of the library is in no report. `:coverage[reports]` is the reports themselves, the per-line records (the tests' and one for the code no test compiled), and `:coverage[branches]` the branch records (12.4) |
| `:coverage_floor` | only if `coverage_floor.txt` is beside the BUCK file: green while `coverage.txt` is at least that floor (12.4) |
| `:ci` | `:build` and `:test` |
| `:table` | the committed graph is what the pinned mopm's `plan --unit-graph --locked` prints for the package and its path dependencies now, byte for byte, the dependencies held by identity only (an action; not part of `:ci`, but of `//ci:all` for every example). `:workspace` is the files it reads: the package's and its dependencies', flat, each at its path from the repository root |
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

The two `toolchains/` files are in the directory of the `toolchains` cell: `[cells] toolchains = DIR` in the root `.buckconfig`, read by `mojo sync`,
`mojo check` and `buildrules check` alike, and `toolchains/` when there is no such line. The cell is the one place the path is configured, so the tables
cannot land where the cell does not look. `DIR` is relative to the root and must be an existing directory inside it, symbolic links followed, and not inside a
Mojo package's directory (compared by real path; a package whose real path cannot be resolved is refused too); anything else is refused (exit 1, nothing written). The default is not checked, so a repository that has
no such line behaves as before. Four rules, each the reading of Buck's own configuration that the committed tables need:
- A toolchains directory inside a package at the repository root is accepted: every directory is inside such a package, and refusing it would refuse the
  default. Only a package in a subdirectory holds its toolchains directory out.
- A root `.buckconfig` with an include line (`<file:...>`, `<?file:...>`) is refused: includes are not followed, so a cell path they hold would be missed.
- `.buckconfig.local` may not set the toolchains cell (under `[cells]` or `[repositories]`): buck2 honours it, but the pins are committed and so must their
  location be. Exit 1; declare the cell in the committed `.buckconfig`.
- `[repositories]` is Buck's older name for `[cells]`, and is read only when no `[cells]` section exists at all, in `.buckconfig` or `.buckconfig.local`
  (whatever that section holds, as buck2 does: with `[cells] root = .` and `[repositories] toolchains = x` there is no toolchains cell). A header may be followed
  by a `#` comment (`[cells] # x`); buck2 rejects a `;` there, so that is not a section header.

`--toolchains DIR` on `mojo sync` and `mojo check` is an assertion only: it must name that same directory, else exit 1 with both paths. `rust_pins.bzl` is
not covered by this.

`mopm-toolchain.toml` is found by walking up from the package directory to the nearest one, as rustup finds `rust-toolchain.toml`:

```toml
[toolchain]
mopm = "0.0.48"     # an exact release: a version of rules/mopm/pins.bzl, or one buildrules-pins.toml gives a URL, sha256 and size for
mojo = "1.0.0"     # an exact release mopm pins a toolchain for; the graph is made for it
```

**It is required**, like `rust-toolchain.toml`, and there is no implicit default: without it `mojo sync`, `mojo check` and the analysis of every
package stop, name `mopm-toolchain.toml`, and print a minimal example (`[toolchain]`, `mopm = "0.0.48"`, `mojo = "1.0.0"`). Required was chosen because
the Rust side is, and one rule is easier to teach; the other choice, a default in `sync`, would pick a compiler for a repository that never named one.

### 12.3 The table: `buildrules.mojo.lock.bzl`, schema 1

```python
SCHEMA = 1
MOPM = {"version": "0.0.40", "origin": "builtin", "workspace_root": True}   # origin: "builtin" or "buildrules-pins.toml"; workspace_root only when true, spelled True (Starlark)
MOJO = "1.0.0"
CLOSURE_SHA256 = "<mopm's hash of the toolchain closure>"  # a second copy of the graph's, see 12.6
MANIFEST_SHA256 = {"mopm.toml": "<sha256>", "mopm.lock": "...", "../../mopm-toolchain.toml": "...", "../util/mopm.toml": "..."}
GRAPH_JSON = r'''<`mopm plan --unit-graph --locked --mojo M`, path dependencies by identity only>'''
GRAPH = json.decode(GRAPH_JSON)
```

The graph is mopm's text, so reviewing the diff of the table is reviewing mopm's output, with one exception: a **path dependency** (a library of another
package that mopm read from a directory) is committed by identity (id, version, root, its own dependencies and outputs), without its `srcs` and without
`key`, and the `key` of every unit that imports one is left out as well (mopm's key hashes the keys below a unit). A dependency's sources are proved by the
dependency's own table (`mojo check`, `:check` and `:table` of its package), so editing a leaf does not turn the table of every package above it red until each
is synced again. `rules/mojo/tools/graph_norm.zig` makes this form; `sync` writes it and `:table` compares mopm's output, put into it by the same function, with
the committed text. A graph without a path dependency is mopm's text as it is. `MANIFEST_SHA256` lists every file the graph was made
from that the graph does not hash itself: the package's `mopm.toml` and `mopm.lock`, the toolchain file (path relative to the package) and the
`mopm.toml` of every path dependency (a version or a dependency of it changes the graph). The package's own sources and their sha256 are in the graph.

**Where the graph's paths start.** A mopm that has `plan --unit-graph --workspace-root DIR` (`sync` asks the pinned mopm binary: `mopm --help` lists `--workspace-root` when it has it, once per binary; no release number is compared, and a mopm whose help cannot be read is an error) is given
the repository root, the directory of the root `.buckconfig`: every path of the graph (roots, sources, dependency roots) is then relative to it, and the package
may import path dependencies that are its siblings (`../util` in `mopm.toml`), not only ones below it. `sync` records that it asked (`"workspace_root": True`, Starlark's spelling: a lowercase
`true` is not a name Buck2 knows and the table would not load, so `check` refuses it; `check` is offline and never runs mopm, so it trusts the record), and the rules read the record, never the version. An older mopm prints paths
relative to the package and takes path dependencies below it only (the release pinned in rules/mopm/pins.bzl is one of them until it moves to a release that has the flag; a mopm without it that fails on a sibling says "this mopm does not support --workspace-root (needs a release containing it); pin one in mopm-toolchain.toml"); a table made by one is as it was. Either way a path dependency is the target
`//<its directory>:lib`, the directory taken from the repository path of its root, and one outside the repository root is refused. The directory is the one above `src/<name>` when the root is `<dir>/src/<name>`; for a library the member's own `mopm.toml` puts elsewhere (`[targets] lib = { path = "generated/<name>" }`, a package whose sources are committed generator output) it is the nearest directory above the root that holds a `mopm.toml`, which `sync` records in `MANIFEST_SHA256` like any member's (`mopm.toml` is how mopm itself finds a package's directory), and the analysis reads back as the longest recorded manifest directory that holds the root. A root below no such directory, and one in the importing package's own directory, are refused. The package's own library may be anywhere below its directory: the rules take its sources, the name of its module and its tests from the graph, not from the path; `mojo_package` does not run a generator's freshness check, a consumer keeps its generator and freshness-gate targets beside the `mojo_package` (a `<n>_gen` generator and a `<n>_fresh` gate, say). The package's own files that the graph names are read below its directory whichever base the graph prints: the Mojo sources, the test sources (the keys of `test_data` are the test's path below the package, `tests/test_x.mojo`, in both) and the sources and headers of its native libraries; a native unit's `includes` are directories below the package in both
(`sync`, `check`, and the analysis of the package), as is one whose directory is the importing package's own (its library would be the package's `:lib`, which
waits for the tests that import it: a path dependency is a package of its own). The analysis also requires each library a unit imports to have been built as
the graph says (the unit id, version and Mojo included), and refuses a dependency target that says nothing about a package of the unit's closure.

`toolchains/mojo_pins.bzl` is the `toolchain` object of the graphs, copied (two packages' graphs for one Mojo version must agree):
`subdir`, `cc_target`, `closure_sha256`, `zig` (version, url, sha256, size) and `components` (`mojo-compiler`, `libgcc`, `libstdcxx`, each with url, sha256,
size). **buildrules has no Mojo pin of its own**: `toolchains//:mojo_<v>` fetches those packages by sha256 and the zig that links, unpacks them
(`conda_unpack`; busybox for the zig) and names the closure hash. A new Mojo version is a mopm release plus a `sync`.

**One graph per subdir.** A mopm that takes `plan --unit-graph --subdir <s>` (linux-64 is its default; `linux-aarch64` and `osx-arm64` are the others) prints a graph
per conda subdir: the same units, sources and dependencies, with the toolchain (compiler, runtime packages and zig of that platform), the `.conda` of every registry package and the keys
of that subdir. `sync` asks for the graph of every other subdir whose toolchain closure the package's `mopm.lock` records (`"toolchain": {"1.0.0": {"linux-64": ..., "osx-arm64": ...}}`, which `mopm lock` writes for all three
from mopm 0.0.73 on; a lock that records linux-64 alone gets the table it always had, whatever mopm is pinned), and a subdir mopm cannot plan stops the sync. The table then holds, after `GRAPH`, one block per other subdir and the map of all of them:

```python
GRAPH_JSON_LINUX_AARCH64 = r'''<the same, for --subdir linux-aarch64>'''
GRAPH_JSON_OSX_ARM64 = r'''<the same, for --subdir osx-arm64>'''
GRAPHS = {"linux-64": GRAPH, "linux-aarch64": json.decode(GRAPH_JSON_LINUX_AARCH64), "osx-arm64": json.decode(GRAPH_JSON_OSX_ARM64)}
```

`CLOSURE_SHA256` stays the one of the linux-64 graph; `buildrules.mojo.bzl` loads and passes `GRAPHS` only for such a table (a table with `GRAPH` alone has the glue it always had).
`toolchains/mojo_pins.bzl` gets a row per subdir: the key is the Mojo version for linux-64 and `<version>@<subdir>` for the others, and `mojo_toolchains()` declares
`toolchains//:mojo_<v>_<subdir with _>` beside `mojo_<v>` (the compiler closure, the zig and the toolchain; the coverage toolchains exist for linux-64 only). `mojo_package` chooses by the
**target platform**: its constraint on the OS and the CPU selects the graph a unit is built from, in either vocabulary: this package's own constraint values (`//platforms:linux`, `macos`, `x86_64`, `aarch64`), the prelude's (`prelude//os/constraints:linux`, `macos`, `prelude//cpu/constraints:x86_64`, `arm64`), which a repository that does not know buildrules has on its platforms, or both. `//platforms` has three config settings for each pair (`is_linux_x86_64`, `is_prelude_linux_x86_64`, `is_both_linux_x86_64`, and the same for `linux_aarch64` and `macos_aarch64`); the third matches only a platform that carries both vocabularies and is the more specific, so a platform that carries both is not an ambiguous `select`, and every `select` by host lists all three (`by_os_cpu` in rules/core/platform.bzl). A platform that carries neither vocabulary (or one value of each) matches no pair: it takes the `DEFAULT`, which for a table with several graphs is the refusal below. A platform that contradicts itself, one vocabulary naming one pair and the other a different pair, matches two pairs and neither is the more specific, so buck2 refuses its `select` with an ambiguity error instead of the refusal below. The same selects choose the host that runs the actions and the linux arm64 gate, so a platform of either vocabulary is placed, equipped and gated as the same platform of the other. The configuration of the platforms of this package does not change: they carry this package's values only. The pair also selects the graph a unit is built from,
the toolchain, the `.conda` of a registry package and the subdir of `mopm pack` (`:conda` is `<subdir>/mojo-<name>-<version>-mojo<M>_0.conda` and its natives are packed for the subdir).
The coverage builds are linux-64 builds. A platform that matches none of the subdirs the table has graphs for fails the analysis of the package's `:check`, which every target waits for, naming
the graphs the table has. A table with the graph of linux-64 alone is built for linux x86_64 (at any ISA level) exactly as before, and refused on an Arm platform (linux aarch64, macOS arm64): its toolchain is x86_64 and would run on an Arm host, so `:check` fails analysis and says the package needs `buildrules mojo sync` with a mopm that records that platform. `:table` asks mopm for each subdir and compares it with its block,
`mojo check` reads each block (the Mojo version, the subdir the toolchain names), and ci/subdirs.bzl configures an example for each platform and holds what was chosen (there is no
execution platform for linux aarch64 or macOS arm64 yet, so the gate is analysis). Every compile action still declares a linux x86_64 execution platform, so the compiler chosen for
another target platform would not run on it: a real aarch64 or macOS build also needs execution-platform selection, and the analysis gate is no proof that such a build works.

### 12.4 How a unit becomes an action

`mopm unit build --unit ID --graph G --out O --toolchain T [--src S] [--deps D] [--natives N]` is the one compile entry (offline; it checks
every declared input, then executes `T/mojo_compile` with an empty environment). Each unit is one action of `rules/mojo/unit.bzl`:

- `--graph`: the unit's **slice**: the graph's header, the unit's entry without its `key`, and every unit it imports reduced to `id, package, version, kind, root, deps, outputs, mojoc`.
  mopm's `key` hashes every dependency's key, so it moves with any edit below the unit; Buck2's own key (the digests of the inputs) replaces it, and a
  dependency's sources, key and profile are not inputs of the unit that imports it. This is what makes unchanged `.mojoc` bytes stop a cascade.
- `--src`: the unit's sources at the paths the graph names (from the package, or from the repository root when the table's `workspace_root` is true); the target's `srcs` are the graph's, so a file the graph does not name is not an input.
- `--deps`: `<package>.mojoc` of every unit in the closure, flat: the outputs of the dependency targets (a member's `:lib`, a registry package's `prebuilt_<name>`),
  checked against the graph's closure at analysis: the same packages, and each built as the graph names it (the unit id, `<package>@<version>#mojo<Mojo version>/lib`, of the
  dependency target's `MojoLibInfo` is the graph's), so a sibling on another version or another Mojo is refused, naming both ids.
- `--natives`: the native libraries by soname. mopm checks each against the sha256 in the graph before it compiles anything. A static library (`lib<stem>.a`) of a registry package is
  not named in the BUCK file: it is the sub-target `:prebuilt_<package>[<soname>]` of the package's unpacked `.conda`, chosen from the graph (`kind` static, the package of the unit that ships it). Every other
  native is a target of `natives = {...}`, and one the lock provides may not be named there. mopm lists the libraries of a unit in link order (a library before every library it needs), `native_sonames` keeps
  that order, and mopm links them in it; `--natives` itself is a flat directory. A static library a workspace member builds from its own C (`[native.<id>] kind = "static"` in its `mopm.toml`) is a
  native unit of the graph (format 2; these rules read formats 1 to 3, and refuse a newer one: update buildrules), `native:<package>/<id>`, and every unit that links it (the member's library, tests and binaries, and every dependent member's) lists it in `natives` with a `built` field
  naming that unit and no `sha256`: it is a product of this build. It is not named in the BUCK file either. `mojo_package` of the member compiles the unit's `srcs` with the pinned zig into `:native_<id>_cxx`
  (a `cxx_library`, at the platform's baseline CPU whatever ISA level the rest of the program is built for, optimised, with `-I` for each of the unit's `includes`, `cflags` and then the
  flags of the OS) and writes `lib<id>.a` as `:native_<id>` (`native_archive`, rules/cxx/native.bzl); a dependent's units take the member's target. These two names are stable: a repository that lists
  libraries by target can name them. The archive is held to what a library other people link must be by `archive_check` (rules/cxx/archive, a validation of the target, so every build that holds
  the archive runs it): an archive of 64-bit ELF relocatable objects whose members have no time or owner and are in the order of their names, no `.debug_*` section and no byte of the directory it was built in
  (`hermetic.zig`), no object that needs a glibc symbol version newer than the floor (`floor.zig`), and no undefined symbol that the final link would lack: every one is defined by the archive itself, by a library it
  `needs`, by the C library at the floor or by the compiler runtime (`rules/cxx/archive/src/floor_symbols.txt`), and the first that is not is named. For a macOS arm64 target the archive is of 64-bit Mach-O relocatable objects in a BSD-style
  archive (the `__.SYMDEF` table is not a member), held to the same rules but the glibc floor: the debug rule reads a `__DWARF` section or a debug-map symbol, and the C library is libSystem, `rules/cxx/archive/src/floor_symbols_macos.txt`, looked up by the C name (the symbol's leading underscore removed);
  an archive that mixes the two formats is refused. The macOS list is written from the C library's documented interface and is not generated from an SDK: a libSystem function it lacks is named in the `allow` of the library, and a name it holds that libSystem lacks is found when the link fails. A package that builds natives also gets `:conda`, the package
  as `mopm pack` writes it with each archive packed as `lib/lib<id>.a`, which a consumer's lock pins by sha256 (`mojo_conda_holds` unpacks it and requires each archive to be the bytes of the target). A graph in which
  a `built` entry names a unit the graph does not have is refused by `buildrules mojo sync` and by `mojo_package`. Every library target (`:lib`, `:lib_ungated`) carries `MojoNativeArchiveInfo`, the unit's natives in
  link order and the file of each, so a label that adopts the package hands the archives to a dependent that still links through other rules. (The `cnative` example's shared library is a `natives = {...}` entry.)
  `mojo_package(conda = True)` gives a package `:conda` without natives. A package whose dependencies are workspace members is packed with each member staged at its repository path in one workspace
  directory (the package at `<dir>/mopm.toml`, a member at `<dir>/<path>/mopm.toml` with the path normalized, so a sibling `../b` is `<dir>/../b` made `<parent>/b`), because `mopm pack` reads the manifest of each
  path dependency beside the `--manifest` it is given (it takes no `--workspace-root`); a member that leaves the repository, or lands on a file already staged, is refused. Each such dependency must name a `version`
  beside its `path`: the `.conda` holds the package alone and records the member as `mojo-<name> <range>`, never a path. `mojo_conda_holds(sole = True, depends = [...])` requires exactly that of the built file:
  nothing under `lib/mojo/` but the package's own `.mojoc` and `.mopm.json`, and, after the compiler, exactly the listed dependencies in order.
- `--toolchain`: a directory assembled from `mojo_launch` (as `mojo_compile`), the wrapper (`wrapper`), the compiler closure (`compiler`), the zig (`zig`), `CLOSURE_SHA256`
  and `toolchain.cfg`. `mojo_launch` puts the wrapper's options (where the closure and the zig are) in front of mopm's arguments, inserts the ISA flags after `build`,
  and rewrites mopm's `--source-root` for `precompile` (below). It runs no compiler and owns no policy.

A registry dependency is a `pinned_file` (URL, sha256, size of the `.conda` the graph names for this Mojo version) unpacked by `prebuilt_unpack`, never compiled. The same program takes the package's static native libraries out of the same file, `lib/<soname>` for each `--native <soname>=<sha256>` that the
rule passes from the graph (the lock's value): the member is hashed first, and a hash that differs, a member that is missing, doubled, empty, a link or too large, or a soname that is not `lib<stem>.a`
is refused, with no output written. What is pinned: the `.conda` as a whole (its sha256 and size, checked at the download) guards the `.mojoc`, which is not hashed again; each native library is also hashed against the lock's value for it. A `.conda` with two `pkg-*.tar.zst` is refused; the size bound (512 MiB) is on each member, as its tar header declares it.
`-c buildrules.url_map="<from>=<to> ..."` in the `.buckconfig.local` of the cell that declares the download (the toolchain downloads are in the `toolchains` cell, whose
`.buckconfig.local` is its own) changes where a download is fetched from and nothing else: the sha256 is still checked.

**Tests and ISA.** `<stem>__bin` is `mopm unit build` of the test unit on the agnostic platform (the ISA flags `--target-cpu x86-64-vN` are in `toolchain.cfg`, so a v3 and a v1
build are two keys); `<stem>` runs the binary with the compiler's `lib/` on `LD_LIBRARY_PATH` (the binary needs `libKGENCompilerRTShared.so`) and the platform's
`exec_compatible_with`, and checks at analysis that its platform has the level (as section 11). A `.mojoc` carries no ISA flag: libraries are shared by every level.
It is also a `buck2 test` target (`ExternalRunnerTestInfo`).

**Coverage** on mopm's units: the test unit's profile in the slice is replaced by `{opt: 0, assert: all, debug: true}` (mopm passes `-g`), the link goes
through `cov_zig` (it keeps the debug information and rewrites the action's directories out of it), kcov v42 built from source with the pinned zig (`rules/coverage`
`kcov_build`, `cov_zig`, `debug_relocate`, `cov_normalize`) runs the binary in a tree of copies of the test source and the library's sources at the relative names the line
tables use, and `cov_normalize` maps the report to repository paths. `cov_run` refuses a binary that names the library's sources by the directory they were staged in. `covcheck`'s policy and the census are not ported.

**Branch coverage** of the same tests (`rules/coverage/branch/README.md`): kcov writes no branch data for a Mojo executable, so each test is also built as LLVM bitcode (the unit's profile `{opt: 0, assert: all, debug: false}` and the
build arguments `--emit llvm-bitcode --debug-level line-tables`, so `<stem>__bc` is the very `mopm unit build` of the test with those flags), instrumented with IR profile counters by Mojo's own lld (LLVM 24: the only
LLVM that reads and writes the compiler's bitcode, unpacked from the pinned compiler package) and linked as a release test is, with the LLVM 23 profile runtime (`<stem>__pgo`); run in the tree of its sources, the raw
profiles merged by the pinned `llvm-profdata` (`<stem>__profdata`; the raw profile version is `RAW_PROFILE_VERSION`, checked against both LLVMs by a check of each Mojo toolchain); read back by lld with the profile
applied, as IR text whose branches carry their counts (`<stem>__ir`); and the branches of the library's sources in that IR classified, each a source decision or a branch the compiler made, as lcov `BRDA` records in
repository paths (`<stem>__info`). The tools are static Zig executables (`cov_branch link|run|annotate`, `cov_branch_classify`), each behind its tests. A test whose unit links native libraries is instrumented too: `<stem>__pgo` is given the unit's `native_sonames` (the graph's
order: a library before every library it needs) and their targets, the very wiring of `<stem>__bin`, and links them after the instrumented object by path, as the ordinary link does; a shared one is
found at run time through `<stem>__pgo[libs]` (`cov_branch run --lib-dir`). A library the unit links that the target is not given, one it is given that the unit does not link, and a graph order in which an
archive stands after one that needs it are refused when the target is analysed; a library that defines a symbol the instrumented object defines too fails the link (README of `rules/coverage/branch`).

**What no test compiled.** Mojo compiles only the functions a test reaches, so a function no test calls has no line in kcov's report and no branch in the IR, and a count made from those alone would
lose that function's lines and branches from its denominator the moment its last test was deleted, and read higher for it. `:coverage` reads the library's sources as well (`rules/coverage/tools/mojo_src.zig`,
the rules of covcheck, the full-source checker this replaced: its lexer's executable lines and its declaration reader's functions): every function of a source whose own lines have no record, in a line report or a branch record file, is
**uncompiled**, and its own executable lines count as found and not hit, as do two arms for each decision word on them (`if`, `elif`, `while`, `for`, `and`, `or`; an `and`/`or` that an `if`, `elif` or `while` tests has
two more for its right operand, as the compiler's records give; a line that starts with `comptime` or `alias`, or follows `@parameter`, decides nothing at run time). A function with a record on any one of its own
lines is the compiler's alone, so its lines are the compiler's. The source is a heuristic where the compiler's records are exact: the compiler gives a function fewer lines than the source has (a `return` folded into a select has none), so deleting a test can raise the line denominator, and lowers it only if the compiler recorded a line the lexer does not count as code (none seen); and the
compiler's raising calls and subscripts are branches the source has no word for, so the source's count of a function's arms can be below the compiler's. A source whose first line starts with `# @generated` (then the end of the line, a space or a tab)
is machine-written: no report of it is asked for and nothing of it is counted (a report that names it lists the row `(not counted)`).

Two things look like an uncompiled function and are not uncovered code: a function the compiler **inlined** into every caller (it has no record of its own, and a test calls it), and a function whose code, or
whose every use, is in a `comptime if` arm **dropped for this target** (an AVX-512 path on a machine without AVX-512). Only evidence that a test reached the function tells them from a function nobody calls, and
a line is left out of the figures only with it (the rules of the full-source checker's uncompiled report, `rules/coverage/tools/mojo_calls.zig` and `mojo_gate.zig`, each cited there to its source):

1. **Call evidence.** An `@always_inline` function's own lines, or the lines inside the `comptime if` / `elif` / `else` and `@parameter` arms of a function, are left out only when a line **outside** the function that
   calls it was **hit** in a test's report. A call is an identifier followed by `(` or `[` in the code of the line (a comment, a string and a declaration are no call): `f(` for a free function, `x.f(` or `T(x).f(` for
   a method. A method is reached only by a call that names its type (`T.f(`, `T(x).f(`); a free function by a call in its own file or in a file that imports its name or its module; a name the package declares more than once, by
   none. The calls are those of the package's own library and tests (`cov_summary --src` of a test path, never counted). An inlined function nobody calls is counted, and so is one whose only caller was not hit.
2. **Per arm, not per function.** The lines outside the arms of a function with compile-time arms are counted; only the arm lines (the gate line included) go. A nested closure is a function of its own: its class and its
   arms are its own, and neither reclassifies the function around it.
3. **Platform-gated functions.** A function with at least one use all of whose uses are *dropped* is not counted, all its lines, and is listed. A use is any occurrence of its name as an identifier in the package's sources (a
   call, a value, `mod.f`, an alias's name; not a comment, string, import line or its own declaration), a function declared more than once is never gated, and a use inside the function itself does not count. A use is dropped
   when it is inside a compile-time arm, of a function with a record, and **no line of that arm** has one (the gate line is not in the arm: its condition runs whichever arm is compiled), or inside another gated function
   (computed to a fixpoint). Any other use is live. A function with no use counts; functions that only call each other from a dropped arm count (the fixpoint starts from nothing gated).
4. **The report says what it left out.** `:coverage[excluded_uncompiled]` is `uncompiled.excluded.txt`: `excluded <path> <lines> lines <arms> arms` for each source that lost lines or arms to call evidence, `excluded total
   <lines> lines <arms> arms`, `gated <path> <function> <def line> <lines> lines` for each gated function, and `gated total <n> functions <lines> lines <arms> arms`. The lines and arms it lists are in neither `coverage.txt` nor
   `uncompiled.cobertura.xml` / `uncompiled.branches.info`; only the evidence moves a line out, and none of it moves a figure down.

**What `:coverage` gives a consumer.** Three outputs of one target, built from the same reports and records:

- `:coverage` (its default output, `coverage.txt`): one row per file, `<path> <hit>/<total> <n>%`, the rows of a test's own sources marked `(not counted)`, then `total <hit>/<total> <n>%`
  over the library's sources. A library source with no executable line (a re-export `__init__.mojo`) is listed `0/0`. Then the branch rows, the same listing with `branches ` in front of each row, over
  the arms of the library's source decisions (`if`, `elif`, `while`, `and`/`or`, a `for` head, a raising call in a `try:` body): an arm counts as hit when any test took it. A source with code and no
  decision, or with no code, is `0/0`; a package whose tests link native libraries has them like any other.
- `:coverage[reports]`: the records the rows were counted from, one file per test (`<stem>__cov.cobertura.xml`), kcov's Cobertura XML after `cov_normalize`: `<?xml?>`, `<coverage timestamp="0">`,
  one `<package name="">`, one `<class name="P" filename="P">` per file that has a record, bytewise sorted, and in it one `<line number="N" hits="H"/>` per line the compiler emitted code for, sorted by
  number, `H` being 1 when the test ran the line and 0 when not. `P` is the repository path (relative to the root of the cell that holds the package; never absolute, never under `buck-out`). A line
  kcov gave branch data keeps it, `branch="true" condition-coverage="NN% (k/n)"`. A file with no executable line has no class, so it is the `0/0` row of `coverage.txt` and absent from the
  records, the same fact twice. This is the shape `covcheck` reads with `--cobertura` (one file per test binary; a path in several files is merged by summing). One file more than the tests': `uncompiled.cobertura.xml`,
  the same shape, with a `<line number="N" hits="0"/>` for each line of the functions no test compiled (above), so the reports together hold the lines `coverage.txt` counted. `:coverage[reports_of_tests]` is the
  tests' files alone, `:coverage[reports_uncompiled]` the one file.
- `:coverage[branches]`: the branch records the `branches` rows were counted from, one lcov file per test (`<stem>__info.info`): per library source the IR holds code of, `SF:<repository path>`, then
  `BRDA:<line>,<col>:<kind>:<n>/<N>,<arm>,<count>` per arm of each decision, then `end_of_record`. `<kind>` is `br`, `select`, `switch`, `try` or `rhs`; `<n>/<N>` is which decision of that kind, of how many, at that line
  and column in one copy of the code (Mojo gives an `if` and its `elif`s one location); the arms are numbered from 0 in LLVM's weight order (true first; a `try` decision's are returned and raised); `-` is a decision
  that never ran, an arm counted and not taken, never written as 0. A source with code and no decision is `SF:` and `end_of_record` alone; a test that ran none of the library writes an empty file. This is the
  shape `covcheck` reads with `--branch-lcov` (the block field is not a number, so upstream lcov tools cannot read it). Present only when the tests are instrumented. One file more than the tests': `uncompiled.branches.info`,
  the same shape, `BRDA:<line>,<col>:br:0/1,<arm>,-` (kind `rhs` for a right operand) for the arms of the decision words of the functions no test compiled. `:coverage[branches_of_tests]` is the tests' files alone,
  `:coverage[branches_uncompiled]` the one file.

`:coverage[excluded_uncompiled]` is a fourth file, for a reader rather than a consumer: `uncompiled.excluded.txt`, what the call evidence and the platform gate left out of the figures (above).

A consumer selects them by sub-target, and the build report (or `--show-full-output`) names one path per test:

```
buck2 build //pkg:coverage                       # coverage.txt
buck2 build //pkg:coverage[reports] --show-full-output
buck2 build //pkg:coverage[branches] --show-full-output
```

*Branch records.* kcov writes no `branch` attribute for a Mojo executable, so `:coverage[reports]` holds no branch data (`examples/mojo/coverage_records_test.zig` holds that, and holds the `branches` rows of `coverage.txt`
to the records of `:coverage[branches_of_tests]` file by file; `examples/mojo/uncompiled_test.zig` holds the uncompiled files, and that deleting a test lowers the figures). The classifier refuses what it has no evidence for, naming `file:line:col`; the shapes that stay refused are in `rules/coverage/branch/README.md`.

*Unmeasured sources.* A source of the library whose code kcov cannot record (every function `@always_inline("nodebug")`, so the compiler gives it no line table) is in no report although the tests run it, and `:coverage`
refuses a source that is in no report. A package says so explicitly: `coverage_unmeasured.txt` beside its BUCK file (and beside `coverage_floor.txt`) holds one entry per line, `<source path relative to the package>`, a TAB or two spaces,
and the reason (required); blank lines and lines starting with `#` are skipped. The file is an input of `:coverage` (and not of `:workspace`, so the table does not move with it); with no file the package is as it was. A listed source that no
report names is accepted and printed after the totals as `unmeasured: <repository path>: <reason>`, followed by `unmeasured total N files: left out of the line and branch totals and the floors`: it is counted in no total and in no floor, and it is
never listed `0/0`, so a figure never claims to have measured it. The action fails, naming the file and the path, for an entry whose source a report names ("listed as unmeasured but measured: remove the entry": the entry went stale when kcov began
to record the file), an entry that is no library source of the package (no such file, a test, another file), a path listed twice, an entry without a reason, and an entry for a source with no statement (it is listed `0/0` already). A path starting with `/` is refused. An entry is accepted only if kcov cannot record the source: every function and method it defines must be `@always_inline("nodebug")` and it must define one, and outside the bodies of those functions it may hold nothing but declarations. The rule is strict and fails closed: no `;` and no backslash outside a string or comment anywhere in the source; each statement outside a body is exactly one of an import (`import NAME(.NAME)*( as NAME)?` items, or `from NAME(.NAME)* import` such items, optionally in one pair of parentheses: plain names, a byte of 128 or more counting as part of a name), an `alias` or `comptime` constant (`NAME = expr` or `NAME: Type = expr`) whose text has no `(` (no call; `[ ]` is fine), a `struct` or `trait` header whose first colon outside brackets ends it, a field `var NAME: Type` with no initializer and no call, a decorator (`@always_inline("nodebug")` in double quotes, `@fieldwise_init`, `@value`, `@register_passable` or `@deprecated`, the last two with at most one string argument; `@parameter` is refused outside a body), a docstring (a string literal and nothing else), a `def` or `fn` whose whole body is `...` and whose signature has no `=` (no default value), or `pass`; anything else is refused, naming its line. In a nodebug function (its lines after the header, and the header after the signature) the words `fn`, `def` and `lambda` are refused (also in the signature, so a parameter of a function type such as `f: fn(Int) -> Int` is refused, and inside a format string whose literal has a `{`) unless the `def` starts a nested `@always_inline("nodebug")` function the lister also found, and so is a `def` or `fn` the lister could not name. A source indented with tabs in one place and spaces in another, and a line in a body that dedents to a level no enclosing block has, are refused. A struct with `@fieldwise_init` or `@value` is accepted by decision: the methods the compiler writes for it are assumed to have no source line for kcov to record, and that is not checked by a build. Source that merely looks like one of these (a one-line `struct S: pass`, `"x".format(f())`, `var g = f()`, a field with an initializer) is refused, so listing a source cannot hide code that runs. The first function that is not nodebug is refused ("listed as unmeasured but <name> at line N is not @always_inline(\"nodebug\"): kcov can record it; test it instead"). The line splits at the first TAB or two spaces, whichever comes first, so a TAB inside the reason stays in it. The cases are the two tables of `rules/coverage/tools/cov_unmeasured_test.zig` (`source_cases`, `joined_cases`, `reviewed_cases`) and the tests beside them. A package with the file but no library or no test fails analysis of `:coverage` naming the file. A source that is in no
report and is not listed is refused as it always was (`rules/coverage/README.md`, "Unmeasured sources"; `examples/mojo/unmeasured`).

*The floor.* A package with a `coverage_floor.txt` beside its BUCK file (the file every other package's floor is, `rules/coverage/README.md`) gets `:coverage_floor`: `lines NN.NN`, the line total of
`coverage.txt` rounded down to a hundredth, and `branches NN.NN`, the `branches total` likewise. Each figure is a minimum: lower than the floor fails with `coverage fell`, equal passes, and higher passes and prints
`you may raise the floor to NN.NN` (optional). A package whose `coverage.txt` has branch rows needs a `branches` figure ("the tests record branches ... add `branches NN.NN`"), and one without them is refused a `branches` figure
("the coverage has no branches to hold"); a package whose code has no decision (a table) has `branches total 0/0`, which is no branches figure, so its floor is `lines NN.NN` alone. With no file there is no target, and the package is as it was. `mojo_coverage_floor(name, coverage, floor)` (`rules/mojo/defs.bzl`) checks a `:coverage` against any other file.

### 12.5 Versions: pinned mopm, the Mojo version

`rules/mopm/pins.bzl` is a table like Rust's: `MOPM_VERSIONS` (url, sha256, size, unpack directory) and `MOPM_DEFAULT`. `0.0.48` is the published mopm release (its linux-x86_64 tarball;
the digest and size are the row's in `rules/mopm/pins.bzl`, the source of truth, which match the release's `SHA256SUMS`); a machine that mirrors the download points it at its copy with `url_map`.
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
| a failing test, and a target that imports the library | the gate: `:lib` is built by an action that takes every test run's marker as an input, so it, `:build`, a binary and every package that imports it fail to build; `:lib_ungated` is the way to build the library without its tests (12.8) | the same output, and the failed `mojo_gate` action's missing input |
| a prebuilt whose bytes are not the pinned ones | the download | `Invalid sha256 digest. Expected A, got B` |
| the toolchain's closure hash differs from the graph's | `mopm unit build` | `the toolchain at T is closure A, but the graph pins B` |
| the two copies of the closure hash in the table differ | analysis; `mojo check` | `the table records toolchain closure A but its unit graph pins B: the file was edited by hand` |
| the table's Mojo is not the graph's, or mopm-toolchain.toml names another | analysis; `mojo check`; `mojo sync` (mopm exit 4) | `the table says Mojo 1.1.0 but its unit graph is for Mojo 1.0.0`; `mopm has no pinned toolchain for mojo 1.1.0` |
| a native library other than the pinned one | `mopm unit build` | `native library X has sha256 B, but the graph declares A` |
| a library source no test compiled, that has any statement beyond comments, docstrings, imports, alias declarations and trait declarations (a re-export-only `__init__.mojo`, a file of `comptime NAME = ...` aliases, or a file of `trait` blocks whose methods have a body of only `pass`, `...` or a docstring, has none, is omitted by the report, and is listed `0/0`; a trait method with any other statement in its default body, and a struct or function, are code) | `:coverage` | `<file> is in no report: no test compiled it, or kcov could not open it` |
| a package's line coverage below its `coverage_floor.txt` | `:coverage_floor` | `<package>: line coverage is 60.00% (3/5), below its floor 70.00%: coverage fell` |
| a package's branch coverage below its `branches` figure | `:coverage_floor` | `<package>: branch coverage is 50.00% (1/2), below its floor 60.00%: coverage fell` |
| a floor file with no `branches` figure for a package whose tests record branches, or one with it for a package that has none to hold | `:coverage_floor` | `the tests record branches (1/2) and the floor file has no `branches` figure: add `branches 50.00``; `the floor file has a `branches` figure and the coverage has no branches to hold (the code has no decision, or the branch instrumentation was dropped)` |
| a branch in a library source that is neither a source decision nor a branch the classifier has evidence for | `<stem>__info` (so `:coverage`) | `cov_branch_classify: <file>:<line>:<col>: a br at '<token>' is neither a source decision nor a known compiler-made branch: <source line>` |
| an expected source with code and no branch record | `:coverage` | `<path> is in no branch record: its tests ran no code of it, or the classifier found none` |
| an instrumented test that fails, writes no profile or one of another raw profile version | `<stem>__profdata` | `BRANCH COVERAGE RUN FAILED: ...` (`... has raw profile version 12, not 11, the version the pinned llvm-profdata reads`) |
| a profile that is not that of the binary, or does not fit the bitcode | `<stem>__ir` | `BRANCH COVERAGE ANNOTATE FAILED: the profile ... holds no record of N of the M functions ... links` / `lld reported N diagnostic(s) applying the profile` |
| the Mojo package's lld not LLVM 24, or its raw profile version not the one `llvm-profdata` reads | `toolchains//:mojo_<v>_cov_branch` | `llvm_branch lld RED: ... does not print 'LLD 24.'` / `llvm_branch raw_version RED: raw profile version 12 not accepted by llvm-profdata 23.1.3, which expects 11` |
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
- **`mopm pack` packs a static native library** (mopm 0.0.20 and later: `[native.<id>] kind = "static"`, one archive per subdir given as `--native <id>=<subdir>:<file>`, the file written as `lib/<file name>`), and `mopm lock` pins its sha256 in the lock. A shared library is still not packed: its sha256 is in the consumer's `mopm.lock` and its bytes come from buildrules (`natives = {...}`).

### 12.8 The gate

A library that is not tested is not a library: `:lib` is the `.mojoc` behind the run of every test of its package (`mojo_gated_lib_rule`, rules/mojo/unit.bzl). `:lib_ungated` is the compile (`mopm unit build`), the package's own tests import it (they cannot import `:lib`, which waits for them), and `:lib` is a copy of its bytes made by the `mojo_gate` action, whose inputs are the compiled file and the marker each test run writes after the test exited 0. A failing test leaves no marker, so the action never runs; everything that reads `:lib` (a member's unit through `--deps`, a binary, `:build`, `:ci`, `mopm pack`) is red with it. The bytes are the compiled ones, so a dependent's key moves only when the library does and not when only a test changes. A package with no test has nothing to wait for; `:coverage` is what refuses it. The proof is a pair of fixtures that need no compiler (`ci/mojo_gate`): a library behind a failing test makes its consumer red, the same behind a passing one is green, and `ci/negative.bzl` requires both outcomes, plus the wiring: the real packages' `:lib` has every test run among its dependencies.

**The hang limit.** Every welded Mojo test action is held to a hang limit, so a test that never finishes ends the build red and says why, instead of holding a worker
until the executor's own timeout. It is infrastructure and not a timing assertion: a test never waits for a time to pass, so a test that has not finished by the limit
did not finish at all, and the limit is never evidence that a test is slow. The same contract holds in these rules and in a consumer's own Mojo rules (`gate_mojo` of
`rules/core/test_runtime.bzl`):

- **Default and override.** 1800 seconds per action. `test_hang_limit_s` is the attribute of a test run (`mojo_test_run_rule`), a positive whole number of seconds, and
  `mojo_package(test_hang_limit_s = {"<test source or *>": seconds})` sets it per test (`*` is every test, a test's own entry wins; a name that is no test of the package, or a
  value that is not a positive whole number, is refused when the package loads). Raise it for a test that is genuinely long; never lower it to make a test pass.
- **Which actions.** The ones whose marker welds `:lib`: the test run (`check marker`, `--hang-limit-s N --hang-label LABEL`) and, in a consumer's rules, the gated run
  (`gate mojo --hang-limit-s N`). The command of `buck2 test` is not welded and has the test runner's own timeout; the coverage runs (the kcov run and the branch run, which
  run the same test again) are not welded either and are not given it: they have no limit of their own in these rules, and a coverage run that hangs is ended by the executor's timeout (the welded run of the same test is stopped first, so `:lib` is red regardless). The compile of the test has its own watchdog.
- **On expiry** the whole process group of the test is killed (`SIGKILL`; a child or a grandchild the test left is in it), the status is `125`, and stderr gets exactly one line
  that starts `hang limit:`: `hang limit: <test> did not finish within <N> s and was stopped; a test never waits on time, so this means it hung (an event that never came)`. `<test>` is the label of the test
  run, as the rule prints it (`buildrules//examples/mojo/x:test_x`). The action stays red like any failing test: no marker, no `PASS` line, and the library stays unbuildable;
  a failure is never a cache hit, so the next build runs the test again. Processes of the group that survive the kill (the supervisor looks, as for a coverage run) are named on
  a line of their own that does not start with `hang limit:`.
- **With the time limit.** `gate mojo` already has a test time limit, `--deadline-s L --runner-timeout-s T` (D1-D6), which a rule puts on the command a test runner runs so the
  test is stopped before the runner's timeout is, with a `TEST TIME LIMIT` line and status 137. It stays as it is. The two are limits of different commands (a welded action has the
  hang limit; a test runner's command has the time limit), and when one `gate mojo` is given both the shorter one runs (the longer cannot fire first) and a tie is the time limit's,
  whose line also names the runner's timeout. The hang limit is not expressed through the time limit because it must not need a runner timeout, and its verdict must not say the test was
  slow. The coverage limit (`--limit-s`) is another kind of run and is refused beside it.
- **Proof.** `rules/gate` (the supervisor and `gate mojo`) and `rules/check` (`check marker`) test the verdict (status, the one line, no marker, the group and a grandchild killed) with the
  supervisor's clock replaced, never by waiting; `//rules/core/tests` holds the attribute's checks; `//ci:negative.bxl:check` holds that every real test run carries `--hang-limit-s 1800` (and the
  override of `examples/mojo/test_defines`) on the action that writes its marker, and that `//ci/faulty:mojo_test_that_hangs`, a test that blocks forever under a limit of one second, is red with the hang-limit line.

### 12.9 Test data and variables

A test that reads a golden file, a fixture, a pinned third-party file (a `.thrift` specification), library sources, or starts a program, needs those files where it runs. The
build action of a test sees only its inputs, and its working directory is the execution root, so `mojo_package` takes them as arguments and makes them inputs of the test run
and of the coverage run:

```python
mojo_package(
    path = ".",
    test_data = {
        "*": {"golden/out.txt": "golden/out.txt"},                          # every test of the package: {staged path: file or target}
        "tests/test_tool.mojo": {"bin/tool": "//tools:tool"},               # one test, named as the graph names its source; its entries are added to `*`
    },
    test_env = {"MODE": "strict"},                                          # every test of the package: {NAME: value}
    test_defines = {"TRACE": True, "LEVEL": 3},                             # compile-time defines of every test build: -D TRACE=true -D LEVEL=3
)
```

- **Where the files are.** Each test has a directory of its own, `data`, made by copying every staged file to its staged path. It is the test's working directory, so a relative path opens
  a staged file, and the variable `BUILDRULES_TEST_DATA` holds its absolute path. A test without data has neither: its working directory and environment are as before. The directory is an input, so
  treat it as read-only and write under `TMPDIR`.
- **Files and programs.** A value is a file of the package or a target (`//pkg:name`, `:name`, resolved from the BUCK file's directory); a target is staged as its default output, with the executable bit it has,
  so a program built by another target starts from the staged path. A target with more than one default output is refused by Buck2.
- **The test run and the coverage run.** `:<stem>` (and `buck2 test`, whose command is the same start without a marker) runs `check marker|run --private-scratch --env BUILDRULES_TEST_DATA=<dir> --abs BUILDRULES_TEST_DATA
  --cwd-env BUILDRULES_TEST_DATA`, then one `--env NAME=VALUE` per `test_env` entry. `:<stem>__cov` stages the same files into the tree that is kcov's working directory (`cov_run --private-scratch --data-env BUILDRULES_TEST_DATA
  --env NAME=VALUE`): that tree also holds the test's source and the library's sources under the names the line tables use, so the test sees the same files plus those.
- **Compile-time defines.** A test whose code is chosen at compile time (a flag read with `is_defined`, `get_defined_int` or `get_defined_string`) cannot get it from `test_env`, which is a run-time variable. `test_defines = {"NAME": value}`
  gives the build of every test `-D NAME=value`: a string, a bool (`true` or `false`) or an int, in the order of the names. The three builds of a test get them, so each is the program that ran: `:<stem>__bin` (the run), `:<stem>__cov_bin` (the kcov run) and `:<stem>__bc` (the
  bitcode of the branch run, whose instrumented link and run follow from it). Nothing else does: `:lib_ungated` and `:lib` are the `.mojoc` that every dependent imports and are built as mopm's graph says, a binary (`[targets] bins`) and a dependent member are built without them. The library's own `.mojoc` is compiled without them, but a `.mojoc` holds the library as IR that the importing build compiles again, so the library's code reads the test's defines: a module-level `comptime` gate
  (`comptime TRACE: Bool = is_defined["TRACE"]()`), a plain function and a generic function of the library all see them in a test build (`examples/mojo/test_defines` asserts each, measured on the pinned Mojo). mopm's unit graph (spec/unit-graph.md of mopm 0.0.48) has no defines: a unit's `profile` is `opt`, `assert` and `debug`, the build passes `-D ASSERT=<assert>`, and the `key` hashes the unit as printed, so the defines are not in the graph, in
  the committed table or in `:table`. They are arguments of the unit action, as the ISA flags are (`build_arg=` lines of its toolchain file, put right after `build`), and the action's key moves with them: a changed define builds and runs the test again, an unchanged one is a cache hit.
- **Scratch the runner owns.** Every test run and every coverage run, in either layout, gets `TMPDIR`, `TEST_TMPDIR` and `HOME` of its own: absolute paths of directories that exist, are empty when the test starts, and are
  writable. `TMPDIR` and `TEST_TMPDIR` are the same directory, `HOME` another. They are made fresh for each run (the directory is `buildrules_test.<random>`, in `BUCK_SCRATCH_PATH`, else `TMPDIR`, else `/tmp`, with no
  link in its path), so two tests never share them, and the whole directory is removed when the run ends. The three names are the runner's: `test_env` refuses them, and nothing a build or an earlier run left in the process's
  own environment reaches the test under them. `BUCK_SCRATCH_PATH`, which Buck2 sets for a build action (not for `buck2 test`), is left as it is and is **relative** to the action's directory, not to the test's working
  directory: a test must not use it, `TMPDIR` is the absolute path to write under.
- **The installed layout.** `test_layout = "installed"` (the default is `"default"`, the layout above, unchanged) runs each test the way a program installed on a machine runs: from a fresh root made for that run, in the
  private scratch directory (`<scratch>/root`, an absolute path with no link in it):

  ```
  <root>/bin/<exe>      the test binary, a copy of it (so /proc/self/exe, and argv[0], is this path); the directory that held the binary is copied to <root>/bin, so its lib/ is there for its runpath
  <root>/share/...      the test_data, each key relative to share/ ({"golden/out.txt": ...} is <root>/share/golden/out.txt); the directory exists, empty, for a test without data
  working directory     <root>; BUILDRULES_TEST_DATA, when the test has data, is <root>/share
  ```

  `check marker|run --private-scratch --installed --install-share <data dir> --share-env BUILDRULES_TEST_DATA` does it for the test run. The coverage run uses the same layout (`cov_run --private-scratch --installed --data <data dir>
  --data-env BUILDRULES_TEST_DATA`): kcov wraps the copy at `<root>/bin/<exe>` with `<root>` as its working directory, and the root also holds the test's source and the library's sources under the names the line tables
  use, beside `bin/` and `share/`; a source whose first directory is `bin` or `share` is refused. In this layout a staged path may be any path (the data is under `share/`, apart from the sources). A value other than
  `"default"` and `"installed"` is refused when the package loads. The branch coverage run (`cov_branch run --installed --data <data dir> --data-env BUILDRULES_TEST_DATA`) lays out the same tree for the
  instrumented binary, so a package in this layout has branch records and a `branches` floor like any other.
- **The action key.** The staged files are inputs of both actions by their digests, and the variables are arguments, so a change to a staged file, to which file a path names, or to a variable runs the test again, and a
  test that depends on the new content can turn red; a change that touches none of them is a cache hit. On the farm a file that is not an input is not there at all, so a test cannot read what it did not declare.
- **Refused at load** (rules/mojo/test_data.bzl, each an analysis test in rules/mojo/tests): a key that is no test of the package (a mistyped path stages nothing); a staged path that is empty, absolute, ends in `/`, or holds `.`, `..` or an empty
  segment (it would leave the directory); a staged path that is also the directory of another, or that is staged twice for one test (by `*` and by the test); a staged path that is, or is inside, a path the coverage tree holds (the test's
  source, a library source) or holds one; a staged value that is not a string; a variable name that is not a shell name or that the runner sets (`PATH`, `LD_LIBRARY_PATH`, `LD_PRELOAD`, `DYLD_*`, `TMPDIR`, `TEST_TMPDIR`, `HOME`, `PWD`,
  `BUILDRULES_TEST_DATA`, `BUILDRULES_UNIT_NONCE`, `BUCK_SCRATCH_PATH`); a `test_env` value that is not a string; a `test_defines` that is not a dict, a name that is not an identifier or is `ASSERT` (the profile's), and a value that is not a string, a bool or an int, or
  is empty or holds a space, a control character or a non-ASCII character (a value is one line of the toolchain file and one argument of the compiler); a `test_layout` that is neither `default` nor `installed`; with the installed layout, a source of the test or of the
  library in `bin/` or `share/`. `mojo_test_run_rule` and `mojo_cov_run_rule` (`data`, `test_env`, `test_layout`) repeat the checks on their own arguments.
- **Proof.** `ci/mojo_data` runs a stand-in test (a program that reads the staged file by a relative path, checks the working directory against `BUILDRULES_TEST_DATA`, checks a variable, and starts a staged program) with the
  Mojo test run rule, without a compiler: green when everything is staged, and red, for its reason, with other content, another variable value, no program, and a program without the executable bit (`ci/negative.bzl`, `FAULTY`).
  `examples/mojo/testdata` is the real thing: a package whose tests read a golden file, a third-party file, a library source and a variable, and start a program, in `:ci` and in `:coverage`.
  The same probe, told to expect the installed layout, is green in `ci/mojo_data:run_green_installed` (it finds itself at `<root>/bin/<name>`, the data at `<root>/share`, the root as its working directory) and red, for its reason, when the run
  is the default layout, when a default-layout probe is run installed, and when `share/greeting.txt` is missing or has other content; it also checks the private `TMPDIR`, `TEST_TMPDIR` and `HOME` in every run. `examples/mojo/installed` is the real
  thing for the layout: a library that finds its own files from `/proc/self/exe` (`executable_path`, `install_root`, `share_dir`) with tests that run in `test_layout = "installed"`, in `:ci` and in `:coverage`; two of its tests
  (`test_scratch_a`, `test_scratch_b`) check that their `TMPDIR`, `TEST_TMPDIR` and `HOME` are set, absolute, empty and writable. That two runs get different directories is held by the cases of `check` (rules/check/runspec_test.zig, and
  check_exe_test.zig on the built executable), which start the program twice and compare.
  `examples/mojo/test_defines` is the real thing for the defines: a bool, an int and a string define, and tests that assert each is on in the test's build, that a name nobody gave is not, that the library's code (a module-level `comptime` gate, a function, a generic function) reads the define of the test build that imports it;
  in `:ci` and in `:coverage`, so the kcov run and the branch run were built with the same defines or its tests would fail there. `//ci:negative.bxl` holds the wiring (the arguments are on the three test builds and on no library or other package's test) and `//rules/mojo/tests:test_data` the
  arguments and each refusal.

Not in `mopm.toml`: the unit graph is mopm's, and a test's data is how a build system gives a test its files, not what a package is. When mopm's graph carries a package's test files (a `[tests]` table of globs), `buildrules mojo sync` could
generate `test_data` from it; until then the declaration is the BUCK file's, and nothing in mopm changes.

### Status

The examples: `examples/mojo/ws` (`app` -> `util` -> `base`, three packages in a chain, plus the registry package `cnative` with a C library built by `rules/cxx`'s `c_shared`) and
`examples/mojo/registry/cnative` (the publisher's side: its `.mojoc`, `mopm pack`, the library); `examples/mojo/sys_app` consumes two `-sys` packages (an empty Mojo module over a static C library) whose archives
come out of their `.conda` files, with no `natives` in its BUCK file: `examples/mojo/registry/probe_sys` (which needs `base_sys`, a member below it) is the publisher's side, whose libraries are member natives (`srcs` in each `[native.<id>]`), built and packed by `mojo_package` (`:conda`).
`examples/mojo/member_native` is two members, `cshim_user` -> `cshim`: `cshim` has a C shim of its own (`[native.shim]`), its test calls it, and the test of `cshim_user` links the archive `cshim` builds, with no `natives`
in either BUCK file; `cshim:conda` packs the archive and `cshim:conda_holds` requires the `.conda` to hold the bytes of `:native_shim`; `examples/mojo/copy_of_cshim:same_bytes` builds the same C at another path and requires the
same archive bytes. `examples/mojo/member_native_macos` is those two members again at mopm 0.0.73, whose lock has a graph for `osx-arm64`: built for macOS arm64 their tests run on the macOS worker with the shim's archive in the link, and `ci/native_macos.bzl` (a part of `ci/negative.bxl`) holds from the configured targets that the shim is compiled for `aarch64-macos` on macOS arm64 and for `x86_64-linux-gnu.2.34` on linux x86_64. The proofs and their `Commands:` lines are in the commit message of the branch `mojo`.

Limits: linux x86-64 only (macOS arm64 builds Mojo units, and a member's static native library; no coverage, no other C or C++); one Mojo version (mopm pins one); the coverage is line coverage of what the compiler emitted code for (a function no test reaches emits none, so the percentage is an
upper bound); a workspace member's native library is static (a `shared` one is refused by mopm); the archive's undefined-symbol check knows the C library only by `floor_symbols.txt`, so a call to a symbol
that list lacks is refused until it is added there (`native_archive` takes `allow`, but a manifest has no field for it); `mopm unit test` and the supervisor, a published mopm release, and Arm are not covered.

### 12.10 `mojo_sync`: the sync as a build action

`buildrules mojo sync` is the only writer of `<pkg>/buildrules.mojo.lock.bzl`, `<pkg>/buildrules.mojo.bzl`, `toolchains/mojo_pins.bzl` and `toolchains/mopm_pins.bzl`. A box that may not run a
built binary (a session that builds only on the farm) cannot run it, and so could not follow a mopm bump or a change to a `mopm.toml`. `mojo_sync` (rules/mojo/sync.bzl, the Mojo counterpart of
`cargo_sync`) runs it as an action. Nothing in the action needs a shell: the staging, the run and the comparison are one Zig program (rules/mojo/tools/mojo_sync.zig).

```python
load("@buildrules//rules/mojo:sync.bzl", "mojo_sync")
mojo_sync(
    name = "sync",
    workspaces = [":workspace"],                      # the package's :workspace (12.1), and the :workspace of any other package synced with it
    files = ["//dir:mopm-toolchain.toml"],            # the other files the sync reads: the toolchain file, a buildrules-pins.toml
    mopm = "0.0.48",                                  # the version mopm-toolchain.toml names; built as toolchains//:mopm_0_0_48
    committed = ["buildrules.mojo.lock.bzl", "buildrules.mojo.bzl"],
)
```

| target | what |
|---|---|
| `:sync` | the action's output: a directory holding the files a sync writes, at their repository paths (the lock and the glue of each package, `<toolchains>/mojo_pins.bzl`, `<toolchains>/mopm_pins.bzl`) and nothing else. `buck2 run //pkg:sync` writes them into the working tree (from the repository root; `-- --to DIR` names another directory, which must hold a `.buckconfig`), only where the bytes differ, and prints each file it wrote. `buck2 build //pkg:sync --show-full-output` names the directory without writing |
| `:sync_check` | (with `committed`) red unless each committed file is, byte for byte, what the sync writes now; the message names the file, the first differing line and `buck2 run //pkg:sync`. Nothing is written: the build failing is the check |

What the action does: it copies the staged files (the `workspaces` hold the package and its path dependencies, siblings included, at their repository paths, without the generated files, so a stale table
is no input of the table that replaces it) into a scratch directory, adds a `.buckconfig` naming the toolchains directory (`toolchains = "toolchains"`; the attribute names another), and runs
`buildrules mojo sync --mopm <the pinned mopm> <packages>` there. mopm plans from each `mopm.lock` with no network. Only the files listed above leave the scratch directory. It refuses, before running
anything, a package whose `mopm-toolchain.toml` names another mopm than `mopm = "..."`: the lock records the mopm version, and the file it is written with must be that one.

Limits. A package whose toolchain file lives in a directory with no `export_file` of it gets the export added by a sync; that BUCK file is not an output, so run `buildrules mojo sync` where you can once. A path
dependency added to a `mopm.toml` since the last sync is not in the stale table's `:workspace`: add its `:workspace` to `workspaces`. `mojo_pins.bzl` holds the toolchains of the packages synced together:
sync every package of a repository that uses several Mojo versions in one target. A repository with a `buildrules-pins.toml` stages it in `files` (the lock records `origin: builtin` otherwise).

### 12.11 System libraries a test loads

A graph of **format 3** (mopm's `plan --unit-graph`) pins the libraries that a package opens by their bare names (`mode = "load"`). It has a top-level `system_libs` array, one entry per conda package of the graph's subdir (`name`, `version`, `build`, `url`, `sha256`, `size`; sorted by name; every run dependency of a library is an entry too), and each `test` and `bin` unit that loads some lists their names in `loads` (sorted). A graph with no such library is format 2 as before. A graph of a format above 3 is refused ("update buildrules"), because a rules version that does not know `loads` would run the test on whatever the worker has; `system_libs` or `loads` in a graph older than 3, a `loads` name that is no entry, a malformed or unpinned entry, and subdirs that pin other libraries or give a unit other `loads` are refused at analysis, naming the package.

`mojo_package` declares, for each entry and subdir, the pinned download of its `.conda` (the sha256 and size of the graph, the URL through `url_map` like every pin) and `:syslib_<name>` (`mojo_system_lib`, rules/mojo/system_libs.bzl): `conda_unpack --all-libs` writes every regular `lib/*.so*` and `lib/*.dylib*` file of the package flat into one directory, a link as a copy of the file it resolves to (so a bare name that is only a link opens), and nothing else (no archive, header or pkg-config file). A package whose library embeds its install prefix is refused rather than copied. No package is refused for what it is: one that holds no shared library (a metapackage such as conda-forge's `xz`, a package of tools or headers) unpacks to an empty directory, and a link to a file the package does not hold (the unversioned `liblzma.so` of `liblzma-devel`, whose library is in `liblzma`) is left out; the action says each on its standard error as `conda_unpack: note: <package>: ...`, and the build goes on. What stays an error is integrity: a download whose sha256 or size is not the pin's (`pinned_file`), an archive that is corrupt or truncated or lacks `info/paths.json`, a member named twice, an empty library, a link that leaves `lib/` or loops, and the install-prefix placeholder above (the design is the mopm repository's `docs/design/any-conda-forge-native.md`, section 8). The test run, the kcov run and the branch-coverage run of each test are given `--lib-dir <directory>` for each library it `loads`, in the graph's order (`check run|marker`, `cov_run`, `cov_branch run`; `buck2 test` runs the same command): on Linux the directories follow the compiler's lib on `LD_LIBRARY_PATH`, on macOS they come first in `DYLD_FALLBACK_LIBRARY_PATH`, before `macos_library_dirs` and dyld's defaults (a fallback: an operating system library is not shadowed and a bare name still resolves), and `DYLD_LIBRARY_PATH` stays the compiler's alone. A run without them has the environment it always had. The compiles are not given them, and a unit's slice for `mopm unit build` says format 2 and has no `loads`, so no compile moves with a pin.

A package's `:lib` also carries `MojoSystemLibsInfo` (`dirs`: the directory of each `system_libs` entry of the graph, by name): a label that adopts the package for a repository whose tests run through other rules hands them to a dependent, which puts them on its own test runs' library path the way the runs above do, so a dependent test that calls the package's code finds the same pinned files and nothing from the worker. They are no input of the library's file (the gate copies the same bytes), only of the dependent's runs. The stand-in of `ci/mojo_syslibs` (`run_green_via_lib`) runs a probe with the directories a gated library exports and is red for a library that exports none (`run_red_via_lib_without`); `ci/system_libs.bzl` holds that `:lib` of `examples/mojo/load_native` lists one library for each entry of its graph.

The directories are inputs of the run, so a change to a pin re-runs the tests that load it and no other. The pins move only with a mopm release; a user's own install may be newer within the range the manifest allows. The proof is `examples/mojo/load_native` (two tests: SQLite, absent from a Linux worker, and Brotli, absent from a macOS one without a Homebrew directory in `macos_library_dirs`) and the stand-in of `ci/mojo_syslibs` (`run_green_libless` is also given `xz`, a metapackage, and `liblzma-devel`, whose only link dangles: both unpack without failure to an empty directory, and the probe still finds its libraries), which runs the real unpack and `check run` on a probe and is red for a run given no library or one of the two it needs (`ci/negative.bzl`).

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

Every key of `[buildrules_re]` (`mode`, `linux_arm64_enabled`, the property sets, `darwin_macos_hosts`, `macos_library_dirs`) is read from the root cell's configuration, in every rule and macro that reads one, and not from the cell that evaluates the file: a repository that consumes buildrules through a cell of another repository sets them in that repository's root `.buckconfig` or `.buckconfig.local` and its platforms see them. Local mode's refusal reads `[buck2_re_client] engine_address` and `cas_address` from the root cell too, because that section is Buck2's own client configuration, which Buck2 takes from the root cell. For a repository that is its own root nothing changes. `ci/root_keys.bxl` holds this at analysis with `ci/rootcell`, a cell whose configuration has no such section.

| mode | meaning | refused when |
|---|---|---|
| `remote` (default, also when unset) | every action runs on the farm named by `[buck2_re_client]`; worker properties come from `[buildrules_re] linux_x86_64_properties` | the property set is missing (the platform fails to load, with a message naming the file to copy and the opt-in below) |
| `local` | every action runs on the machine running buck2: CI runners, people without a farm | `[buck2_re_client] engine_address` or `cas_address`, or `linux_x86_64_properties`, is also set (a machine that has a farm does not run locally); the value is neither `remote` nor `local` |

Other hosts (remote mode). A Mojo compile cannot target another platform than the one it runs on, so the Mojo rules place a package's compile, test run, gated library and `.conda` on the execution platform of the target platform's kind (`rules/mojo/exec.bzl`): linux aarch64 on `//platforms:linux_aarch64`, macOS arm64 on `//platforms:macos_aarch64`, every other platform on linux x86_64 (action keys unchanged). A farm that has such workers registers the platform with `[buildrules_re] linux_aarch64_properties` or `macos_aarch64_properties`, the exact worker property set read like `linux_x86_64_properties`; nothing is committed, and an absent key registers nothing. For a target platform whose key is absent, every target of a Mojo package fails analysis (`:check`) with a message that names the key (for linux aarch64, with the switch below on). The tools those actions run are the host's (on macOS the compile wrapper is `mojo_compile_macos`, chosen by `by_os_cpu` so a platform that states macOS in either vocabulary gets it, and which links with the host's C driver and refuses a worker whose identity is not one of `[buildrules_re] darwin_macos_hosts`, the identities `mojo_compile host-identity` prints, separated by spaces; a macOS Mojo target fails analysis without that key): the mopm tarball of `rules/mopm/hosts.bzl` (a version with none for the host is refused, naming it), and the Zig tools built for the host's target. Unpacking and the checks of the committed table stay on linux x86_64. Coverage is linux x86_64 only. C and C++ (`cxx`) are linux x86_64, except that the static library a workspace member builds from its own C (`[native.<id>]`, section 12) is also built for macOS arm64: the pinned zig, running on the linux x86_64 execution platform, compiles it for `aarch64-macos` at its generic arm64 CPU and archives it, and the macOS compile of the Mojo units links the archive (the tests of the member and of every dependent member). Nothing else of `cxx` is built for macOS arm64: the toolchain compiles and archives, it does not link an executable or a shared library for it. A registry package's native libraries, which come out of its `.conda`, are not built by these rules and were not exercised on macOS. A native library a package opens at run time by its bare name (a `mode = "load"` entry of `[native-dependencies]`, `dlopen("liblz4.so.1")`) is not linked, and a graph of format 2 or older does not list it: it is a system library the host supplies, a package declares nothing more for it, and the name is the one its code passes to `OwnedDLHandle`. On Linux the loader then searches its default directories, and the Linux run environment is the same with or without the key below. A graph of format 3 pins such libraries and the tests that load them (section 12.11), and the runs are given the pinned files instead; the key below is then only the fallback for the libraries the graph does not pin. On macOS a test is run with `DYLD_FALLBACK_LIBRARY_PATH` set to the directories of `[buildrules_re] macos_library_dirs` followed by `/usr/local/lib:/usr/lib`, and nothing else is added to the environment beside `DYLD_LIBRARY_PATH` (the compiler runtime). The key is read from the root cell like `darwin_macos_hosts`: absolute directories separated by `:` or spaces (a relative one fails analysis), kept in the order given, and passed to the runners as a flag (`--macos-library-dirs` of `check run`/`marker`, and of `gate mojo`), not as an environment variable the runner reads. Setting the variable replaces dyld's own default (`$HOME/lib:/usr/local/lib:/usr/lib`); the two defaults after the key's directories are appended so the system directories stay searched, and `$HOME/lib` is not, because a hermetic action's `HOME` is its own empty directory. With the key absent (or empty) the variable is not set and dyld's own defaults apply, as before the key existed. The value is part of the action key of a macOS test run (the flag is a command argument), so changing the key re-runs the macOS tests and no other; Linux action keys do not change. The variables are set on the test program itself, which is started directly (not through `/bin/sh` or `env`, whose protection strips `DYLD_*`). `examples/mojo/subdirs` (`tests/test_bare_name_native.mojo`) opens `liblz4` this way on both hosts: it passes on a macOS worker whose `macos_library_dirs` names the directory of `liblz4.dylib`, and fails with `dlopen failed` without the key. A repo whose `platforms/BUCK` does not call `buildrules_execution_platforms` (it copies the linux x86_64 executor onto `buildrules//platforms:linux_x86_64` itself) gets nothing registered from the new keys: setting a key there makes the Mojo rules pick that platform, and Buck2 then fails with "no compatible execution platform". Such a repo registers `buildrules//platforms:linux_aarch64` and `macos_aarch64` itself, each with the exact worker property set of its key. A repo that calls `buildrules_execution_platforms` needs no change (the platforms of buildrules are its default for the other hosts). In local mode the keys are refused like `linux_x86_64_properties`. `ci/exec_select.bxl` holds this at analysis, with the keys set to placeholders and absent.

The linux arm64 switch. Linux arm64 tests are disabled until Linux arm64 farm hardware is racked, behind one setting, `[buildrules_re] linux_arm64_enabled` (`true` or `false`; absent = `false`). It is a config key and not a constant so that a repo flips it in its own `.buckconfig.local` and `ci/exec_select.bxl` can hold both states. While it is `false`: the `linux_aarch64` execution platform is not registered even when `linux_aarch64_properties` is set (`rules/platforms.bzl`), and every target of every Mojo package (and its `sync` targets) requires `//platforms:skipped_waiting_on_linux_arm64_hardware` on a linux aarch64 target platform. No platform has that value, so such a target is incompatible: `buck2 build --skip-incompatible-targets` lists it as skipped and builds nothing for it, and a dependency on it is incompatible too. The reason is `skipped: waiting on linux-arm64 hardware`; it is never reported as a pass. Nothing is deleted: with the switch `true` the targets are exactly what they were (no `target_compatible_with` is added, so no action key changes). macOS arm64 is not covered by the switch. To re-enable, add `linux_arm64_enabled = true` under `[buildrules_re]` in `.buckconfig.local` (or the committed `.buckconfig`).
Local mode is hermetic in what it runs, not in where: the tools of every action are the pinned toolchains' (busybox, zig, rustc, cargo, the Node distribution, ...), downloaded by buck2
and checked against their sha256, with the same command lines and inputs as on a farm. The machine supplies buck2, its kernel and its CPU. The ISA platforms are registered too and run on the machine's CPU:
`x86-64-v3` tests need a CPU with AVX2, BMI1/BMI2, FMA and MOVBE (the CI workflow checks `/proc/cpuinfo` first). Action cache keys do not depend on the mode.

The public CI (`.github/workflows/ci.yml`) builds `//ci:all` this way on `ubuntu-latest`. `//ci:all` is every target of the tree except the ones `ci/all.bzl` lists with a reason each: the refusal fixtures
(`probe_env`, `probe_tree`, `probe_usr`, and the `:coverage` of `cnative`, `probe_sys` and `base_sys`, which are red by design) and `ci/negative` (a known defect that a wildcard build skips; the completeness check analyses it on the platform it breaks on and fails unless it is red for the reason it carries, `ci/negative.bzl`). Before it builds, the workflow runs
`buck2 bxl //ci:completeness.bxl:check`, which fails and names every target of `//...` and `crates//...` that is in the closure of neither `//ci:all` nor `//ci:mojo` and is not excluded, so a new target cannot go unbuilt.
`//ci:all` also builds `//ci:floors`: the Zig tests of each package run again under kcov and with LLVM's block counters, and the Node tests under `jest --coverage`, and each package's lines and branches
are held to their `coverage_floor.txt` as a minimum (a fall below it fails; above it passes with a hint that the floor may be raised); `rules/coverage/README.md` says what is measured and what is not.
`//ci:mojo` is not built there: its packages need a package channel for `cnative` (the pinned mopm tarball is the published release, section 12.5); it is fetched
through `buildrules.url_map` from a mirror a public runner does not have. `//ci:mojo` is built on a farm that has the mirror.
`//ci:all` therefore also builds `//ci:lock_hashes` (`ci/lock_hashes_check.zig`), which needs no Mojo and no network: it reads every committed `buildrules.mojo.lock.bzl`, hashes each source file the lock lists (`{"path": P, "sha256": H}`) and fails, naming the lock, the path, the declared hash and the actual hash, for a hash that differs or a file that is not there. A source edited without `buildrules mojo sync` is thus red on the public runner and not only in `//ci:mojo`. It reads the files of every package (the packages list of the no-shell lint, which `ci/completeness.bxl` holds to the tree) and not a glob, so a lock in a new package is read and a package missing from the list is a completeness failure. Its unit tests (a fixture lock with a wrong hash and one that lists a missing file, each refused) run with its build.

`ci.yml` runs on pull requests (build and unit tests; the only workflow that does), and `.github/workflows/release.yml` calls it as the first stage for a push to `main`; a green push that changes more than documentation or CI is then tagged and released with no human action (RELEASING.md). `//ci:workflow` checks the three workflows (`ci/workflow_check.zig`, `ci/release_check.zig`, `ci/stages_check.zig`).
