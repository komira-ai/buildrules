"""`mojo_conda`: a library as the `.conda` a registry serves (the publisher's side, for fixtures).

`mopm pack` writes one `.conda` per subdir holding `lib/mojo/<name>.mojoc` and its metadata. The registry stand-ins of the
examples use it so that a consumer's lock can name a real package, its sha256 and its size. `mopm pack` is mopm's: this rule
only runs it on the `.mojoc` a `mojo_package` built. (Publishing, which uploads, is not a build action.)

A package that ships a static native library (`[native.<id>] kind = "static"` in its manifest) gives `natives = {"<id>": "<archive target>"}`:
the archive is packed as `lib<id>.a` beside the `.mojoc`, and the package's `.mopm.json` names it. The consumer's `mopm lock` pins the archive's
sha256; the consumer's `mojo_package` takes it out of the `.conda` (rules/mojo/tools/prebuilt_unpack.zig).
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/cxx:providers.bzl", "NativeArchiveInfo")
load(":providers.bzl", "MojoLibInfo")

def _impl(ctx):
    lib = ctx.attrs.lib[MojoLibInfo]
    out = ctx.actions.declare_output("channel", dir = True)
    manifest = ctx.attrs.manifest
    if ctx.attrs.members:
        # mopm reads the manifest of each path dependency at `<dir of --manifest>/<path>/mopm.toml`: lay the manifests out as the workspace has them.
        tree = {"mopm.toml": manifest}
        for path, member in ctx.attrs.members.items():
            tree[path + "/mopm.toml"] = member
        workspace = ctx.actions.copied_dir("workspace", tree)
        manifest = cmd_args(workspace.project("mopm.toml"), hidden = workspace)
    cmd = cmd_args(
        ctx.attrs.mopm[RunInfo],
        "pack",
        "--compiler",
        ctx.attrs.mojo,
        "--mojoc",
        cmd_args("linux-64=", lib.mojoc, delimiter = ""),
        "--manifest",
        manifest,
        "-o",
        out.as_output(),
    )
    for native_id, archive in ctx.attrs.natives.items():
        # The package's `[native.<id>] kind = "static"`: the archive is `lib<id>.a` in the `.conda` (mopm names the library by the file's name, which must
        # be the soname of the unit: a `native_archive` says its own).
        info = archive.get(NativeArchiveInfo)
        named = ctx.actions.copy_file("natives/" + (info.soname if info else "lib{}.a".format(native_id)), archive[DefaultInfo].default_outputs[0])
        cmd.add("--native", cmd_args("{}=linux-64:".format(native_id), named, delimiter = ""))
    ctx.actions.run(cmd, category = "mopm_pack", identifier = ctx.attrs.package)
    conda = out.project("linux-64/mojo-{}-{}-mojo{}_0.conda".format(ctx.attrs.package, ctx.attrs.version, ctx.attrs.mojo))
    return [DefaultInfo(default_output = conda, sub_targets = {"channel": [DefaultInfo(default_output = out)]})]

_mojo_conda = rule(
    impl = _impl,
    attrs = {
        "lib": attrs.dep(providers = [MojoLibInfo]),
        "manifest": attrs.source(),
        # The manifests of the path dependencies (workspace members) the manifest names: `{"<path as the manifest writes it>": "<their mopm.toml>"}`.
        "members": attrs.dict(attrs.string(), attrs.source(), default = {}),
        # `[native.<id>]` of the manifest -> the static archive (a `cxx_library[static-pic]`) packed as `lib<id>.a` (mopm pack --native).
        "natives": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "mojo": attrs.string(),
        "mopm": attrs.exec_dep(),
        "package": attrs.string(),
        "version": attrs.string(),
    },
)

def mojo_conda(**kwargs):
    _mojo_conda(exec_compatible_with = LINUX_X86_64, **kwargs)

def _holds_impl(ctx):
    out = ctx.actions.declare_output(ctx.attrs.package + ".mojoc")
    natives = ctx.actions.declare_output("natives", dir = True)
    cmd = cmd_args(ctx.attrs.unpacker[DefaultInfo].default_outputs[0], ctx.attrs.conda[DefaultInfo].default_outputs[0], ctx.attrs.package, out.as_output(), "--natives", natives.as_output())
    for soname, archive in sorted(ctx.attrs.natives.items()):
        cmd.add("--native-from", cmd_args("{}=".format(soname), archive[DefaultInfo].default_outputs[0], delimiter = ""))
    ctx.actions.run(cmd, category = "mojo_conda_holds", identifier = ctx.label.name)
    return [DefaultInfo(default_output = out)]

_mojo_conda_holds = rule(
    impl = _holds_impl,
    attrs = {
        "conda": attrs.dep(),
        # `{"lib<id>.a": <the archive target>}`: the `.conda` must hold `lib/<soname>` with exactly the bytes of that target's file.
        "natives": attrs.dict(attrs.string(), attrs.dep(), default = {}),
        "package": attrs.string(),
        "unpacker": attrs.exec_dep(default = "buildrules//rules/mojo:prebuilt_unpack"),
    },
)

def mojo_conda_holds(**kwargs):
    """The `.conda` of `mojo_conda` holds each native library at `lib/<soname>` with the bytes the build made: unpacked by `prebuilt_unpack`, which refuses a
    member that is missing, empty, a link, or whose sha256 is not that of the file. Building it is the check."""
    _mojo_conda_holds(exec_compatible_with = LINUX_X86_64, **kwargs)
