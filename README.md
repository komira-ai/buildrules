# buildrules (v0 proof of concept)

Hermetic Buck2 rules, Apache-2.0. v0: Rust, Node, Zig, C/C++ and Mojo on linux-x86_64 only.

    rules/core        pinned_file (sha256 + size download), run_check
    rules/rust        pins.bzl (the Rust version table: RUST_VERSIONS, RUST_DEFAULT, RUST_OLDEST), toolchain.bzl (one toolchain per version), rust.bzl, cargo.bzl
                      (cargo_workspace, cargo_package), cargo_unit.bzl, test_run.bzl, isa_audit.bzl, rustc_launch.zig, bs_runner.zig, sync.bzl (`buildrules sync` on a farm)
    rules/isa.bzl     ISA_LEVELS: one table of -march flags (rustc, zig cc, Mojo) and the selects that use it; rules/matrix.bzl: CI matrix transitions
    rules/zig, rules/gate, rules/kpin, rules/node, rules/pins
                      generic rules; kpin is pins.toml / npm only
    rules/node        node_dist, npm_tarball (one pinned tarball), npm_modules, tsc_*, jest_test, ...; npm.bzl: the front door `npm_package(path = ".")` (docs/contract.md section 13)
    rules/cxx, third_party/aws-lc   hermetic C/C++ on the pinned zig; AWS-LC 1.39.0 (crypto[static-pic]) with prefix, symbol and glibc-floor gates
    rules/mojo        mojo_package (docs/contract.md section 12): one `mopm unit build` action per unit of mopm's graph, tests, coverage, `:check`; mojo_launch, prebuilt_unpack
    rules/mopm        the pinned mopm (pins.bzl, toolchain.bzl)
    rules/coverage    kcov v42 built from source and the coverage path tools, cov_run, cov_summary
    cli/              the `buildrules` command line (Zig): init, cargo new/init/adopt, sync, check, npm sync/check, mojo sync/check. The unit-graph generator is part of it
    rules/platforms.bzl   the execution platforms: remote by default (properties come from .buckconfig.local), local on request (`-c buildrules_re.mode=local`, docs/contract.md section 14)
    toolchains/       the `toolchains` cell: rust_toolchains(), cxx_toolchains(), mopm_toolchains(), mojo_toolchains() (the last from mopm's graphs)
    platforms/        linux_x86_64, linux_x86_64_v1..v4 and linux_armv8_*, linux_x86_64_rust_<v>; platforms/exec (the execution platforms: agnostic + one per ISA level)
    tools/release     the release tool (Zig): version, deterministic source archive, checks, GitHub release (RELEASING.md); tools/scrub: the public-repository scrub
    ci/               the CI matrix (`buck2 build //ci:matrix`): examples on the default and oldest Rust, both zigs, ISA v1 and v3, the refusals, examples/crates;
                      `//ci:mojo`: the Mojo examples; ci/negative planted defects
    site/, infra/     the buildrules.dev site (built and tested on the farm) and its infrastructure
    examples/hello    rust_binary + rust_library + rust_test (welded) + run_check
    examples/isa      Rust and C built at an ISA level; isa_audit reads the machine code for ymm
    examples/crates   a workspace of its own (the cell `crates`) with crates.io dependencies: a build script (cc) that compiles zstd and a crate that links it;
                      `buck2 build //ci:crates` lints and tests it and proves its generated files are what `buildrules sync` writes (no network: a local registry)
    examples/p4ws     std-only crates for the build-script contract (links/DEP_*, undeclared reads), in the unit-level form
    examples/unpinned a table for a Rust nobody pins: cargo_package must refuse it (rules/rust/refusal.bzl)
    examples/mojo     ws: app -> util -> base (workspace members) and a registry package with a native C library; registry/cnative: its publisher's side

Build (copy .buckconfig.local.example to .buckconfig.local first; actions run on the remote-execution farm it names):

    buck2 build examples/hello:hello_runs

Without a farm, opt in to running every action on this machine, with the same pinned toolchains (docs/contract.md section 14):

    buck2 build -c buildrules_re.mode=local examples/hello:hello_runs

`.github/workflows/ci.yml` does that on GitHub's hosted runners; `.github/workflows/release.yml` calls it for every push to main and releases a green one automatically (RELEASING.md: a tag and a source archive with its sha256; no binaries). `//ci:workflow` checks both workflows.

`rust-toolchain.toml` selects the Rust version (1.95.0 here); `rules/rust/pins.bzl` holds every version buildrules can fetch (1.95.0 default, 1.85.0 oldest),
and `buildrules-pins.toml` adds your own (docs/contract.md section 6).
The buck2 binary is the release pinned in `tools/buck2` (dotslash file); `./buck2` is its gitignored extraction.

## Using it from another repository

```
[cells]
  buildrules = buildrules-ext          # a git external cell needs no directory
  toolchains = toolchains
[external_cells]
  buildrules = git
[external_cell_buildrules]
  git_origin = <the repository>
  commit_hash = <the commit>
[parser]
  target_platform_detector_spec = target:<root>//...->buildrules//platforms:linux_x86_64 target:buildrules//...->buildrules//platforms:linux_x86_64 target:toolchains//...->buildrules//platforms:linux_x86_64
[build]
  execution_platforms = <root>//platforms/exec:exec
```

`buildrules init` writes this. `toolchains/BUCK`: `rust_toolchains()` (cargo_unit), plus `cxx_toolchains()` if C/C++ rules are used;
`platforms/exec/BUCK`: `buildrules_execution_platforms(name = "exec", linux_x86_64 = "buildrules//platforms:linux_x86_64")`.
The worker properties come from `[buildrules_re]` in the root `.buckconfig.local`.

## Registry crates whose build script a buildrules target replaces

`third_party/buildrules/overrides.json` (hand-written, read by `buildrules sync`): per `name version`, `why` (required),
`drop_build_script`, `cfgs`, `native_deps` (static archives a binary or test links) and `patch` (copy / sub / add on the
unpacked crate, `rules/rust/crate_patch.zig`). The example is `aws-lc-sys` -> `//third_party/aws-lc:crypto[static-pic]`.
Every other build script runs as it is, under `rules/rust/bs_runner.zig` (`examples/crates`: zstd-sys). A `cargo_package(extra_srcs = [...])` names files
outside the package that `include_str!` reads; a `[[bin]]`/`[[test]]` whose path is outside `src/` and `tests/` is a source.

## The front door (`cargo_workspace`, `cargo_package`)

    BUCK                      cargo_workspace(path = ".")      :check, :lint :debug :test :release, one target per action
    crates/<m>/BUCK           cargo_package(path = ".")
    buildrules.bzl            written by `buildrules sync`: binds the table to the two macros
    buildrules.lock.bzl       the generated table: units, lints, policy, manifest hashes; pure data
    third_party/buildrules    the registry units (BUCK, crate_sizes.tsv), generated
    rules/rust/cargo.bzl      the macros; rules/rust/cargo_unit.bzl the one rule behind every unit

Per member: `:lib`, `:bin` (if any), `:debug`, `:release`, `:test` (one `.passed` marker per cargo test target), `:lint` (clippy-driver, the
member's `[lints]`, `clippy.toml`, `-D warnings` by policy), `:coverage` (refuses: not built for Rust yet), `:sources` (the package's files) and one target per action named in
`[workspace.metadata.buildrules]` / `[package.metadata.buildrules]` (`actions = { ci = ["lint", "test"] }`). Every step carries the workspace's `:check`
as a validation: a Cargo.toml, Cargo.lock or rust-toolchain.toml that differs from what the table was made from is red, and no compile
action takes a Cargo.toml as an input. Doctests are out of v0.

## The contract

`docs/contract.md` is the contract between the rules, the generator and the `buildrules` command line (load paths, generated files,
table schema, `[*.metadata.buildrules]`, `rust-toolchain.toml`, the `.buckconfig` that `init` writes, exit codes). The command line and the generator
are Zig (`cli/`); nothing needs Python or any other interpreter.

## Cells

The rules are used as a cell of another repository. facebook/buck2#683 (a `.bzl` file's types are distinct per loading cell) bites transitive
sets only: a tset declared in a rules cell fails when a second cell uses it. Providers made of lists, dicts and artifacts cross cells, so the rules here
use no tset (rules/mojo/providers.bzl says so), and a rules cell can sit next to any number of consumers. The earlier probes of this (nested projects with a
pinned external cell) were removed with their home-path origins; `examples/crates` is a second cell of this repository that builds with these rules.

## Before a push

`buck2 build //tools/scrub:scrub` reads every file of the repository and is red on a date before 2026-09-01, a personal name, an email, a home path,
a private host, an IP address, an endpoint, private-infrastructure vocabulary or the name of the project this one grew out of (tools/scrub/README.md).
