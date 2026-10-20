# Why buildrules, and how it is designed

Part 1 of 2. This part is the argument and the design. Part 2 ([how.md](how.md)) is
the manual: install, configure, build. The same text is on the site, under Why and How.

Everything here describes the repository at its current `main`. Where a thing is
planned and not built, the text says "planned". Where a claim rests on an
experiment that has not been repeated, it says what was and was not shown.

## 1. Summary

buildrules is a set of [Buck2](https://buck2.build) rules and a command line, written
in Zig, that builds Rust, Node.js, Zig, C/C++ and Mojo projects from the files their
native tools already use (`Cargo.toml`, `Cargo.lock`, `package.json`,
`package-lock.json`, `mopm.toml`), with every compiler and runtime pinned by hash,
and with a separate cacheable action for each dependency.

Four ideas carry the design:

1. **The native lockfile stays the source of truth.** buildrules never keeps a second
   dependency list. `cargo build`, `cargo test` and `npm test` keep working on the same
   files.
2. **Toolchains are pinned downloads, not host installs.** No action reads a host
   compiler, a host `PATH` or a host `node`.
3. **The unit of caching is one dependency.** A registry crate is one action. An npm
   package is one download. A Mojo package is one action. A change recompiles what it
   touched and nothing else.
4. **Build metadata is generated ahead of time and checked.** Starlark cannot read
   TOML or JSON, so a command (`buildrules sync`) bakes the lockfiles into a generated
   table, and a second command (`buildrules check`) refuses a table that has gone stale.

Status: version 0, linux x86_64 only. The public repository's releases are source
archives, not binaries. Section 9 lists what is not done.

Planned and not built: Arm and macOS (and Windows) hosts, release binaries of the
command line, a Homebrew formula, an apt repository, an install script, and Python rules.

## 2. The problem

### 2.1 Native tools are good at one language

`cargo`, `npm` and `zig build` are what the people who write each language expect to
use. They resolve versions, write a lockfile, build, test, and are documented in every
tutorial. A project of one language rarely needs anything else.

A repository of several languages meets the limit. Each tool has its own idea of
caching, its own idea of where a build happens, and no knowledge of the others. One
`cargo` invocation does not know that a C library it links is built by a different tool,
or that a web bundle needs the Rust crate to exist first. The glue is shell scripts and
CI configuration, which nothing checks.

### 2.2 Monorepo build systems solve this by taking the description over

Systems such as Buck2 and Bazel express the whole graph, across languages, as targets in
build files. That buys one scheduler, one cache and remote execution. The usual price is
that the build system's description becomes the source of truth: dependencies are listed in
build files, often copied from a lockfile or generated from it, and the native tool no longer
knows about the build. The language's own commands either stop working or work on a copy that
can drift from what the build uses.

buildrules is an attempt to keep the benefits and avoid that price. (This paragraph
describes build systems in general and is background, not a claim about this repository's
code.)

### 2.3 Host toolchains make builds differ between machines

A build that calls whichever `rustc`, `cc` or `node` is on the `PATH` produces
different output on different machines, and a cache keyed on the inputs cannot tell. The
inputs it can see (sources, flags) are the same; the input it cannot see (the compiler) is not.
Two consequences follow.

- The cache is unsound: a hit can return the output of a different compiler.
- The cache is useless between machines: to be safe, the key has to include something about
  the machine, so no two machines share entries.

The fix is to make the compiler an input: download it by hash, give every action a path to
it, and give the action nothing else.

### 2.4 Caches that miss

A cache entry is useful only if its key is stable. Two common sources of unstable keys:

- **Coarse actions.** If a whole Cargo workspace is one action, touching one crate misses
  the whole action. A cache that can only reuse "everything or nothing" reuses little.
- **Leaking paths and environment.** If an output records the directory it was built in (a
  debug-info compile directory, a path in a manifest), the same sources built in two places
  are two different files, and a downstream action's key changes with them.

buildrules answers the first with one action per dependency (section 5.3) and the second by
building every pinned tool with the working directory remapped out of its output, and then
building each test repository twice in two directories to prove it (section 7).

### 2.5 Remote execution needs complete inputs

Remote execution runs an action on another machine that has only what the action declares. A
build that works locally because the host happens to have a library, a `HOME` configuration or a
network connection fails there, or worse, works there by accident. Remote execution is
therefore a strong test of hermeticity, and buildrules uses it that way: its default execution
platform is remote, and a local fallback exists only as an explicit opt-in (section 5.9).

## 3. The approach

buildrules is a thin layer. It does not replace Cargo's resolver, npm's resolver or mopm's.
Each of them still decides what the dependency graph is. buildrules reads the decision and turns it into
Buck2 actions.

| Language | Who decides the graph | What buildrules reads | What it adds |
|---|---|---|---|
| Rust | Cargo | `Cargo.lock`, and the unit graph Cargo prints (`--unit-graph`) | one action per unit; pinned rustc, std, cargo, clippy |
| Node.js | npm | `package-lock.json` (lockfile version 3) | one download per locked tarball; pinned Node.js |
| Mojo | mopm | mopm's unit graph (`mopm plan --unit-graph`) | one action per unit (`mopm unit build`); pinned mopm |
| Zig | you, by hand | build files you write | pinned Zig, tests welded to executables |
| C/C++ | you, by hand | the prelude's `cxx_library` and `cxx_binary` | a toolchain on the pinned Zig (`zig cc`) |

Buck2 supplies the scheduler, the content-addressed cache and the Remote Execution API
(REAPI) client. buildrules does not implement any of them.

## 4. What a user sees

```
buildrules init . --git <origin> --commit <40 hex>   # once per repository
buildrules cargo new crates/hello                    # or: cargo adopt
buildrules sync                                      # after Cargo.toml, Cargo.lock or rust-toolchain.toml change
buck2 build //crates/hello:test //crates/hello:debug
buildrules check                                     # offline, read-only: the pull-request gate
```

A member's `BUCK` file is two lines and the command line writes it:

```python
load("//:buildrules.bzl", "cargo_package")

cargo_package(path = ".")
```

Node and Mojo have the same shape (`buildrules npm sync`, `buildrules mojo sync`, one macro
call per package). The manual is part 2.

## 5. The design

### 5.1 Layers

```
 your repository
   .buckconfig          cells, execution platforms, pinned buildrules commit
   toolchains/BUCK      one call per toolchain family
   platforms/BUCK       the execution platforms
   buildrules.lock.bzl  generated table (Rust)         <- buildrules sync
   buildrules.bzl       generated binding of table to macros
   third_party/buildrules/BUCK   registry crates as units
 buildrules (a Buck2 cell, pinned to one commit)
   rules/               the rules: rust, node, zig, cxx, mojo, mopm, coverage, core, pins
   cli/                 the `buildrules` program (Zig); contains the generator
   platforms/           target platforms, one per instruction-set level
 Buck2 (pinned release; the bundled prelude is part of the binary)
```

buildrules is used as a Buck2 *cell* pinned by a full commit hash (a git external cell, or a
vendored copy). Every machine that builds the repository gets the same rules. The pin is a
commit, not a branch or a tag: `buildrules init` refuses anything that is not 40 hex digits.

The Mojo rules avoid transitive sets. Buck2 treats a `.bzl` file's types as distinct per loading cell
(an open upstream limitation, facebook/buck2#683), so a transitive set's type is per cell. The providers
of the Mojo rules (`rules/mojo/providers.bzl`) are lists and dicts, which cross cells, so a rules cell
can sit next to a consumer cell.

### 5.2 The sync and check model

Starlark cannot read TOML. While Buck2 loads a package, a macro cannot open `Cargo.toml`, and
shelling out at load time would put an unpinned tool into every query.

So the reading happens ahead of time, in `buildrules sync`, and its result is written down as
data:

- `buildrules.lock.bzl` is pure Starlark literals: the compiler version, the sha256 of
  `Cargo.lock` and of every `Cargo.toml`, the policy, and one row per unit.
- `buildrules.bzl` binds the table to the macros.
- `third_party/buildrules/BUCK` declares the registry crates.

All three are committed. A second `sync` on unchanged inputs writes the same bytes. A generated
file says "Do not edit" in its first line, and editing one is detected.

Staleness has three layers, from cheap to thorough:

1. `buildrules check` is offline and read-only. It compares hashes and the presence of files and
   exits 1 on any difference, printing the fix. It is meant for pull requests.
2. `:check`, a Buck2 *validation* attached to every `:debug`, `:release`, `:test` and `:lint`
   target, compares the same hashes at build time. A stale table cannot be built.
3. `buildrules sync --check` regenerates into `buck-out/` and exits 1 unless every generated file
   is byte-identical to the committed one.

No compile action takes a `Cargo.toml` as an input. Editing the policy in
`[package.metadata.buildrules]` therefore re-runs the check and nothing else.

The cost is real: a developer must remember to run `sync` after changing a manifest. The design
makes forgetting loud (layer 1 fails the pull request; layer 2 fails the build) instead of
silent.

### 5.3 Rust: the `cargo_unit` engine

`cargo build --unit-graph` (unstable, so `sync` sets `RUSTC_BOOTSTRAP=1` for that one
invocation, and nothing is compiled) prints the graph Cargo itself would execute: every
crate, with its features, profile, edition and dependencies. `sync` runs it per member and per
verb (build, test, release), merges the graphs, and writes one table row per distinct unit.
buildrules does not re-implement Cargo's resolver or feature unification.

Each unit becomes one `cargo_unit` target, named by a content id:
`<crate>-<version>_<hash>`. The hash covers the unit's body: sources, features, flags, profile
fields that rustc sees, and the ids of its dependencies. Two builds that share a unit share its
target and so its action key. Nothing in the key names the workspace member being edited. That is
the per-crate cache.

A unit has one of four modes:

| mode | action |
|---|---|
| build | compile an rlib, a proc-macro, or a binary |
| test | compile with `--test` and run the binary; the output is a `.passed` marker |
| run-custom-build | run a build script and capture what Cargo would |
| lint | run `clippy-driver` with the member's `[lints]`; a lint under `-D warnings` fails the action |

**Compilation** runs the pinned `rustc` through `rustc_launch`, a small Zig program. It rebuilds
the environment from nothing (an empty `PATH`; private `HOME`, `TMPDIR` and Zig caches), remaps the
working directory to `.`, and acts as the linker: it runs `zig cc` from the pinned Zig, with
`-Wl,--strip-debug`, because Zig's C runtime start-up objects otherwise record the directory they
were built in.

**Build scripts** run under `bs_runner`, which reproduces what Cargo gives a script: `OUT_DIR`,
`CARGO_CFG_*` (from `rustc --print=cfg`), `DEP_<LINKS>_<KEY>` from direct dependencies with `links`,
and `CC`/`CXX`/`AR` pointing at the pinned Zig. A variable the script reads and the runner does not
define is unset, so the script fails or takes its default, as in a clean Cargo run. The runner honors
`rustc-cfg`, `rustc-link-lib`, `rustc-link-search`, `rustc-flags`, `rustc-env`, `warning`, `error`
and `metadata`, and *refuses* `rustc-link-arg*` and any other `rustc-` key, so nothing is dropped
silently. A registry crate whose build script cannot be reproduced can be replaced by an override
(`third_party/buildrules/overrides.json`) that points at a buildrules target; the AWS-LC target
under `third_party/aws-lc` is built for that use. No override file ships in this repository, and
the generator's unit tests exercise the override keys.

**Tests** are build actions that write a `.passed` marker, so a cached `buck2 build` of `:test`
means the tests passed on identical inputs. (Doctests are not run; section 9.)

**Lints** use the same pinned toolchain. Clippy is a component of each Rust version's pin.

**Refusals at load.** The macros refuse, with the fix in the message: a compiler that is not
pinned; a table whose recorded toolchain hashes differ from the pins; lto, a custom codegen
backend, rpath, incremental and split-debuginfo profile fields; git or alternate-registry
dependencies; a root `[package]`.

There is also a set of hand-written rules (`rust_library`, `rust_binary`, `rust_test`) for
crates described without Cargo. They share the toolchain and the launcher. `rust_library` can weld
its tests with `gate_tests = [...]` so the library cannot be built unless they pass.

### 5.4 Node.js: `npm_package`

`package-lock.json` (lockfile version 3) is the single source of what is installed. `package.json`
is the single source of what is run. `buildrules npm sync` reads both and writes
`buildrules.lock.bzl`: the pinned Node.js version, the sha256 of both files, the scripts and the
`"buildrules"` policy, and one row per locked tarball.

A row holds the registry URL, the lockfile's sha512 `integrity`, and a sha256 and size. Buck2 keys
downloads by sha256, npm records sha512; `sync` downloads each tarball once, checks that its sha512
equals the lockfile's, and records the sha256. A tarball whose bytes changed under the same version
fails the build.

`:node_modules` is one cached action per locked tarball (download, check, unpack as npm does) plus
one assembly action that copies each package to the paths the lockfile gives it and links `.bin`. No
install script runs. Packages whose `os`, `cpu` or `libc` exclude linux x64 glibc are not declared.
A lockfile change re-runs the assembly and not the downloads.

A script step (`:typecheck`, `:lint`, `:test`, `:build`) runs the package's `package.json` script
with the pinned Node.js in a copy of the package, with an environment of a scratch `HOME`, UTC, and a
`PATH` of Node and the declared `step_tools`. Scripts are read without a shell: `&&`, quotes,
backslashes and leading `NAME=value` are understood; pipes, redirection, `;`, `||`, `$`, globs, `npm`
and `npx` are refused with the fix. The refusal is raised when the step is built, not by `sync`.

### 5.5 Mojo: `mojo_package` over mopm

[mopm](https://mopm.dev) is a package manager for Mojo. It owns what "build Mojo" means: it resolves
dependencies into `mopm.lock` and can print a *unit graph* (`mopm plan --unit-graph`) naming every
compile unit, its inputs and its outputs. buildrules does not write a second Mojo driver. It runs
mopm's answer as cached Buck2 actions, as it runs rustc on Cargo's answer.

- `buildrules mojo sync` runs the pinned mopm and writes its graph *verbatim* into
  `buildrules.mojo.lock.bzl`, so reviewing the diff of the table is reviewing mopm's output.
- Each unit is one action: `mopm unit build`, which checks every declared input against the graph's
  hashes and then runs the compiler with an empty environment.
- A unit's action receives a *slice* of the graph: its own entry without mopm's `key`, and the
  imported units reduced to what the compiler needs. mopm's key hashes every dependency's key, so it
  moves with any edit below; Buck2's own key (the digests of the inputs) replaces it. Unchanged
  `.mojoc` bytes therefore stop a rebuild cascade.
- Registry packages arrive as sha256-pinned `.conda` files, matched to the Mojo version, unpacked and
  never compiled.
- buildrules pins *no Mojo compiler of its own*. The toolchain is whatever mopm's graphs name
  (compiler and runtime libraries by sha256, plus the Zig that links), copied into
  `toolchains/mojo_pins.bzl` by `sync`. A new Mojo version is a mopm release plus a `sync`.
- Coverage: each test is built again with debug info and run under kcov (v42, built from source with
  the pinned Zig in the `rules/coverage` package). The report is mapped to repository paths. It is
  line coverage of what the compiler emitted code for, so a function no test reaches emits none and
  the percentage is an upper bound.

`mopm-toolchain.toml` names the mopm and Mojo versions. It is required (as `rust-toolchain.toml` is),
found by walking up from the package directory.

The Mojo rules and mopm's own releases have different clocks. A mopm row of `rules/mopm/pins.bzl`
marked `release_pending` is a stand-in built from a development tree, and its hash is not that of
the published mopm release at the same URL; the Mojo beta leg is skipped while a row is marked. A row
without that mark is the published release, and the leg runs. The file shows which it is, and a test
fails if the file, `beta/mojo/STEPS` and `RELEASING.md` disagree.

### 5.6 The Zig family and C/C++

Zig is the toolchain for everything native. The `zig_exe`, `zig_test` and `zig_module` rules
compile Zig code with a pinned Zig (0.12.0 by default, 0.15.2 available). A `zig_exe` can name
`unit_tests = [...]` so the executable is not built unless its unit tests pass: the weld.

C and C++ use the prelude's `cxx_library` and `cxx_binary` with a toolchain that
`cxx_toolchains()` declares. The compiler, assembler and archiver are `zig cc`, `zig c++` and
`zig ar` of the pinned Zig, launched through `zig_cc_launcher`. The target is
`x86_64-linux-gnu.2.34`, so a produced binary uses no glibc symbol newer than 2.34. The toolchain compiles with `-g0`
and links with `-Wl,--strip-debug`. `nm`, `objcopy`, `strip` and every Python helper tool of the
prelude are *refusals* that name the tool and exit 2, never a search of the worker's `PATH`.

Gates that run as Buck2 validations (they run in every build whose graph holds the library):

| gate | what it refuses |
|---|---|
| `hermetic_check` | a binary with a `.debug_*` section or the path of its link directory in its bytes |
| `glibc_floor_check` | an ELF needing a glibc symbol version newer than a stated floor |
| `prefixed_archive_check` | a vendored library whose defined symbols do not all carry a prefix |
| `c_check` | a built executable whose exit status or stdout is not as declared |

A vendored C library can be built with every global symbol renamed under a prefix. The worked
example is AWS-LC 1.39.0 (libcrypto only), which a Rust override can use in place of a crate's
own AWS-LC build script. The renaming header is generated from the library's own symbol table, and the
prefixed archive is read back and refused unless every defined symbol carries the prefix.
`docs/cxx_mutants.md` lists six planted defects that each go red.

### 5.7 Pins and version tables

Every tool an action runs is a download with a URL, a sha256 and a size. A wrong hash fails the
download. Where the tools come from:

| tool | where the pin lives | pinned today |
|---|---|---|
| Rust (rustc, rust-std, cargo, clippy; llvm-tools for the ISA audit) | `rules/rust/pins.bzl` (`RUST_VERSIONS`, `RUST_DEFAULT`, `RUST_OLDEST`) | 1.95.0 (default), 1.85.0 (oldest) |
| Zig | `rules/pins/pins.bzl` | 0.12.0 (default), 0.15.2 |
| busybox (the shell and file utilities) | `rules/pins/pins.bzl` | 1.35.0, static |
| Node.js | `rules/node/pins.bzl` | 24.21.0, linux x64 |
| mopm | `rules/mopm/pins.bzl` | 0.0.1 (a stand-in only if the row is marked `release_pending`; see section 5.5) |
| Mojo | not pinned by buildrules: named by mopm's graph | the one version mopm pins |
| libgcc, libstdcxx (conda-forge) | `rules/pins/pins.bzl` | 15.3.0 |

A repository selects a Rust version in `rust-toolchain.toml`, which must name an *exact* release.
`stable`, `1.95`, a beta channel or a dated nightly is refused, because a floating channel is a
different compiler tomorrow. This one file also selects the compiler for plain `cargo`, through
rustup, so Cargo and Buck2 agree.

A repository that needs a version buildrules does not pin writes its hashes into
`buildrules-pins.toml`. `sync` copies them into generated files the toolchain macros read
(`toolchains/rust_pins.bzl`, `toolchains/mopm_pins.bzl`). A version that buildrules already pins is
refused in that file: the reviewed hashes win.

A toolchain is an input of every compile, test and lint action of its units, so two Rust versions
never share an action key. An upgrade is a visible diff of a pin and a regenerated table.

The pins are fetched from their upstream hosts. `buildrules.url_map` replaces a URL's leading part
and nothing else, to route a download through a mirror; the hash is still checked. `docs/pins.md`
lists the mirrors that were verified byte-identical and says which pins have none.

### 5.8 Instruction-set platforms

A target platform can pick an instruction-set level. `rules/isa.bzl` holds one table, `ISA_LEVELS`:
x86-64-v1 to v4 and armv8.0-a to armv8.4-a, each with the flags of rustc, `zig cc` and Mojo.
`native` is never passed: a farm matches "at least, within the family", so host-tuned code would be
cached under a lower level's key.

- `platforms/` has one platform per level (`linux_x86_64_v3`, `linux_armv8_2`, ...) and a plain
  `linux_x86_64` with no level and no flag.
- The level is in the Buck2 configuration, so a v1 and a v3 build differ in output path and key.
- Compiles run on an ISA-agnostic execution platform (a compiler emits v3 code on any worker). A
  *test* at level vN runs on an execution platform that carries `ISA=x86-64-vN`, so the farm
  schedules it on a worker that has the level. Analysis refuses a test built for v3 that is placed
  on a platform which does not report v3.
- A build script and a proc-macro run on the build host and never get the flags.
- `isa_audit` disassembles a binary with the pinned `llvm-objdump` and fails unless it holds `ymm`
  (256-bit AVX2) instructions at v3 or v4 and none below. A flag that never reached the compiler
  would otherwise leave a green, cached, wrong build.

Only the x86-64 half is exercised. The Arm rows are data: there is no Arm worker and no
execution platform that carries an Arm level, and an Arm test finds no platform and is refused.

### 5.9 Where actions run

`[buildrules_re] mode` is `remote` (the default) or `local`.

- **remote**: every action runs on the REAPI farm named in the gitignored `.buckconfig.local`. If the
  worker property set is missing, the platform fails to load and says so. There is no silent fallback.
- **local**: every action runs on the machine running Buck2, with the same pinned toolchains, the
  same command lines and the same inputs. It is refused when a farm is also configured, so a machine
  that has a farm cannot slip into running locally.

Local mode is hermetic in *what* it runs, not *where*: the machine still supplies Buck2, its kernel
and its CPU. Action cache keys do not depend on the mode. The public CI uses local mode on GitHub's
hosted Ubuntu runners.

No endpoint, account or worker property appears in any rule, generated file or committed
configuration.

### 5.10 Tests are part of the build

A test is an action, and the library it covers cannot exist without it: a Rust library with
`gate_tests`, a Zig executable with `unit_tests`, a Cargo member's `:test` marker. A cached rebuild
therefore means the tests passed on identical inputs. The consequence for review: a green cached
build is evidence about the inputs it was keyed on, and a gate is proven only by a red build on a
planted defect. The repository follows that rule: `ci/negative` holds planted defects that must stay
red, and `docs/cxx_mutants.md` lists the mutants of the C/C++ gates.

## 6. What the repository itself runs on

The public repository is built by its own rules. `//ci:all` is every target of the tree except those
`ci/all.bzl` lists with a reason each (the refusal fixtures, which are red by design, and
`ci/negative`). A completeness query fails and names any target of the tree that is in the closure of
neither `//ci:all` nor `//ci:mojo` and is not excluded, so a new target cannot go unbuilt.

`//ci:matrix` builds the examples on the default and the oldest Rust, on both pinned Zigs, and at ISA
levels v1 and v3. The site `buildrules.dev` is built and tested by the Node rules, and its tests read
the sources the pages describe (the usage text, the contract, the pin tables) and fail when a page
names a command, rule or version that does not exist.

## 7. Determinism, and its proof

A hermetic build should produce the same bytes everywhere. buildrules claims a narrower thing and
tests it:

- **Each pinned tool is hashed**, so the compiler is the same bytes everywhere.
- **No action sees the host.** Environments are rebuilt from nothing; the working directory is
  remapped out of compiler output; build scripts get a fixed variable set.
- **The release pipeline builds each test repository twice**, the second time in a different
  directory, and compares the sha256 of every output (a file's bytes, or a directory's names and
  bytes). A second build in the same directory could not see an output that depends on the path it
  was built at; this one can. Any difference is red, with both digests.

This is the *beta* stage of the release (section 8). The test repositories are hello-world projects
per language, made as a user makes one: `beta/<lang>/` holds the files the user writes and a `STEPS`
file lists the commands the user types. The stage tool copies the directory outside the checkout, runs
the steps with the `buildrules` built from the candidate commit, builds, runs what was built, checks
what it prints, then builds again from nothing.

The proof found real defects. C and C++ outputs depended on the directory they were linked in (Zig
assembles the C runtime's start-up objects at link time with debug info that names the working
directory, whatever `-g0` said). The toolchain now links with `-Wl,--strip-debug`, and `hermetic_check`
fails a binary that has a `.debug_*` section or contains its link directory. The fix was shown red
without the flag and green with it on the farm.

What this establishes, and what it does not:

- It establishes that those two path dependencies are gone, and that each environment's two builds
  agree across two paths.
- It does **not** establish that a binary built on a GitHub runner and one built on the farm are the
  same bytes: no run compares a runner leg with a farm leg, and a farm leg does not repeat the build
  (the farm's cache would answer it; it requires `local: 0` instead). That claim should be made only
  if a beta run shows it.
- It does not cover Arm or macOS (section 9).

## 8. Releases

A release is automatic: every push to `main` that changes more than documentation or CI and is green
in every stage is tagged and published with no human action. The pipeline (`.github/workflows/release.yml`,
described in `RELEASING.md`) runs these stages in order, each only if the previous succeeded:

| stage | what |
|---|---|
| gate | the whole tree (`//ci:all`) and the completeness check, in local mode on a runner |
| beta | hello-world repositories per language, consuming the candidate commit as a user would, each built twice in two directories |
| gamma | the maintainers' own repositories built on the farm with the candidate; fails the release if no farm is configured |
| plan | decides whether this commit is released and the version; creates nothing |
| archive | a deterministic source archive of the tested commit, its `SHA256SUMS`, and GitHub build provenance attestations of both |
| verify | read-only: the sha256 matches; the checkout is the tested commit; the attestations verify, pinned to this workflow, commit and `refs/heads/main`; rebuilding the archive gives the same bytes; the file list equals the commit's tree; the public-repository scrub passes |
| tag | the annotated tag, made only after the archive verifies |
| publish | the GitHub release, from the verified files |
| bump | after `publish`: opens a pull request, with auto-merge, in a downstream repository named by a repository variable, moving its `buildrules` submodule to the released commit; nothing waits for it, and a failed bump un-releases nothing |

Two properties are deliberate:

- **Verify before tag.** Nothing before `tag` waits for it, so a failure in the archive, the
  attestation or the verification leaves no tag behind. The tag is the first thing in the pipeline
  that cannot be taken back, and it is made last but for the release.
- **A small blast radius for tokens.** A ruleset lets only one GitHub App, the release bot, create
  or move a `v*` tag. The `tag` job mints the bot's token, scoped to this repository and to contents
  write, and uses it in one step; the `bump` job mints a second token for the downstream repository
  alone, also used in one step. `publish` uses the ordinary workflow token and `gh release create --verify-tag`,
  which cannot create a tag. A static check (`ci/release_check.zig`) holds the workflow to this, and
  also refuses `continue-on-error` and inline expansion of variables in `run:` lines.

A version is `v<MAJOR>.<MINOR>.<PATCH>`. `MAJOR.MINOR` is the `VERSION` file; `PATCH` is the highest
existing tag plus one. An old run is never published after a newer one.

What a release holds: `buildrules-<version>.tar.gz`, `SHA256SUMS`, notes, and the attestations.
The archive is reproducible with one stated dependence: the tar bytes are git's, so the archive is
made once and verified against a second build with the same git on the same runner. A consumer relies
on the published file and its sha256, not on remaking it. **There are no binaries**: the command line
is built from the source archive on your farm or machine (part 2). Other channels are planned
(section 9).

## 9. Trade-offs, limits and what is not done

### Trade-offs taken on purpose

- **Generated tables, committed.** The price of keeping the lockfile authoritative is a generated
  file that must be refreshed. The checks (section 5.2) turn forgetting into a red build.
- **Remote by default.** The point is a shared cache and uniform workers. A machine with no farm must
  say so (`mode=local`). The cost is a harder first run.
- **Exact toolchain versions only.** `stable` and `1.95` are refused. This makes upgrades explicit and
  blocks a silent compiler change; it also means you must know the exact version.
- **Refusal over approximation.** An unsupported Cargo feature, a build-script directive that cannot be
  reproduced, or a shell construct in an npm script is refused with the fix. Nothing is dropped or
  guessed.
- **A mirror is a map, not a fallback.** Buck2's download rule takes one URL; buildrules does not
  invent a second.

### Limits today (built behaviour)

- **Linux x86_64 only**, for clients and workers. macOS, Windows and Arm are *planned*; nothing is
  built for them. `beta.yml` declares the Arm (`ubuntu-24.04-arm`) and macOS (`macos-14`) legs and
  skips them, with the reason in the job name.
- **Rust:** crates.io only; the workspace root is the repository root and must be a virtual workspace;
  every package listed in `members` (a glob other than `dir/*` is refused); doctests not run;
  `:coverage` refuses; lto, rpath, incremental and split-debuginfo refused; `sync` needs the network
  the first time a registry crate is fetched.
- **Node:** lockfile version 3 only; no workspaces; registry tarballs over https only; install
  scripts do not run; scripts must fit the shell-free subset; one `dist` directory.
- **Mojo:** one Mojo version (the one mopm pins); a workspace member's native libraries are not in
  mopm's graph yet; line coverage only (no branch coverage, no floors); `mopm lock` contacts the
  registry even for path dependencies only.
- **The host still supplies** a Linux kernel, glibc 2.34 or newer, and `libgcc_s.so.1` and
  `libz.so.1` (the Rust compiler needs them; they are not pinned yet), plus Buck2 itself.
- **Only one farm** has run buildrules. It uses plain REAPI v2 through Buck2, so other farms that
  implement it should work; that has not been tested.
- **Python** rules are planned; no design is committed.

### Not done, so you know

- Release binaries for the command line, a Homebrew formula, an apt repository, an install script:
  none exist for buildrules (all planned). The command line is built from the source archive.
- Arm and macOS hosts (planned): their beta legs, which `beta.yml` declares and skips, and execution
  platforms for the Arm instruction-set levels.
- A published, deployed `buildrules.dev` (the site is built and tested; its hosting stack is a step
  the repository owner runs).

### Why it may still be the right trade

For a team that already runs a remote cache and wants Rust, Node, native code and Mojo in one graph
without giving up `cargo` and `npm`, the cost is a `sync` step and a stricter toolchain policy. For
a single-language project that builds well with its native tool, buildrules adds a layer that does
not pay for itself. That judgment is the reader's; this document makes no claim about build
times, and none is measured here.
