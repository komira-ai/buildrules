"""`pinned_file`: one sha256-pinned download. The only client-side operation.

Both the sha256 and the size are required. With both stated buck2 contacts the URL
only when the remote CAS lacks the blob; a wrong hash fails the download.

The URL goes through `buildrules.url_map` (url_map.bzl) when the machine sets one: where a file is
fetched from may change, the bytes may not (the sha256 is still checked). The beta stage uses that to
fetch the pins from their mirrors (docs/pins.md) after the primary host failed.
"""

load(":url_map.bzl", "mapped_url")

def check_pinned(who, sha256, size_bytes, refuse = fail):
    """A download is pinned by its sha256 (64 lower-case hex digits) and its length: anything else is refused, naming the target. `refuse` is `fail`
    in a rule; a test passes a recorder (rules/rust/refusal.bzl)."""
    if size_bytes <= 0:
        refuse("pinned_file {}: `size_bytes` must be the file's positive length in bytes".format(who))
    if len(sha256) != 64 or any([c not in "0123456789abcdef" for c in sha256.elems()]):
        refuse("pinned_file {}: `sha256` must be 64 lower-case hex digits, got {}".format(who, repr(sha256)))

def _impl(ctx):
    check_pinned(ctx.label, ctx.attrs.sha256, ctx.attrs.size_bytes)
    out = ctx.actions.declare_output(ctx.attrs.out or ctx.label.name, has_content_based_path = False)
    ctx.actions.download_file(
        out.as_output(),
        ctx.attrs.url,
        sha256 = ctx.attrs.sha256,
        size_bytes = ctx.attrs.size_bytes,
        is_executable = ctx.attrs.executable,
    )
    if ctx.attrs.executable:
        # An executable pin runs as itself (`$(exe ...)`, `buck2 run`).
        return [DefaultInfo(default_output = out), RunInfo(args = cmd_args(out))]
    return [DefaultInfo(default_output = out)]

_pinned_file = rule(
    impl = _impl,
    attrs = {
        "executable": attrs.bool(default = False),
        "out": attrs.option(attrs.string(), default = None),
        "sha256": attrs.string(),
        "size_bytes": attrs.int(),
        "url": attrs.string(),
    },
)

def pinned_file(url, **kwargs):
    """A sha256-pinned download of `url` (mapped by `buildrules.url_map` when the machine sets one)."""
    _pinned_file(url = mapped_url(url), **kwargs)
