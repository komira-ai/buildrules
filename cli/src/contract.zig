//! The contract (docs/contract.md in the buildrules repository), as constants: every file name, label
//! and text the CLI writes or reads that a Starlark file or a user depends on. One place, so the
//! writers (init, cargo, sync) and the readers (check, the contract tests) cannot drift apart.

const std = @import("std");

/// `SCHEMA` of buildrules.lock.bzl. A reader refuses any other value.
pub const schema: u32 = 2;

/// The target the unit graphs are made for (v0 is Linux x86_64 only).
pub const target = "x86_64-unknown-linux-gnu";

/// The generated table: pure data, written by the unit-graph generator.
pub const lock_file = "buildrules.lock.bzl";
/// The wrapper that binds the table to the two macros; the only file BUCK files load.
pub const bzl_file = "buildrules.bzl";
/// Registry units: one package at the repository root, written by the generator.
pub const third_party = "third_party/buildrules";
pub const sizes_file = "third_party/buildrules/crate_sizes.tsv";
/// Hand-written, optional: registry crates whose build script a buildrules target replaces (cli/src/buckgen.zig).
pub const overrides_file = "third_party/buildrules/overrides.json";

/// Hand-written, optional: the Rust versions this repository pins itself (docs/contract.md, section 6). `sync` copies it into
/// the generated `toolchains/rust_pins.bzl`, which `toolchains/BUCK` loads; `check` fails when either differs from the other.
pub const pins_file = "buildrules-pins.toml";
pub const rust_pins_file = "toolchains/rust_pins.bzl";

/// Mojo (docs/contract.md, section 12). Per package, next to its mopm.toml: the unit graph as mopm printed it, and the glue.
pub const mojo_lock_file = "buildrules.mojo.lock.bzl";
pub const mojo_bzl_file = "buildrules.mojo.bzl";
/// `SCHEMA` of buildrules.mojo.lock.bzl.
pub const mojo_schema: u32 = 1;
/// Found by walking up from a package; required, with no default (docs/contract.md, section 12).
pub const mojo_toolchain_file = "mopm-toolchain.toml";
/// Written by `buildrules mojo sync` from the graphs and from buildrules-pins.toml; loaded by toolchains/BUCK.
pub const toolchains_dir = "toolchains";
pub const mojo_pins_name = "mojo_pins.bzl";
pub const mopm_pins_name = "mopm_pins.bzl";
/// The default places; the `toolchains` cell of .buckconfig (`[cells] toolchains = DIR`) moves the directory (mojo_cmd.zig, `resolveTables`).
pub const mojo_pins_file = toolchains_dir ++ "/" ++ mojo_pins_name;
pub const mopm_pins_file = toolchains_dir ++ "/" ++ mopm_pins_name;
/// The section and key of .buckconfig that name the toolchains directory: the cell itself.
pub const buckconfig_section = "cells";
pub const buckconfig_toolchains_key = "toolchains";
pub const mojo_defs_label = "@buildrules//rules/mojo:defs.bzl";

pub const mojo_bzl_text =
    "# Written by `buildrules mojo sync`. Do not edit: `buildrules check` fails when this differs from what sync writes.\n" ++
    "# Binds the generated table (" ++ mojo_lock_file ++ ") to the macro of " ++ mojo_defs_label ++ ".\n" ++
    "load(\"" ++ mojo_defs_label ++ "\", _mojo_package = \"mojo_package\")\n" ++
    "load(\":" ++ mojo_lock_file ++ "\", \"CLOSURE_SHA256\", \"GRAPH\", \"MANIFEST_SHA256\", \"MOJO\", \"MOPM\", \"SCHEMA\")\n\n" ++
    "TABLE = {\n" ++
    "    \"CLOSURE_SHA256\": CLOSURE_SHA256,\n" ++
    "    \"GRAPH\": GRAPH,\n" ++
    "    \"MANIFEST_SHA256\": MANIFEST_SHA256,\n" ++
    "    \"MOJO\": MOJO,\n" ++
    "    \"MOPM\": MOPM,\n" ++
    "    \"SCHEMA\": SCHEMA,\n" ++
    "}\n\n" ++
    "def mojo_package(path = \".\", **kwargs):\n" ++
    "    _mojo_package(path = path, table = TABLE, **kwargs)\n";

/// The public load path of the macros.
pub const defs_label = "@buildrules//rules/rust:defs.bzl";
/// The Rust version table the generator reads (an exported file the CLI builds).
pub const pins_target = "buildrules//rules/rust:pins.bzl";

pub const metadata_header = "[package.metadata.buildrules]";
pub const workspace_metadata_header = "[workspace.metadata.buildrules]";

/// What a BUCK file loads: the repository-root wrapper.
pub const member_load = "load(\"//:" ++ bzl_file ++ "\", \"cargo_package\")\n";
pub const member_call = "cargo_package(path = \".\")\n";
pub const member_buck = member_load ++ "\n" ++ member_call;

pub const workspace_buck =
    "# Written once by `buildrules sync`; yours after that. The workspace's targets: :check, and one aggregate per step.\n" ++
    "load(\"//:" ++ bzl_file ++ "\", \"cargo_workspace\")\n\n" ++
    "cargo_workspace(path = \".\")\n";

pub const bzl_text =
    "# Written by `buildrules sync`. Do not edit: `buildrules check` fails when this differs from what sync writes.\n" ++
    "# Binds the generated table (" ++ lock_file ++ ") to the two macros of " ++ defs_label ++ ".\n" ++
    "load(\"" ++ defs_label ++ "\", _cargo_package = \"cargo_package\", _cargo_workspace = \"cargo_workspace\")\n" ++
    "load(\":" ++ lock_file ++ "\", \"CARGO_LOCK_SHA256\", \"MANIFEST_SHA256\", \"MEMBERS\", \"PACKAGES\", \"RUSTC\", \"TOOLCHAIN\", \"UNITS\", \"WORKSPACE\")\n\n" ++
    "THIRD_PARTY = \"//" ++ third_party ++ "\"\n\n" ++
    "CARGO = {\n" ++
    "    \"CARGO_LOCK_SHA256\": CARGO_LOCK_SHA256,\n" ++
    "    \"MANIFEST_SHA256\": MANIFEST_SHA256,\n" ++
    "    \"MEMBERS\": MEMBERS,\n" ++
    "    \"PACKAGES\": PACKAGES,\n" ++
    "    \"RUSTC\": RUSTC,\n" ++
    "    \"TOOLCHAIN\": TOOLCHAIN,\n" ++
    "    \"UNITS\": UNITS,\n" ++
    "    \"WORKSPACE\": WORKSPACE,\n" ++
    "}\n\n" ++
    "def cargo_package(path = \".\", **kwargs):\n" ++
    "    _cargo_package(path = path, table = CARGO, third_party = THIRD_PARTY, **kwargs)\n\n" ++
    "def cargo_workspace(path = \".\", **kwargs):\n" ++
    "    _cargo_workspace(path = path, table = CARGO, **kwargs)\n";

/// The Cargo.toml `init` writes when the repository has none: a virtual workspace with the policy
/// every member inherits (actions are chains of steps; docs/contract.md).
pub const workspace_manifest =
    "# Written by `buildrules init`. A virtual workspace: v0 wants the root manifest to have no [package].\n" ++
    "[workspace]\n" ++
    "resolver = \"3\"\n" ++
    "members = []\n\n" ++
    workspace_metadata_header ++ "\n" ++
    "# Policy only (profiles and lints stay in cargo's own tables). `ci` is what `buck2 build //:ci` builds.\n" ++
    "default-action = \"ci\"\n\n" ++
    "[workspace.metadata.buildrules.actions]\n" ++
    "ci = [\"lint\", \"test\"]\n\n" ++
    "[workspace.metadata.buildrules.lint]\n" ++
    "deny-warnings = true\n\n" ++
    "# A hermetic build cannot use incremental compilation: the generator refuses a profile that has it on.\n" ++
    "[profile.dev]\n" ++
    "incremental = false\n";

/// Added to a member's Cargo.toml by `cargo new|init|adopt`.
pub const member_metadata =
    metadata_header ++ "\n" ++
    "# Policy only: `actions = { name = [\"lint\", \"test\"] }`, `default-action`, `[package.metadata.buildrules.lint]`.\n" ++
    "# Absent keys inherit [workspace.metadata.buildrules]. See docs/contract.md.\n";

/// Exit codes of every command.
pub const exit_ok: u8 = 0;
pub const exit_fail: u8 = 1;
pub const exit_usage: u8 = 2;

/// The paths a repository's `.gitignore` must carry.
pub const ignore_lines = [_][]const u8{ ".buckconfig.local", "buck-out/" };

comptime {
    std.debug.assert(schema == 2);
}

/// The keys `[workspace.metadata.buildrules]` and `[package.metadata.buildrules]` accept (the generator,
/// cli/src/unitgen.zig, refuses any other), the one key under `lint`, and the steps an action may chain.
pub const policy_keys = [_][]const u8{ "default-action", "actions", "lint" };
pub const lint_keys = [_][]const u8{"deny-warnings"};
pub const steps = [_][]const u8{ "lint", "debug", "test", "release", "coverage" };
