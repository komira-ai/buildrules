"""`buildrules.url_map`: a machine's mirror of pinned downloads.

`-c buildrules.url_map="<from-prefix>=<to-prefix> ..."` (in `.buckconfig.local`, never committed) replaces the leading part of a
download's URL, for the downloads the Mojo family declares (the mopm tarball, the Mojo toolchain packages, registry packages).
It exists for a machine whose copy of a file is not where the pin says (a release that is not published yet, an offline
mirror). The sha256 and size of every download are still checked, so a mirror cannot change the bytes; it changes where they
are fetched from, and nothing in an action key.
"""

def mapped_url(url):
    m = read_config("buildrules", "url_map", "")
    for pair in m.split():
        if "=" not in pair:
            fail("buildrules.url_map: `{}` is not <from-prefix>=<to-prefix>".format(pair))
        src, dst = pair.split("=", 1)
        if url.startswith(src):
            return dst + url[len(src):]
    return url
