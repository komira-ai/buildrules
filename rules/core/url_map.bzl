"""`buildrules.url_map`: a machine's mirror of pinned downloads.

`-c buildrules.url_map="<from-prefix>=<to-prefix> ..."` (in `.buckconfig.local`, never committed) replaces the leading part of a
download's URL, for every `pinned_file` (the zig, node, rust, conda and busybox pins, the mopm tarball, the Mojo packages).
It exists for a machine whose copy of a file is not where the pin says (a release that is not published yet, an offline
mirror). The sha256 and size of every download are still checked, so a mirror cannot change the bytes; it changes where they
are fetched from, and nothing in an action key.
"""

def map_url(m, url, refuse = fail):
    """`url` through the map `m` (the value of `buildrules.url_map`); a pair that is not `<from-prefix>=<to-prefix>` is refused (`refuse` is `fail`
    in a rule; a test passes a recorder, rules/rust/refusal.bzl) and skipped."""
    for pair in m.split():
        if "=" not in pair:
            refuse("buildrules.url_map: `{}` is not <from-prefix>=<to-prefix>".format(pair))
            continue
        src, dst = pair.split("=", 1)
        if url.startswith(src):
            return dst + url[len(src):]
    return url

def mapped_url(url):
    return map_url(read_config("buildrules", "url_map", ""), url)
