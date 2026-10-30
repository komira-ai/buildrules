"""What `native_library` refuses while the graph is analysed, and the pure functions it computes with, as functions of plain values.

Each check takes the values it judges and `refuse`, which is `fail` in a rule; a test passes a recorder (rules/rust/refusal.bzl) and
reads what was refused (rules/native/tests/BUCK). Every message names the target, so a refusal says where to look.
"""

load("//rules/core:pinned_file.bzl", "check_pinned")

_KEYS = ["url", "sha256", "size", "strip", "files"]

# The formats `archive_files` unpacks, by the end of the name it is given.
ARCHIVE_EXTENSIONS = [".tar.gz", ".tgz", ".tar.xz", ".tar", ".zip"]

# A source is C++ by its extension; the language of the others is the C driver's (assembly: `.S` is preprocessed, `.s` is not).
CXX_SUFFIXES = (".cc", ".cpp", ".cxx", ".c++")
ASM_SUFFIXES = (".S", ".s")

def archive_extension(url):
    """The archive format a URL names, by the end of its file name (query and fragment left out), or None."""
    name = url.split("#")[0].split("?")[0].rsplit("/", 1)[-1]
    for e in ARCHIVE_EXTENSIONS:
        if name.endswith(e) and len(name) > len(e):
            return e
    return None

def relative(path):
    """A path below a directory: not empty, not absolute, with no empty, `.` or `..` segment, no backslash."""
    if not path or path.startswith("/") or "\\" in path:
        return False
    for seg in path.split("/"):
        if seg in ("", ".", ".."):
            return False
    return True

def check_upstream(who, up, refuse = fail):
    """The `upstream` table: a pinned https archive and the explicit list of the files staged out of it. Nothing outside `files` is staged."""
    if type(up) != "dict":
        refuse("{}: upstream is {}, a table of url, sha256, size, strip and files".format(who, repr(up)))
        return
    for k in sorted(up.keys()):
        if k not in _KEYS:
            refuse("{}: upstream has the key {}; the keys are {}".format(who, repr(k), ", ".join(_KEYS)))
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
    if type(strip) != "string" or (strip and not relative(strip)):
        refuse("{}: upstream strip {} is not a directory below the archive's root".format(who, repr(strip)))
        return
    files = up["files"]
    if type(files) != "list" or not files:
        refuse("{}: upstream files lists the files to stage (an archive's tree is not staged whole: a file nobody names is not an input)".format(who))
        return
    seen = {}
    for f in files:
        if type(f) != "string" or not relative(f):
            refuse("{}: upstream file {} is not a path below the archive".format(who, repr(f)))
            return
        if f in seen:
            refuse("{}: upstream file {} is listed twice".format(who, f))
            return
        seen[f] = True

SOURCE_KINDS = ["srcs", "hdrs", "exported_headers", "includes", "exported_includes"]

def check_sources(who, files, kind, value, refuse = fail):
    """One list of `native_library` (`kind`, one of `SOURCE_KINDS`), in one resolved branch (a `select()` is checked once per arm), against `files`, the upstream
    table's list (empty without one).

    A source is a file of the upstream tree when it is in `files`, else a file of the package. Headers of the package are `hdrs` and `exported_headers` (a list, or
    a dict of include names to files); a header of the tree is reached through `includes` and `exported_includes`, which are directories of the tree, so a header
    of the tree may not be named as one of the package's."""
    if kind not in SOURCE_KINDS:
        refuse("{}: {} is not one of the file lists {}".format(who, kind, ", ".join(SOURCE_KINDS)))
        return
    tree = {f: True for f in files}
    if kind == "srcs":
        for s in value:
            if type(s) != "string" or not relative(s):
                refuse("{}: src {} is not a path below the package or the upstream tree".format(who, repr(s)))
                return
            if not s.endswith(CXX_SUFFIXES + ASM_SUFFIXES + (".c",)):
                refuse("{}: src {} is not a C, C++ or assembly file (.c, .cc, .cpp, .cxx, .c++, .S, .s)".format(who, s))
                return
    elif kind in ("hdrs", "exported_headers"):
        for h in (value.values() if type(value) == "dict" else value):
            if type(h) != "string" or not relative(h):
                refuse("{}: {} {} is not a path below the package".format(who, kind, repr(h)))
                return
            if h in tree:
                refuse("{}: {} is a file of the upstream tree: a header of the tree is reached through includes or exported_includes, not named in {}".format(who, h, kind))
                return
    else:
        for d in value:
            if d == ".":
                if not files:
                    refuse("{}: {} names `.`, the upstream tree, and the target has no upstream".format(who, kind))
                    return
                continue
            if type(d) != "string" or not relative(d):
                refuse("{}: {} {} is `.` or a directory below the upstream tree".format(who, kind, repr(d)))
                return
            if not any([f.startswith(d + "/") for f in files]):
                refuse("{}: {} {} is not a directory that holds a file of upstream files".format(who, kind, repr(d)))
                return

def check_cxx_runtime(who, declared, cxx, refuse = fail):
    """`cxx_runtime`, when a target states it, is what its sources are: a library with a C++ source links the C++ runtime, and one without does not."""
    if declared != None and declared != cxx:
        refuse("{}: cxx_runtime = {} but {}".format(who, declared, "the sources include C++ (.cc, .cpp, .cxx, .c++)" if cxx else "no source is C++ (.cc, .cpp, .cxx, .c++)"))

def has_cxx_sources(srcs):
    return any([s.endswith(CXX_SUFFIXES) for s in srcs])

def link_order(own, dep_orders):
    """The archives of a link line: `own` first, then the archives of the dependencies in the order they are given, each archive once. An archive that several
    dependencies share stays after the last of its users (a library comes before the libraries it calls into). `dep_orders` are the dependencies' own link
    orders. Archives are compared by `key`: their path."""
    flat = [own]
    for order in dep_orders:
        flat.extend(order)
    last = {}
    for i, a in enumerate(flat):
        last[str(a)] = i
    return [a for i, a in enumerate(flat) if last[str(a)] == i]

def cxx_label(label):
    """The label of the `cxx_library` behind a `native_library` label: `<name>_cxx`, in the same package."""
    if ":" not in label:
        fail("native_library: dep {} is not a target label".format(repr(label)))
    return label + "_cxx"
