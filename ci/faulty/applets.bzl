"""A stand-in for the pinned multi-call binary (the applets `archive_files` runs) whose `stat -c %h` prints a word of our choosing (or nothing), so `archive_files` can be shown to refuse a file whose names it cannot count.

The target it declares is a script. Run as the binary itself it does what the pinned binary does, except that `--install -s <dir>` links every applet to the script and not to the
pinned binary; run under the name of an applet it does the applet, except `stat -c %h`, which prints `output` and succeeds. The pinned binary is its other output, so the action that
uses the script has it too. It is a Linux fixture: the script is run by the worker's own `/bin/sh`.
"""

load("//rules/core:platform.bzl", "LINUX_X86_64")

def _impl(ctx):
    real = ctx.attrs.real[DefaultInfo].default_outputs[0]
    lines = [
        "#!/bin/sh",
        'name="${0##*/}"',
        'if [ "$name" = stat ] && [ "$1" = -c ] && [ "$2" = %h ]; then echo "' + ctx.attrs.output + '"; exit 0; fi',
        'if [ "$name" = applets ]; then',
        '  if [ "$1" = --install ]; then',
        cmd_args("   ", real, "--list | while read applet; do", real, 'ln -s "$0" "$3/$applet"; done; exit 0', delimiter = " "),
        "  fi",
        cmd_args("  exec", real, '"$@"', delimiter = " "),
        "fi",
        cmd_args("exec", real, '"$name" "$@"', delimiter = " "),
        "",
    ]
    script, _ = ctx.actions.write("applets", cmd_args(lines, delimiter = "\n"), is_executable = True, allow_args = True)
    return [DefaultInfo(default_output = script, other_outputs = [real])]

_applets_without_link_counts = rule(impl = _impl, attrs = {
    # What `stat -c %h` prints: nothing, or a word that is not a number.
    "output": attrs.string(),
    "real": attrs.exec_dep(default = "buildrules//rules/pins:busybox"),
})

def applets_without_link_counts(**kwargs):
    _applets_without_link_counts(exec_compatible_with = LINUX_X86_64, **kwargs)
