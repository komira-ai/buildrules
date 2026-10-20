# buildrules: how to use it

Part 2 of 2. Part 1 ([why.md](why.md)) is the argument and the design. This part is the manual:
get started, configure, and examples per language.

Everything here is version 0 and runs on **linux x86_64 only**. It describes the repository at its
current `main`. Items marked **planned** do not exist yet: Arm and macOS hosts for the rules, a Homebrew
formula, an apt repository and an install script.

## 1. Getting started

### 1.1 What you need

- Linux on x86_64 with glibc 2.34 or newer, and `libgcc_s.so.1` and `libz.so.1` (the Rust compiler
  loads them; buildrules does not pin them yet).
- [Buck2](https://buck2.build). The buildrules repository pins the release it is tested with in
  `tools/buck2`. Newer releases may work; that is not tested here.
- Git.
- Either a remote execution farm that speaks the
  [Remote Execution API](https://github.com/bazelbuild/remote-apis) (REAPI), or the explicit local
  mode (section 1.4). Nothing else runs on your machine: the generator is part of the `buildrules`
  program, and nothing needs Python or another interpreter.

### 1.2 Get the command line

A release carries the command line as a static program for four platforms, and a source archive (a
Homebrew formula, an apt repository and an install script are **planned**). Pick a release from the
[releases page](https://github.com/komira-ai/buildrules/releases). To use a program, unpack the
tarball of your platform (`linux-x86_64`, `linux-aarch64`, `macos-arm64` or `macos-x86_64`), check it,
and put `buildrules` on your `PATH`:

```sh
v=0.0.1     # the release you chose
t=linux-x86_64     # your platform
curl -fsSLO "https://github.com/komira-ai/buildrules/releases/download/v$v/buildrules-cli-$v-$t.tar.gz"
curl -fsSLO "https://github.com/komira-ai/buildrules/releases/download/v$v/SHA256SUMS"
sha256sum --check --ignore-missing SHA256SUMS
tar -xzf "buildrules-cli-$v-$t.tar.gz"
"buildrules-cli-$v-$t/buildrules" --version
```

`--version` prints `buildrules <version>`, the number of the release. Each tarball carries a
build provenance attestation and a signature, checked with `gh attestation verify` as for the source
archive below. The macOS programs are not code-signed or notarised, and only the linux x86_64 program
is run by the release's user beta. The rules themselves run on a linux x86_64 farm or machine.

Or build the command line from source with Buck2. Check the source archive:

```sh
v=0.0.1     # the release you chose
curl -fsSLO "https://github.com/komira-ai/buildrules/releases/download/v$v/buildrules-$v.tar.gz"
curl -fsSLO "https://github.com/komira-ai/buildrules/releases/download/v$v/SHA256SUMS"
sha256sum --check SHA256SUMS
gh attestation verify "buildrules-$v.tar.gz" --repo OWNER/REPO
tar -xzf "buildrules-$v.tar.gz"
cd "buildrules-$v"
```

`OWNER/REPO` are the two path segments of the repository URL above. The attestation is GitHub build provenance, signed with the release workflow's identity. It proves
the archive was built by that workflow from a commit of `main`. `gh` is only needed for that line.

Build the program. With no farm, use local mode (section 1.4):

```sh
buck2 build -c buildrules_re.mode=local //cli:buildrules --show-output
```

`--show-output` prints the path of the executable. Put it on your `PATH` as `buildrules`.
`buildrules --help` lists the commands and `buildrules <command> --help` their flags. Exit codes are
the same everywhere: `0` ok, `1` failed or stale (the fix is printed), `2` usage.

(A program built from the source archive prints `<MAJOR.MINOR>-dev` for `--version`: only the
released tarballs are stamped with the release number.)

### 1.3 Initialize your repository

Run `init` once, in the repository root. It adds buildrules as a Buck2 cell pinned to one commit.
Get the commit of the release tag:

```sh
git ls-remote https://github.com/komira-ai/buildrules 'refs/tags/v0.0.1^{}'
```

```sh
buildrules init . --git https://github.com/komira-ai/buildrules --commit <the 40-hex commit above>
```

The commit must be 40 hex digits. A branch or tag is refused, because it is not a pin. `init` writes
the files below and never overwrites one that exists:

| file | what |
|---|---|
| `.buckconfig` | cells, execution platform, the pinned buildrules commit, download timeouts |
| `toolchains/BUCK` | one call: `rust_toolchains(extra = EXTRA_RUST_VERSIONS)` |
| `toolchains/rust_pins.bzl` | the extra Rust versions from `buildrules-pins.toml` (empty at first; `sync` rewrites it) |
| `platforms/BUCK` | the execution platform (remote by default) |
| `.buckconfig.local.example` | a template for the farm settings |
| `rust-toolchain.toml` | an exact compiler, if you have none |
| `Cargo.toml` | a virtual workspace with the `[workspace.metadata.buildrules]` policy, if you have none |
| `.gitignore` | lines for `.buckconfig.local` and `buck-out/` |

Other flags: `--path RELPATH` instead of `--git` (buildrules is a local cell inside the repository: a
submodule or a vendored copy, as unpacked from the archive), `--cell NAME` (the name of your repository's
own cell, default `root`) and `--rust-version N.N.N` (default `1.95.0`).

A root `Cargo.toml` that has a `[package]` is refused. The root must be a virtual workspace and your
packages live in subdirectories.

### 1.4 Say where actions run

Buck2 needs somewhere to run actions. buildrules has two modes, chosen by `[buildrules_re] mode`.

**Local mode** runs every action on the machine that runs Buck2, with the same pinned toolchains. Use it
on a CI runner or without a farm. Either pass the option on every command,

```sh
buck2 build -c buildrules_re.mode=local //crates/hello:test
```

or write it once in the gitignored `.buckconfig.local`:

```ini
[buildrules_re]
  mode = local
```

Local mode is refused if an engine or CAS address or a worker property set is also configured: a machine
that has a farm does not run locally.

**Remote mode** (the default) runs every action on a farm. Copy the template and fill it in. The copy is
gitignored; never commit it.

```sh
cp .buckconfig.local.example .buckconfig.local
```

```ini
[buck2_re_client]
  engine_address = <execution endpoint>
  action_cache_address = <action cache endpoint>
  cas_address = <content-addressable storage endpoint>
  instance_name = <instance name>
  tls = true

[buildrules_re]
  linux_x86_64_properties = OSFamily=Linux,ISA=x86-64,container-image=docker://<image>@sha256:<digest>
```

`linux_x86_64_properties` is your farm's own worker property set, comma-separated `key=value` pairs,
passed through unchanged. If it is missing, the execution platform fails to load with a message that
names the file; nothing falls back to your machine.

(The text that `init` writes into `.buckconfig.local.example` today still says there is no local
fallback. Local mode exists; the comment is out of date.)

### 1.5 Your first build

```sh
buildrules cargo new crates/hello      # a package, adopted: BUCK file, metadata, workspace member
buildrules sync                        # Cargo's files -> the generated table; commit the output
buck2 build //crates/hello:test //crates/hello:debug
buildrules check                       # offline: the pull-request gate
```

What each step does:

- `cargo new` (and `cargo init`) creates a package with `--vcs none` and adopts it. Without
  `--cargo <path>` the Cargo step is skipped and a minimal manifest and source file are written. Add
  `--lib` for a library.
- `sync` lets Cargo resolve (a new dependency updates `Cargo.lock`; nothing else is upgraded), reads
  the unit graph Cargo prints for each member, and writes `buildrules.lock.bzl`, `buildrules.bzl`, the
  root `BUCK` (only if absent) and `third_party/buildrules/`. It obtains the pinned Cargo by building
  `toolchains//:cargo_<v>` with Buck2, so execution must be configured first (section 1.4). The first
  sync downloads crate sources, so it needs the network; nothing is compiled.
- `buck2 build` of `:test` runs the tests as build actions. A cached rebuild means they passed on
  identical inputs. In remote mode, check the summary line:
  `Commands: N (cached: N, remote: N, local: 0)`. In the default mode, `local` is always 0.
- `check` exits 1 if the generated files no longer match `Cargo.toml`, `Cargo.lock` and
  `rust-toolchain.toml`, and prints `buildrules sync` as the fix.

Commit everything `init` and `sync` wrote except `.buckconfig.local`.

### 1.6 Build it a second time

Run the same build again: it should be all `cached`. Change one source file of a crate and rebuild: only
that crate and what depends on it run. That is the per-dependency cache working; on a farm it is shared
by every machine and every CI job.

### 1.7 Adding it to CI

On a GitHub-hosted Ubuntu runner, local mode works with no farm. The buildrules repository's own
`.github/workflows/ci.yml` is a working example: it installs the pinned Buck2, verifies its sha256, and
runs every `buck2` command with `-c buildrules_re.mode=local`. Run `buildrules check` as a separate,
cheap step that needs no build.

## 2. Configuration

### 2.1 Files at a glance

| file | who writes it | committed | purpose |
|---|---|---|---|
| `.buckconfig` | `init` | yes | cells, execution platform, timeouts |
| `.buckconfig.local` | you | **no** | the farm, or `mode = local`; endpoints live only here |
| `rust-toolchain.toml` | `init`, you | yes | the Rust version (exact) |
| `buildrules-pins.toml` | you | yes | hashes for a version buildrules does not pin |
| `mopm-toolchain.toml` | you | yes | mopm and Mojo versions (Mojo packages) |
| `toolchains/BUCK` | `init`; you add families | yes | which toolchain families exist |
| `platforms/BUCK` | `init` | yes | execution platforms |
| `buildrules.lock.bzl`, `buildrules.bzl` | `sync` | yes | the generated table and its binding (Rust and npm, per directory) |
| `third_party/buildrules/` | `sync` | yes | registry crates as units |
| `toolchains/rust_pins.bzl`, `mopm_pins.bzl`, `mojo_pins.bzl` | `sync`, `mojo sync` | yes | generated pins |
| `<pkg>/buildrules.mojo.lock.bzl`, `buildrules.mojo.bzl` | `mojo sync` | yes | a Mojo package's graph and binding |

Generated files say "Do not edit" in their first line, and editing one is detected.

### 2.2 `.buckconfig`

`init` writes, with `CELL` the value of `--cell`:

```ini
[cells]
  CELL = .
  prelude = prelude
  toolchains = toolchains
  none = none
  buildrules = buildrules-ext          # with --path: buildrules = <RELPATH>

[external_cells]
  prelude = bundled
  buildrules = git                     # --git only

[external_cell_buildrules]
  git_origin = <ORIGIN>
  commit_hash = <40 hex>

[parser]
  target_platform_detector_spec = target:CELL//...->buildrules//platforms:linux_x86_64 target:toolchains//...->buildrules//platforms:linux_x86_64 target:buildrules//...->buildrules//platforms:linux_x86_64

[build]
  execution_platforms = CELL//platforms:exec

[http]
  connect_timeout_ms = 30000
  read_timeout_ms = 120000
```

(plus `[cell_aliases]`, `[buildfile]`, `[buck2]` and `[project]`; see the generated file.) The
`[http]` timeouts are longer than Buck2's defaults (5 seconds to connect) because every pin is a
download.

To upgrade buildrules, change `commit_hash`, run `buildrules sync` (and `mojo sync`, `npm sync` if you use
them), review the diff, commit.

### 2.3 Where actions run

`[buildrules_re] mode`: `remote` (the default, also when unset) or `local`. Any other value is refused.

| setting (in `.buckconfig.local`) | meaning |
|---|---|
| `[buck2_re_client] engine_address`, `action_cache_address`, `cas_address` | standard Buck2 RE client settings; many farms use one address for all three |
| `[buck2_re_client] instance_name`, `tls` | the REAPI instance; whether to use TLS |
| `[buildrules_re] linux_x86_64_properties` | the exact property set of the workers that run linux x86_64 actions |
| `[buildrules_re] mode` | `remote` or `local` |

Action cache keys do not depend on the mode. Local mode is hermetic in what it runs (the pinned tools,
checked by sha256), not in where: the machine supplies Buck2, its kernel and its CPU.

buildrules has been run against one farm. It uses plain REAPI v2 through Buck2, so other farms that
implement it should work; if yours differs, check the worker properties and the glibc version first.

### 2.4 The Rust toolchain: `rust-toolchain.toml`

```toml
[toolchain]
channel = "1.95.0"
components = ["clippy", "rustfmt"]
profile = "minimal"
```

It is required: `sync` and `check` fail without it. Only `channel` is read, and it must be an exact
release such as `1.95.0`. `stable`, `1.95`, a beta channel and a dated nightly are refused. A `path` key
is refused, because a toolchain on one machine is not a pin. Plain `cargo` (through rustup) reads the
same file, so Cargo and Buck2 use the same compiler.

buildrules pins `1.95.0` (the default) and `1.85.0` (the oldest it supports). Another release needs
its hashes in `buildrules-pins.toml`.

### 2.5 Your own pins: `buildrules-pins.toml`

Optional, at the repository root, hand-written. An unknown Rust version is refused unless this file
supplies the hashes of all four components:

```toml
[rust."1.86.0".rustc]
sha256 = "<64 lower-case hex>"   # the hash of rustc-1.86.0-x86_64-unknown-linux-gnu.tar.gz in the dist manifest
size = 122722040                 # bytes of that file

[rust."1.86.0".rust-std]
sha256 = "..."
size = 0                         # a positive number of bytes

[rust."1.86.0".cargo]
sha256 = "..."
size = 0

[rust."1.86.0".clippy]           # the clippy-preview tarball
sha256 = "..."
size = 0
```

Only these tables and keys are read; `#` comments are allowed; no `date` key. A version that buildrules
already pins is refused (the reviewed hashes win). `sync` copies the file into
`toolchains/rust_pins.bzl`. A wrong hash fails the download, never the build silently.

A mopm version buildrules does not pin goes in `[mopm."0.0.2"]` with `url`, `sha256` and `size`;
`buildrules mojo sync` copies it into `toolchains/mopm_pins.bzl`.

### 2.6 Cargo policy: `[*.metadata.buildrules]`

Policy lives in `Cargo.toml` tables that Cargo ignores. Allowed in `[workspace.metadata.buildrules]`
and, overriding per key, in `[package.metadata.buildrules]`. Any other key is refused, naming the key
and the file.

| key | meaning |
|---|---|
| `actions` | named chains of steps, e.g. `ci = ["lint", "test"]`; a name may not be a step name |
| `lint.deny-warnings` | clippy `-D warnings` for `:lint` |
| `default-action` | recorded in the table (no target derives from it yet) |

Steps are `lint`, `debug`, `test`, `release` and `coverage` (`coverage` refuses for Rust: not built).
`init` writes a virtual workspace with `resolver = "3"` and `[profile.dev] incremental = false`.
Incremental builds cannot be hermetic, and `sync` refuses an incremental profile with this fix.
Link-time optimization, a custom codegen backend, rpath and split-debuginfo profile fields are
refused too.

### 2.7 npm policy: the `"buildrules"` key of `package.json`

npm ignores the key.

```json
"buildrules": {
  "steps":   { "typecheck": "tsc-check" },
  "actions": { "ci": ["typecheck", "test", "build"] },
  "dist":    "dist"
}
```

`steps` renames the script a step runs (by default, the script of the step's own name). `actions` are
named chains of steps. `dist` is the directory the build script writes. Any other key is refused.

### 2.8 Mojo: `mopm-toolchain.toml`

```toml
[toolchain]
mopm = "0.0.1"     # an exact release buildrules pins, or one buildrules-pins.toml supplies
mojo = "1.0.0"     # an exact release mopm pins a toolchain for
```

Required. It is found by walking up from the package directory. Without it, `mojo sync`, `mojo check`
and package analysis stop and print a minimal example. buildrules does not pin a Mojo compiler:
mopm's unit graph names the compiler packages, and `sync` records them.

### 2.9 Mirrors

`-c buildrules.url_map="<from-prefix>=<to-prefix> ..."` (or the same under `[buildrules]` in
`.buckconfig.local`) replaces the leading part of a pinned download's URL and nothing else. The sha256
and size are still checked, so a mirror cannot change the bytes. `docs/pins.md` lists mirrors that were
verified byte-identical, and which pins have none.

### 2.10 Target platforms and instruction-set levels

`buildrules//platforms:linux_x86_64` is the default target platform and passes no CPU flag. For a CPU
level, build with a platform of that level:

```sh
buck2 build --target-platforms buildrules//platforms:linux_x86_64_v3 //examples/isa:audit //examples/isa:isa_lib_test
```

Levels are `x86-64-v1` to `v4` (platforms `linux_x86_64_v1` ... `v4`). Arm levels (`linux_armv8_0` ...
`linux_armv8_4`) exist as data; there is no Arm worker and no execution platform that carries an Arm level, so an Arm test is
refused. A test at a level runs on a worker that reports at least that level, so your farm must
schedule on the `ISA` property. In local mode the test runs on your CPU, which must have the level.

The `platforms/BUCK` that `init` writes registers only the ISA-agnostic execution platform. To run
tests at v2 to v4 you pass `isa_platforms` to `buildrules_execution_platforms`, as buildrules'
own `platforms/exec/BUCK` does.

### 2.11 Registry crates with native build scripts

`third_party/buildrules/overrides.json` (hand-written, read by `sync`) maps `name version` to a
`why` (required), `drop_build_script`, `cfgs`, `native_deps` (static archives a binary or test
links) and a `patch` (copy, sub, add) on the unpacked crate. Every other build script runs as it is.
A substitution that stops matching after a version bump fails the build.

## 3. Examples

Sections 3.1 to 3.4 and 3.6 are repositories that the release pipeline's beta stage builds twice from
nothing as a user would; the files are under `beta/` in the repository, with the commands in each
`STEPS` file. The Mojo example (3.5) has a `beta/mojo` leg that runs when the pinned mopm is a published
release and is skipped while the mopm row of `rules/mopm/pins.bzl` is marked `release_pending` (section
3.5 says which it is). Sections 3.7 and 3.8 are built from `examples/` by `//ci:matrix`.
Replace `<origin>` and `<commit>` as in section 1.3.

### 3.1 Rust

```sh
buildrules init . --git <origin> --commit <commit>
buildrules cargo new crates/hello
buildrules sync
buildrules check
buck2 build //crates/hello:bin //crates/hello:test //crates/hello:lint
```

Per member the targets are `:lib`, `:bin` (if it has a binary), `:debug`, `:release`, `:test` (one
`.passed` marker per Cargo test target), `:lint`, `:sources`, and one per action named in the policy.
`buck2 build //crates/hello:ci` builds the `ci` action if you defined it.

A member's BUCK file:

```python
load("//:buildrules.bzl", "cargo_package")

cargo_package(path = ".")
```

An existing package that already builds with Cargo: `buildrules cargo adopt crates/existing` (no path
means every member).

Not supported: doctests (`cargo test` still runs them; `:test` does not), coverage, git or
alternate-registry dependencies, a root `[package]`.

### 3.2 Node.js

```sh
buildrules init . --git <origin> --commit <commit>
buildrules npm sync web
buildrules npm check web
buck2 build //web:ci //web:dist
```

`web/package.json`:

```json
{
  "name": "hello-node",
  "version": "1.0.0",
  "private": true,
  "scripts": { "test": "node test.js", "build": "node build.js" },
  "buildrules": { "actions": { "ci": ["test", "build"] }, "dist": "dist" }
}
```

`web/package-lock.json` is npm's own (lockfile version 3). `npm sync` writes `buildrules.lock.bzl` and
`buildrules.bzl` beside it and, if absent, a BUCK file:

```python
load(":buildrules.bzl", "npm_package")

npm_package(path = ".")
```

Targets: `:node_modules`, `:typecheck`, `:lint`, `:test`, `:build`, `:dist`, `:check`, and one per
action. `npm ci && npm test && npm run build` keeps working outside Buck2. Install scripts do not run;
scripts that use pipes, redirection, `npm` or `npx` are refused with the fix. The first `npm sync`
downloads each locked tarball once to learn its sha256; `--seed FILE` reuses a table's hashes to skip
that.

Other `npm_package` arguments: `node` (a `node_dist` of your own), `step_data`, `step_tools`,
`step_env`, `srcs`, `exclude`, `data`, `visibility`.

### 3.3 Zig

No `sync` step. Write the rules by hand:

```python
load("@buildrules//rules/zig:zig.bzl", "zig_exe", "zig_test")

zig_test(
    name = "hello_unit",
    src = "hello_test.zig",
    imports = ["hello.zig"],
)

zig_exe(
    name = "hello",
    src = "main.zig",
    imports = ["hello.zig"],
    unit_tests = [":hello_unit"],
)
```

```sh
buck2 build //:hello
```

The executable is not built unless its unit tests pass. The rules use Zig 0.12.0 by default; for
0.15.2 add `zig = "buildrules//rules/pins:zig_next"` to both rules. `zig_exe` takes `optimize`
(default `ReleaseSafe`), `strip` (default true) and `target` (default `x86_64-linux-musl`).
`zig_module` shares code between targets.

### 3.4 C and C++

Add the C/C++ toolchain to `toolchains/BUCK` (`init` writes only Rust):

```python
load("@buildrules//rules/cxx:toolchain.bzl", "cxx_toolchains")
load("@buildrules//rules/rust:toolchain.bzl", "rust_toolchains")
load(":rust_pins.bzl", "EXTRA_RUST_VERSIONS")

rust_toolchains(extra = EXTRA_RUST_VERSIONS)

cxx_toolchains()
```

Then use the prelude's rules with no load:

```python
cxx_binary(
    name = "hello_c",
    srcs = ["hello.c"],
    compiler_flags = ["-O2", "-Wall", "-Werror"],
)
```

```sh
buck2 build //:hello_c
```

There is no host compiler: the compiler is `zig cc` of the pinned Zig, and `nm`, `objcopy`, `strip` and
the prelude's Python tools are refusals that name the tool. To prove a binary independent of its build
directory, add `hermetic_check(name = "hermetic_c", exe = ":hello_c")` from
`@buildrules//rules/cxx:defs.bzl`; to prove its glibc needs, `glibc_floor_check`. To follow the platform's
CPU level pass `cxx_toolchains(target_cpu = zig_cpu())` with `zig_cpu` from `@buildrules//rules:isa.bzl`.

### 3.5 Mojo

A Mojo package is a mopm project. Layout (from the `beta/mojo` repository):

```
mopm-toolchain.toml
toolchains/BUCK            rust, cxx, mopm and mojo toolchains (see below)
hello/mopm.toml            [package] name, version, mojo; [targets] lib, tests
hello/mopm.lock            written by `mopm lock`
hello/BUCK                 the two lines below
hello/src/hello/__init__.mojo
hello/tests/test_hello.mojo
```

```python
load(":buildrules.mojo.bzl", "mojo_package")

mojo_package(path = ".")
```

`toolchains/BUCK`:

```python
load("@buildrules//rules:isa.bzl", "zig_cpu")
load("@buildrules//rules/cxx:toolchain.bzl", "cxx_toolchains")
load("@buildrules//rules/mojo:toolchain.bzl", "mojo_toolchains")
load("@buildrules//rules/mopm:toolchain.bzl", "mopm_toolchains")
load("@buildrules//rules/rust:toolchain.bzl", "rust_toolchains")
load(":mojo_pins.bzl", "MOJO_TOOLCHAINS")
load(":mopm_pins.bzl", "EXTRA_MOPM_VERSIONS")
load(":rust_pins.bzl", "EXTRA_RUST_VERSIONS")

rust_toolchains(extra = EXTRA_RUST_VERSIONS)
cxx_toolchains(target_cpu = zig_cpu())
mopm_toolchains(extra = EXTRA_MOPM_VERSIONS)
mojo_toolchains(MOJO_TOOLCHAINS)
```

```sh
mopm lock                         # mopm's own: mopm.toml -> mopm.lock (needs the package registry)
buildrules mojo sync              # mopm's unit graph -> buildrules.mojo.lock.bzl
buck2 build //hello:ci //hello:coverage
buildrules mojo check             # offline gate; `buildrules check` also runs it
```

Targets: `:lib` (the `.mojoc`), `:test` and one `:<stem>` per test file, `:build` (library and
binaries), `:coverage` (line coverage under kcov; red if a library source is in no report), `:ci`,
`:check`. A workspace member is a package with its own BUCK file. Native libraries are declared with
`natives = {"libx.so.1": "//path:target"}`. `mopm` is separate software: see <https://mopm.dev> for
its install and the registry.

Which mopm this flow downloads is the mopm row of `rules/mopm/pins.bzl`. A row marked `release_pending` is a
stand-in: its sha256 and size are those of a development build, not of the published mopm release at the
same URL, so the download fails its hash check, a fresh clone cannot run this flow end to end, and the
`beta/mojo` leg is skipped. A row without that mark is the published release, and the leg runs. The file
shows which it is. Against a stand-in, point the download at a copy of its tarball with
`buildrules.url_map`; with either, you can pin a different mopm version you supply yourself in
`buildrules-pins.toml`:

```toml
[mopm."0.0.2"]   # a version buildrules does not pin; one it pins (0.0.1 today) is refused here
url = "<release url>"
sha256 = "<64 hex>"
size = <bytes>
```

Mojo builds with the one Mojo version that mopm pins. One Mojo version per repository.

### 3.6 Several languages in one repository

`beta/mixed` is a Rust package, a C program, a Zig program and a Node package in one repository:

```sh
buildrules init . --git <origin> --commit <commit>
buildrules cargo new crates/hello
buildrules sync
buildrules npm sync web
buildrules check
buildrules npm check web
buck2 build //crates/hello:bin //crates/hello:test //native/c:hello_c //native/zig:hello //web:ci //web:dist
```

`buildrules check` runs the Cargo checks (and the Mojo checks if there are Mojo packages); `npm check`
covers each npm package.

### 3.7 Instruction-set levels

`examples/isa` builds Rust and C at an instruction-set level and reads the machine code:

```sh
buck2 build --target-platforms buildrules//platforms:linux_x86_64_v3 \
    //examples/isa:audit //examples/isa:audit_c //examples/isa:isa_lib_test
```

`isa_audit` fails unless the binary holds `ymm` (256-bit AVX2) instructions at v3 or v4 and none
below. The test runs on a worker that reports `ISA=x86-64-v3`.

### 3.8 Hand-written Rust rules

For a crate described without Cargo, `rust_library`, `rust_binary`, `rust_test` and `run_check`:

```python
load("@buildrules//rules/rust:defs.bzl", "rust_binary", "rust_library", "rust_test")
load("@buildrules//rules/core:run_check.bzl", "run_check")

rust_test(name = "hello_lib_test", srcs = ["src/lib.rs"], crate_root = "src/lib.rs", crate_name = "hello_lib")
rust_library(name = "hello_lib", srcs = ["src/lib.rs"], crate_root = "src/lib.rs", gate_tests = [":hello_lib_test"])
rust_binary(name = "hello", srcs = ["src/main.rs"], crate_root = "src/main.rs", deps = [":hello_lib"])
run_check(name = "hello_runs", exe = ":hello", expected_stdout = "hello, world")
```

`gate_tests` welds the test: the library cannot be built unless its test passes.

## 4. Reading a failure

- A message that names a command (`buildrules sync`) is telling you the fix. Run it.
- `[buildrules_re] linux_x86_64_properties` not set: `.buckconfig.local` is missing or incomplete, or
  you meant local mode (section 1.4).
- `STALE:` from `check`: a manifest or lockfile changed since the last `sync`. Run `sync`, commit.
- A rule fails at load because the compiler in the table differs from the one buildrules pins: a pin
  was bumped under the table. `sync` rewrites the table; the diff is the bump.
- `Invalid sha256 digest. Expected A, got B`: a pinned download's bytes are not the pinned ones. Do not
  edit the hash to make it pass; find out why the upstream file changed.
- `Timed out while making request`: a pinned host dropped a request. Buck2 retries three times; the
  `[http]` timeouts `init` writes are longer than its defaults. Consider a mirror (section 2.9).
- A test is red: it is a build action, so the output of the failing test is in the build's output. A
  red test is yours to diagnose; do not edit it green.

## 5. Where to go next

- `docs/contract.md`: the contract between the rules, the generator and the command line.
- `docs/pins.md`: the pins and the mirrors.
- `RELEASING.md`: how a release is made, and how to pin one.
- `cli/README.md`, `rules/cxx/README.md`, `rules/coverage/README.md`: per-component notes.
- Part 1, [why.md](why.md): the design and the trade-offs.
