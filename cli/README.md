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
| `autopin compute --event FILE --out DIR --set DIR=KIND ... [--dir DIR]` | for CI: regenerate the pin tables (`buildrules.lock.bzl`, `pins.lock.bzl`) of the named directories from their `package-lock.json` (strict lock, registry tarballs only, capped downloads), write the changed tables and a `manifest.json` under `--out`; the output is untrusted for whatever reads it next (`src/autopin_*.zig`) |

Exit codes of every command: 0 ok, 1 failed or stale, 2 usage.

`sync` runs the generator in process (`unitgen.zig` turns the graphs, `Cargo.lock` and the manifests into the table; `buckgen.zig` turns the table into the
registry package and writes the sizes; `toml.zig` and `val.zig` read and write the formats). Its content ids are byte for byte the Python generator's it replaced, so no committed table
changed. It gets the pinned cargo, the pinned rustc and the Rust version table by building `toolchains//:cargo_<v>`, `:sysroot_<v>` (`<v>` = the version of
`rust-toolchain.toml`, `_` for `.`) and `buildrules//rules/rust:pins.bzl` with `buck2` unless `--cargo`, `--rustc`, `--pins` are given. Nothing needs an interpreter.

Reused from kpin: `diag.zig`, `valid.zig`, `cargo_lock.zig`. kpin's crates generator (`cargo.zig`,
`cargo_trim.zig`) belongs to the other Rust engine and is retired here: the contract's engine is `cargo_unit`.
`rules/zig/zig.bzl` is a stand-in `zig_exe`/`zig_test` until the seed track's Zig rules land.
