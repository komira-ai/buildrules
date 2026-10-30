"""`native_build` of `mojo_package`: how a native library of the package is built beyond the sources in its directory (docs/contract.md, section 12, "Native libraries").

    mojo_package(
        path = ".",
        native_build = {
            "sqlite": {
                "upstream": {
                    "url": "https://www.sqlite.org/2026/sqlite-autoconf-3530400.tar.gz",
                    "sha256": "<64 hex digits>",
                    "size": 3283177,
                    "strip": "sqlite-autoconf-3530400",
                    "files": ["sqlite3.c", "sqlite3.h"],
                },
                "prefix": {"name": "pkg_sqlite3_", "strip": "sqlite3_", "min": 200},
            },
        },
    )

The key is the id of a `[native.<id>]` of the package's manifest; the package still lists the sources it owns in `srcs` (mopm requires one), and the entry adds to them.

    upstream   the library's sources are a pinned archive and not files of the package. `url`, `sha256` and `size` (bytes) pin the download (rules/core/pinned_file.bzl);
               `strip` is the directory every file is below in the archive; `files` are the files staged, as one tree and at their paths below `strip`, an input of every
               compile of the library; `srcs` (of `files`) are compiled with the package's own `srcs`; `includes` (default: `.`, the tree) are the `-I` directories.
               The package's own source can also include a staged file (`#include "sqlite3.c"` with the tree on `-I`), which is how a library that is one file keeps its
               compile flags in the manifest.
    prefix     every global symbol the library defines is renamed to start with `name` (rules/cxx/README.md, "Symbol prefixing"): a library bundled into a program does not
               clash with another copy of itself in the process. `strip` selects the style (`sqlite3_open` becomes `pkg_sqlite3_open` for `strip = "sqlite3_"`; any other
               symbol gets `name + "_"` ahead of it), `min` is the least number of symbols the library must define.
    allow      symbols the archive check may leave undefined (a symbol the C library of the target has and its list of them lacks).

Every refusal is made when the graph is analysed and names the package and the native library. They are plain functions of values (`refuse` is `fail` in a rule), so
rules/mojo/tests holds each one as an analysis test.
"""

load("//rules/core:pinned_file.bzl", "check_pinned", "pinned_file")
load("//rules/core:platform.bzl", "LINUX_X86_64")
load("//rules/cxx:archive.bzl", "archive_files")

_KEYS = ["upstream", "prefix", "allow"]
_UPSTREAM_KEYS = ["url", "sha256", "size", "strip", "files", "srcs", "includes"]
_PREFIX_KEYS = ["name", "strip", "min"]

# The formats `archive_files` unpacks, by the end of the name it is given.
ARCHIVE_EXTENSIONS = [".tar.gz", ".tgz", ".tar.xz", ".tar", ".zip"]

def archive_extension(url):
    """The archive format a URL names, by the end of its file name (query and fragment left out), or None."""
    name = url.split("#")[0].split("?")[0].rsplit("/", 1)[-1]
    for e in ARCHIVE_EXTENSIONS:
        if name.endswith(e) and len(name) > len(e):
            return e
    return None

def _relative(path):
    """A path below a directory: not empty, not absolute, with no empty, `.` or `..` segment."""
    if not path or path.startswith("/") or "\\" in path:
        return False
    for seg in path.split("/"):
        if seg in ("", ".", ".."):
            return False
    return True

def _identifier(s):
    return len(s) > 0 and all([c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_" for c in s.elems()])

def _unknown(who, what, got, known, refuse):
    for k in sorted(got):
        if k not in known:
            refuse("{}: {} has the key {}; the keys are {}".format(who, what, repr(k), ", ".join(known)))
            return True
    return False

def _check_upstream(who, up, refuse):
    if type(up) != "dict":
        refuse("{}: upstream is {}, a table of url, sha256, size, strip, files, srcs and includes".format(who, repr(up)))
        return
    if _unknown(who, "upstream", up.keys(), _UPSTREAM_KEYS, refuse):
        return
    for k in ["url", "sha256", "size", "files"]:
        if k not in up:
            refuse("{}: upstream has no {}".format(who, k))
            return
    url = up["url"]
    if type(url) != "string" or not url.startswith("https://"):
        refuse("{}: upstream url {} is not an https:// URL".format(who, repr(url)))
        return
    if archive_extension(url) == None:
        refuse("{}: upstream url {} does not name an archive: its file name ends in none of {}".format(who, url, ", ".join(ARCHIVE_EXTENSIONS)))
        return
    if type(up["sha256"]) != "string" or type(up["size"]) != "int":
        refuse("{}: upstream sha256 is a string of 64 hex digits and size an integer of bytes".format(who))
        return
    check_pinned("{} (upstream)".format(who), up["sha256"], up["size"], refuse)
    strip = up.get("strip", "")
    if type(strip) != "string" or (strip and not _relative(strip)):
        refuse("{}: upstream strip {} is not a directory below the archive's root".format(who, repr(strip)))
        return
    files = up["files"]
    if type(files) != "list" or not files:
        refuse("{}: upstream files lists the files to stage (an archive's tree is not staged whole: a file nobody names is not an input)".format(who))
        return
    seen = {}
    for f in files:
        if type(f) != "string" or not _relative(f):
            refuse("{}: upstream file {} is not a path below the archive".format(who, repr(f)))
            return
        if f in seen:
            refuse("{}: upstream file {} is listed twice".format(who, f))
            return
        seen[f] = True
    for s in up.get("srcs", []):
        if s not in seen:
            refuse("{}: upstream src {} is not among its files".format(who, repr(s)))
            return
    for d in up.get("includes", ["."]):
        if d == ".":
            continue
        if type(d) != "string" or not _relative(d) or not any([f.startswith(d + "/") for f in files]):
            refuse("{}: upstream include {} is `.` or a directory that holds a staged file".format(who, repr(d)))
            return

def _check_prefix(who, pfx, refuse):
    if type(pfx) != "dict":
        refuse("{}: prefix is {}, a table of name, strip and min".format(who, repr(pfx)))
        return
    if _unknown(who, "prefix", pfx.keys(), _PREFIX_KEYS, refuse):
        return
    name = pfx.get("name")
    if type(name) != "string" or not _identifier(name):
        refuse("{}: prefix name {} is not an identifier (letters, digits and _)".format(who, repr(name)))
        return
    strip = pfx.get("strip", "")
    if type(strip) != "string" or (strip and not _identifier(strip)):
        refuse("{}: prefix strip {} is not an identifier (letters, digits and _)".format(who, repr(strip)))
        return
    least = pfx.get("min")
    if type(least) != "int" or least <= 0:
        refuse("{}: prefix min is the least number of symbols the library defines, a positive integer (it stops a header made from the wrong archive), got {}".format(who, repr(least)))

def check_native_build(who, spec, native_ids, refuse = fail):
    """The refusals about `native_build` (the attribute of `mojo_package`) of the package `who`, whose own native libraries are `native_ids`."""
    if type(spec) != "dict":
        refuse("{}: native_build is {}, a dict by the id of a native library".format(who, repr(spec)))
        return
    for nid in sorted(spec.keys()):
        here = "{} native_build[{}]".format(who, repr(nid))
        if nid not in native_ids:
            refuse("{}: {} is not a native library of this package's graph ({})".format(here, repr(nid), ", ".join(sorted(native_ids)) or "it has none"))
            return
        entry = spec[nid]
        if type(entry) != "dict":
            refuse("{}: the entry is {}, a table of upstream, prefix and allow".format(here, repr(entry)))
            return
        if _unknown(here, "the entry", entry.keys(), _KEYS, refuse):
            return
        if "upstream" in entry:
            _check_upstream(here, entry["upstream"], refuse)
        if "prefix" in entry:
            _check_prefix(here, entry["prefix"], refuse)
        for a in entry.get("allow", []):
            if type(a) != "string" or not a:
                refuse("{}: allow lists symbol names, got {}".format(here, repr(a)))
                return

def stage_upstream(name, up, visibility):
    """The pinned download of `up` and the tree of its files: targets `<name>_download<ext>` and `<name>` (an `archive_files` with `one_tree`, whose
    sub-targets are the files and the directories of `includes`). Returns what `native_static` takes: the label, the sources and the include names."""
    files = up["files"]
    include_dirs = [d for d in up.get("includes", ["."]) if d != "."]
    pinned_file(
        name = name + "_download" + archive_extension(up["url"]),
        url = up["url"],
        sha256 = up["sha256"],
        size_bytes = up["size"],
    )
    archive_files(
        name = name,
        exec_compatible_with = LINUX_X86_64,
        archive = ":" + name + "_download" + archive_extension(up["url"]),
        files = files,
        one_tree = True,
        strip_prefix = up.get("strip", ""),
        tree_dirs = include_dirs,
        visibility = visibility,
    )
    return {
        "upstream": ":" + name,
        "upstream_includes": list(up.get("includes", ["."])),
        "upstream_srcs": list(up.get("srcs", [])),
    }
