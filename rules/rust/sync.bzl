"""`cargo_sync`: `buildrules sync` as a farm action, for any workspace whose Cargo.lock pins its packages.

A farm action has no network, so cargo can neither fetch crates.io nor clone a git repository in it. Everything a sync fetches is pinned already,
though: Cargo.lock records the sha256 of every crates.io package, and third_party/buildrules/git_archives.tsv the sha256 and size of GitHub's archive
of every git commit. So the rule takes three steps, none of which needs the network inside an action:

    1. `buildrules sync --list-sources` reads the lock and the record and names every file to fetch (a remote action; it runs no cargo);
    2. buck2 downloads each one by its sha256 (a dynamic action over that list), so a lock entry whose bytes are not the ones it pins fails the
       download, by URL, which names the crate;
    3. `buildrules sync --sources` runs the pinned cargo and the generator in a copy of the workspace (rules/rust/sync_stage.zig) against those
       files only (cli/src/sources.zig), checking each against its hash again. Every id cargo prints is still crates.io's or the git source's, so
       the files it makes are the files a sync with the network makes.

Three ways to use the target:

    buck2 build //:sync --out .        (check = False)  the output holds every file the sync wrote or changed, and `--out .` puts them into the
                                                         repository: the one command after editing Cargo.toml or Cargo.lock (docs/how.md).
    buck2 build //:sync_check          (check = True)   red unless the committed generated files are what a sync writes now.
    buck2 build //:sync_patch --out D  (patch = True)   the same sync, and what it changed as a verdict, a patch `git apply` takes and the
                                                         files (rules/rust/sync_patch.zig): green whether or not the files are stale, so CI
                                                         can offer the patch of a pull request whose table is. Every cargo_workspace declares
                                                         `:sync_patch` (cargo.bzl); `:sync` and `:sync_check` are a `cargo_sync` call of the
                                                         root BUCK file's own.

The sub-targets `[workspace]` (the copy of the workspace the sync starts from) and `[sources]` (the files fetched by hash) are what a
test of the sync runs it again on (rules/rust/tests:sync_patch_roundtrip).

What it cannot do is resolve a package Cargo.lock does not name yet (a new crate, a git commit not in the record): cargo names it, and a sync where
there is a network adds it once.
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/core:url_map.bzl", "map_url")
load(":pins.bzl", "vname")

def _rel(path, root):
    if root and path.startswith(root + "/"):
        return path[len(root) + 1:]
    return path

def _fetch_impl(actions, listing, url_map, sources):
    """Step 2: each file `buildrules sync --list-sources` names, downloaded by its sha256 (and its size, when the record holds one; a crate's comes
    from the server), in one directory under the names `--sources` reads. The directory holds the files themselves, not links to them, so a
    test that is given it as data (rules/rust/tests:sync_patch_roundtrip, whose fixtures are copied) reads them."""
    files = {}
    for s in listing.read_json()["sources"]:
        f = actions.declare_output("fetched/" + s["file"], has_content_based_path = False)
        if s["size"] == None:
            actions.download_file(f.as_output(), map_url(url_map, s["url"]), sha256 = s["sha256"])
        else:
            actions.download_file(f.as_output(), map_url(url_map, s["url"]), sha256 = s["sha256"], size_bytes = s["size"])
        files[s["file"]] = f
    actions.copied_dir(sources, files)
    return []

_fetch = dynamic_actions(
    impl = _fetch_impl,
    attrs = {
        "listing": dynattrs.artifact_value(),
        "sources": dynattrs.output(),
        "url_map": dynattrs.value(str),
    },
)

def _sync_impl(ctx):
    if ctx.attrs.check and ctx.attrs.patch:
        fail("cargo_sync: `check` and `patch` are two ways to use the sync; give one")
    files = {_rel(s.short_path, ctx.attrs.root): s for s in ctx.attrs.srcs}
    # A filegroup's output is one directory holding the package's files at their paths: it goes where the package is.
    for d in ctx.attrs.deps:
        files[_rel(d.label.package, ctx.attrs.root)] = d[DefaultInfo].default_outputs[0]
    # A file whose path in the workspace is not its path in the tree.
    for path, f in ctx.attrs.named.items():
        files[path] = f
    workspace = ctx.actions.copied_dir("workspace", files)
    listing = ctx.actions.declare_output("sources.json")
    ctx.actions.run(
        cmd_args(ctx.attrs._buildrules[RunInfo], "sync", "--dir", workspace, "--list-sources", listing.as_output()),
        category = "cargo_sync_sources",
        identifier = ctx.label.name,
    )
    sources = ctx.actions.declare_output("sources", dir = True)
    ctx.actions.dynamic_output_new(_fetch(listing = listing, url_map = ctx.attrs.url_map, sources = sources.as_output()))
    out = ctx.actions.declare_output("synced", dir = True)
    # sync_stage, or `sync_patch make` (the same staging and sync, and the patch of what it changed): the same flags.
    cmd = cmd_args(ctx.attrs._patch[RunInfo], "make") if ctx.attrs.patch else cmd_args(ctx.attrs._stage[RunInfo])
    cmd.add(
        "--src",
        workspace,
        "--out",
        out.as_output(),
        "--buildrules",
        ctx.attrs._buildrules[RunInfo],
        "--cargo",
        ctx.attrs.cargo[DefaultInfo].default_outputs[0],
        "--sysroot",
        ctx.attrs.sysroot[DefaultInfo].default_outputs[0],
        "--pins",
        ctx.attrs._pins[DefaultInfo].default_outputs[0],
        "--sources",
        sources,
    )
    if ctx.attrs.check:
        cmd.add("--check")
    ctx.actions.run(cmd, category = "cargo_sync_patch" if ctx.attrs.patch else "cargo_sync", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out, sub_targets = {
        "sources": [DefaultInfo(default_output = sources)],
        "workspace": [DefaultInfo(default_output = workspace)],
    })]

_cargo_sync = rule(
    impl = _sync_impl,
    doc = "Runs `buildrules sync` (or `sync --check`, or the sync and its patch) in a copy of the workspace `srcs`, against the packages of its Cargo.lock downloaded by hash.",
    attrs = {
        "cargo": attrs.exec_dep(),
        "check": attrs.bool(default = False),
        # The files of the packages below the workspace root (the members: `:sources` of cargo_package; the registry and git units: `:files`), which a glob of
        # the root package cannot reach.
        "deps": attrs.list(attrs.dep(), default = []),
        # Workspace path -> file, for a file whose path in the workspace is not its path in the tree: the toolchains cell's
        # rust_pins.bzl (cargo.bzl, `:sync_patch`), and the edited manifests of a test's stale workspace (examples/gitcrates).
        "named": attrs.dict(attrs.string(), attrs.source(), default = {}),
        # `sync_patch make` in place of sync_stage: the output is a verdict, a patch and the files (rules/rust/sync_patch.zig).
        "patch": attrs.bool(default = False),
        # The workspace's files, and the directory (relative to the repository root) they are relative to.
        "root": attrs.string(default = ""),
        "srcs": attrs.list(attrs.source()),
        "sysroot": attrs.exec_dep(),
        # `buildrules.url_map` (rules/core/url_map.bzl): where the downloads come from on this machine; the hashes are checked all the same.
        "url_map": attrs.string(default = ""),
        "_buildrules": attrs.exec_dep(default = "buildrules//cli:buildrules", providers = [RunInfo]),
        "_patch": attrs.exec_dep(default = "buildrules//rules/rust:sync_patch", providers = [RunInfo]),
        "_pins": attrs.exec_dep(default = "buildrules//rules/rust:pins.bzl"),
        "_stage": attrs.exec_dep(default = "buildrules//rules/rust:sync_stage", providers = [RunInfo]),
    },
)

def cargo_sync(name, rustc, srcs, deps = [], root = "", check = False, patch = False, named = {}, **kwargs):
    """`rustc`: the Rust version of the workspace's rust-toolchain.toml (its pinned cargo and sysroot run the sync)."""
    _cargo_sync(
        name = name,
        cargo = "toolchains//:cargo_" + vname(rustc),
        check = check,
        patch = patch,
        named = named,
        deps = deps,
        exec_compatible_with = LINUX_X86_64,
        root = root,
        srcs = srcs,
        sysroot = "toolchains//:sysroot_" + vname(rustc),
        url_map = read_config("buildrules", "url_map", ""),
        **kwargs
    )
