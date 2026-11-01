"""`unpack_cmd`: the one way a rule runs the pinned `unpack` program (tools/bootstrap) on an archive.

An archive is unpacked only with its sha256 (the digest of the pinned download), its size, its format and a limit on the decompressed bytes it may hold. The rule states
all four and this function refuses a rule that leaves one out or states a malformed one, so an unpacking action cannot be written without the checks:

  - `sha256` and `size_bytes` make `unpack` refuse an archive that is not the pinned file before it reads a byte of it;
  - `format` makes it refuse a file that is not the format the rule expects (it is otherwise told by the file's magic);
  - `max_output` makes it refuse an archive that holds more decompressed bytes than the rule's measured need with headroom (a bomb stops at the limit).

Each rule documents where its `max_output` comes from. The program is a pinned download of this repository's release (rules/pins/bootstrap.bzl), chosen by the
execution platform (`//rules/pins:unpack`); no rule builds it, because the zig that builds everything is itself unpacked by it.
"""

_FORMATS = ["tar", "tar.gz", "tar.xz", "zip"]

def check_unpack(who, sha256, size_bytes, max_output, strip_components, format, refuse = fail):
    """Refuses (through `refuse`, `fail` in a rule) an unpacking action that lacks a check or states a malformed one."""
    if len(sha256) != 64 or any([c not in "0123456789abcdef" for c in sha256.elems()]):
        refuse("{}: `sha256` must be the archive's 64 lower-case hex digits, got {}".format(who, repr(sha256)))
    if size_bytes <= 0:
        refuse("{}: `size_bytes` must be the archive's positive length in bytes".format(who))
    if max_output <= 0:
        refuse("{}: `max_output` must be a positive number of decompressed bytes the archive may hold".format(who))
    if strip_components < 0:
        refuse("{}: `strip_components` must not be negative".format(who))
    if format not in _FORMATS:
        refuse("{}: `format` must be one of {}, got {}".format(who, ", ".join(_FORMATS), repr(format)))

def unpack_cmd(who, tool, archive, out, sha256, size_bytes, max_output, strip_components, format):
    """The command line that unpacks `archive` into the directory output `out`: `tool` is the `unpack` dependency, `who` names the target for a refusal."""
    check_unpack(who, sha256, size_bytes, max_output, strip_components, format)
    return cmd_args(
        tool[RunInfo],
        "--format",
        format,
        "--sha256",
        sha256,
        "--size",
        str(size_bytes),
        "--max-output",
        str(max_output),
        "--strip-components",
        str(strip_components),
        archive,
        out.as_output(),
    )

# The default of the `unpack` attribute (an `exec_dep`) of every rule that unpacks an archive: the program pinned for the execution platform. A rule also declares
# `sha256`, `size_bytes` and `max_output` with no defaults, so a target that leaves one out does not load.
UNPACK = "buildrules//rules/pins:unpack"

def _refused_impl(ctx):
    fail("no `unpack` is pinned for the execution platform of {}: the pins are {} (rules/pins/bootstrap.bzl). A rule that unpacks an archive runs the pinned program and has no other way to unpack, so this platform cannot run it.".format(ctx.label, ", ".join(ctx.attrs.hosts)))

# What `//rules/pins:unpack` resolves to on an execution platform with no pin: analysing it fails, naming the platform (the label's configuration) and the hosts that have one.
unpack_refused = rule(
    impl = _refused_impl,
    attrs = {
        "hosts": attrs.list(attrs.string()),
    },
)
