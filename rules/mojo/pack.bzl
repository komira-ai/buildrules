"""`mojo_conda`: a library as the `.conda` a registry serves (the publisher's side, for fixtures).

`mopm pack` writes one `.conda` per subdir holding `lib/mojo/<name>.mojoc` and its metadata. The registry stand-ins of the
examples use it so that a consumer's lock can name a real package, its sha256 and its size. `mopm pack` is mopm's: this rule
only runs it on the `.mojoc` a `mojo_package` built. (Publishing, which uploads, is not a build action.)

A package that ships a static native library (`[native.<id>] kind = "static"` in its manifest) gives `natives = {"<id>": "<archive target>"}`:
the archive is packed as `lib<id>.a` beside the `.mojoc`, and the package's `.mopm.json` names it. The consumer's `mopm lock` pins the archive's
sha256; the consumer's `mojo_package` takes it out of the `.conda` (rules/mojo/tools/prebuilt_unpack.zig).
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules:platforms.bzl", "linux_arm64_gate")
load(":exec.bzl", "unit_exec")
load("//rules/cxx:providers.bzl", "NativeArchiveInfo")
load("//rules/native:link.bzl", "check_cxx_link")
load(":providers.bzl", "MojoLibInfo")

def _within(path):
    """`a/b/../c` -> `a/c`; None when the path leaves the directory it starts in."""
    out = []
    for p in path.split("/"):
        if p in ("", "."):
            continue
        if p == "..":
            if not out:
                return None
            out.pop()
        else:
            out.append(p)
    return "/".join(out)

def workspace_tree(dir, manifest, members):
    """The files `mopm pack` reads, laid out as the repository has them: `{"<repository path>/mopm.toml": <file>}`.

    `dir` is the package's directory from the repository root ("" for the root itself) and `members` maps each path dependency, as the package's mopm.toml
    writes it (`util`, or `../b` for a sibling), to that package's mopm.toml. mopm reads the manifest of a path dependency at
    `<dir of --manifest>/<path>/mopm.toml`, so the package and every member are put at their own repository paths and a sibling's `..` stays inside the
    tree. (A copied_dir refuses a key that is not normalized, which `../b/mopm.toml` is: keyed by the path as it is written, a sibling cannot be staged.)
    Fails for a path that leaves the repository, and for two entries that land on one file."""
    tree = {}
    here = _within(dir)
    if here == None:
        fail("mojo_conda: the package directory {} leaves the repository".format(dir))
    own = (here + "/" if here else "") + "mopm.toml"
    tree[own] = manifest
    for path, member in members.items():
        at = _within((here + "/" if here else "") + path)
        if at == None:
            fail("mojo_conda: the member {} of the package at {} leaves the repository".format(path, here or "."))
        file = (at + "/" if at else "") + "mopm.toml"
        if file in tree:
            fail("mojo_conda: the member {} of the package at {} is {}, which is already staged".format(path, here or ".", file))
        tree[file] = member
    return tree, own

def _impl(ctx):
    lib = ctx.attrs.lib[MojoLibInfo]
    subdir = ctx.attrs.subdir
    out = ctx.actions.declare_output("channel", dir = True)
    manifest = ctx.attrs.manifest
    if ctx.attrs.members:
        tree, own = workspace_tree(ctx.attrs.dir, manifest, ctx.attrs.members)
        workspace = ctx.actions.copied_dir("workspace", tree)
        manifest = cmd_args(workspace.project(own), hidden = workspace)
    cmd = cmd_args(
        ctx.attrs.mopm[RunInfo],
        "pack",
        "--compiler",
        ctx.attrs.mojo,
        "--mojoc",
        cmd_args(subdir + "=", lib.mojoc, delimiter = ""),
        "--manifest",
        manifest,
        "-o",
        out.as_output(),
    )
    # A published member whose archive has C++ sources must say `link = ["c++"]` (mopm writes it into the package's metadata, and a consumer's link adds `-lc++` from it): the
    # `link` of the member's library unit is the graph's statement of it. Refused here, where the archive that ships is known, and not in a consumer's link.
    check_cxx_link(str(ctx.label), any([(a.get(NativeArchiveInfo) != None and a[NativeArchiveInfo].cxx) for a in ctx.attrs.natives.values()]), ctx.attrs.link)
    for native_id, archive in ctx.attrs.natives.items():
        # The package's `[native.<id>] kind = "static"`: the archive is `lib<id>.a` in the `.conda` (mopm names the library by the file's name, which must
        # be the soname of the unit: a `native_archive` says its own).
        info = archive.get(NativeArchiveInfo)
        named = ctx.actions.copy_file("natives/" + (info.soname if info else "lib{}.a".format(native_id)), archive[DefaultInfo].default_outputs[0])
        cmd.add("--native", cmd_args("{}={}:".format(native_id, subdir), named, delimiter = ""))
    ctx.actions.run(cmd, category = "mopm_pack", identifier = ctx.attrs.package)
    conda = out.project("{}/mojo-{}-{}-mojo{}_0.conda".format(subdir, ctx.attrs.package, ctx.attrs.version, ctx.attrs.mojo))
    return [DefaultInfo(default_output = conda, sub_targets = {"channel": [DefaultInfo(default_output = out)]})]

_mojo_conda = rule(
    impl = _impl,
    attrs = {
        "lib": attrs.dep(providers = [MojoLibInfo]),
        "manifest": attrs.source(),
        # The package's directory from the repository root, which `members` are laid out around ("" when it is the root). A member's path may start with `..`
        # (a sibling directory): it is staged at its repository path, below the same workspace as the package.
        "dir": attrs.string(default = ""),
        # The manifests of the path dependencies (workspace members) the manifest names: `{"<path as the manifest writes it>": "<their mopm.toml>"}`.
        "members": attrs.dict(attrs.string(), attrs.source(), default = {}),
        # `[native.<id>]` of the manifest -> the static archive (a `cxx_library[static-pic]`) packed as `lib<id>.a` (mopm pack --native).
        "natives": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        # The `link` of the member's library unit in mopm's graph: the system libraries a consumer's final link adds (`[native.<id>] link = [...]` of the manifest).
        "link": attrs.list(attrs.string(), default = []),
        "mojo": attrs.string(),
        "mopm": attrs.exec_dep(),
        "package": attrs.string(),
        # The conda subdir of the target platform (`linux-64`, `linux-aarch64`, `osx-arm64`): the directory of the channel the `.conda` is in, and the
        # subdir `mopm pack` is told the `.mojoc` and every native archive are built for (rules/mojo/subdirs.bzl).
        "subdir": attrs.string(default = "linux-64"),
        "version": attrs.string(),
    },
)

def mojo_conda(**kwargs):
    # A `target_compatible_with` of the caller is added to the arm64 gate's.
    own = kwargs.pop("target_compatible_with", [])
    _mojo_conda(exec_compatible_with = unit_exec(), target_compatible_with = linux_arm64_gate() + own, **kwargs)

def _holds_impl(ctx):
    out = ctx.actions.declare_output(ctx.attrs.package + ".mojoc")
    natives = ctx.actions.declare_output("natives", dir = True)
    cmd = cmd_args(ctx.attrs.unpacker[DefaultInfo].default_outputs[0], ctx.attrs.conda[DefaultInfo].default_outputs[0], ctx.attrs.package, out.as_output(), "--natives", natives.as_output())
    for soname, archive in sorted(ctx.attrs.natives.items()):
        cmd.add("--native-from", cmd_args("{}=".format(soname), archive[DefaultInfo].default_outputs[0], delimiter = ""))
    if ctx.attrs.sole:
        cmd.add("--sole")
    if ctx.attrs.depends != None:
        if ctx.attrs.depends:
            for dep in ctx.attrs.depends:
                cmd.add("--depends", dep)
        else:
            cmd.add("--no-depends")
    ctx.actions.run(cmd, category = "mojo_conda_holds", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out)]

_mojo_conda_holds = rule(
    impl = _holds_impl,
    attrs = {
        "conda": attrs.dep(),
        # `{"lib<id>.a": <the archive target>}`: the `.conda` must hold `lib/<soname>` with exactly the bytes of that target's file.
        "natives": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "package": attrs.string(),
        # `sole`: the `.conda` holds nothing under `lib/mojo/` but the package's own `.mojoc` and `.mopm.json` (a package packed from a workspace holds none of
        # its siblings).
        "sole": attrs.bool(default = False),
        # `depends`: the dependencies the `.conda` records after the compiler, exactly and in order, each as conda spells it (`"mojo-<name> <range>"`); `[]` is
        # none. Unset, they are not checked.
        "depends": attrs.option(attrs.list(attrs.string()), default = None),
        "unpacker": attrs.exec_dep(default = "buildrules//rules/mojo:prebuilt_unpack"),
    },
)

def mojo_conda_holds(**kwargs):
    """The `.conda` of `mojo_conda` holds each native library at `lib/<soname>` with the bytes the build made: unpacked by `prebuilt_unpack`, which refuses a
    member that is missing, empty, a link, or whose sha256 is not that of the file. Building it is the check. With `sole = True` it also refuses a `.conda`
    that holds a file of another package under `lib/mojo/`, and with `depends = [...]` one whose recorded dependencies are not those, exactly."""
    _mojo_conda_holds(exec_compatible_with = LINUX_X86_64, **kwargs)
