"""A stand-in for the pinned multi-call binary (the applets `archive_files` runs) whose `stat -c %h` prints a word of our choosing (or nothing), so `archive_files` can be shown
to refuse a file whose names it cannot count.

The target it declares is a directory holding `applets` (ci/faulty/applets.zig), the pinned binary under its own file name and `stat_output`, with `applets` as its output; the action that
uses it has the whole directory. Every applet is the pinned one's, except `stat -c %h`. It is a Linux fixture.
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/cxx:archive.bzl", "archive_files")

def _impl(ctx):
    real = ctx.attrs.real[DefaultInfo].default_outputs[0]
    shim = ctx.attrs.shim[DefaultInfo].default_outputs[0]
    text = ctx.actions.write("stat_output", ctx.attrs.output)
    dir = ctx.actions.copied_dir("dir", {"applets": shim, real.basename: real, "stat_output": text})
    return [DefaultInfo(default_output = dir.project("applets"), other_outputs = [dir])]

_applets_without_link_counts = rule(impl = _impl, attrs = {
    # What `stat -c %h` prints: nothing, or a word that is not a number.
    "output": attrs.string(),
    "real": attrs.exec_dep(default = "buildrules//rules/pins:busybox"),
    "shim": attrs.exec_dep(default = "buildrules//ci/faulty:applets"),
})

def applets_without_link_counts(**kwargs):
    _applets_without_link_counts(exec_compatible_with = LINUX_X86_64, **kwargs)

def archive_files_over_applets(case, output):
    """`archive_files_with_<case>`: the file `copy.c` of the control archive of ci/faulty/BUCK, staged by applets whose `stat -c %h` prints `output` (target `applets_printing_<case>`)."""
    applets_without_link_counts(name = "applets_printing_" + case, output = output)
    archive_files(
        name = "archive_files_with_" + case,
        archive = ":archive_control.tar.gz",
        busybox = ":applets_printing_" + case,
        files = ["copy.c"],
        strip_prefix = "pkg",
    )
