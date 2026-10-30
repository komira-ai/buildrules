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

_PREFIX_KEYS = ["name", "strip", "min", "extra_symbols", "cxx_namespaces"]

def _identifier(s):
    return type(s) == "string" and len(s) > 0 and all([c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_" for c in s.elems()])

def check_prefix(who, pfx, refuse = fail):
    """The `prefix` table: every global symbol the library defines is renamed to start with `name` (`strip` selects the strip style); `min` is the least number of
    symbols the library defines, which stops a header made from the wrong archive."""
    if type(pfx) != "dict":
        refuse("{}: prefix is {}, a table of name, strip, min, extra_symbols and cxx_namespaces".format(who, repr(pfx)))
        return
    for k in sorted(pfx.keys()):
        if k not in _PREFIX_KEYS:
            refuse("{}: prefix has the key {}; the keys are {}".format(who, repr(k), ", ".join(_PREFIX_KEYS)))
            return
    if not _identifier(pfx.get("name")):
        refuse("{}: prefix name {} is not an identifier (letters, digits and _)".format(who, repr(pfx.get("name"))))
        return
    strip = pfx.get("strip", "")
    if strip != "" and not _identifier(strip):
        refuse("{}: prefix strip {} is not an identifier (letters, digits and _)".format(who, repr(strip)))
        return
    extra = pfx.get("extra_symbols", [])
    if type(extra) != "list" or any([not _identifier(x) for x in extra]):
        refuse("{}: prefix extra_symbols {} is a list of identifiers (names the library refers to and does not define, such as a weak hook a program defines)".format(who, repr(extra)))
        return
    spaces = pfx.get("cxx_namespaces", [])
    if type(spaces) != "list" or any([not _identifier(x) or x == "std" for x in spaces]):
        refuse("{}: prefix cxx_namespaces {} is a list of C++ namespaces (identifiers, never `std`) whose mangled names the library may define without the prefix: a header of macros cannot rename them".format(who, repr(spaces)))
        return
    least = pfx.get("min")
    if type(least) != "int" or least <= 0:
        refuse("{}: prefix min is the least number of symbols the library defines, a positive integer (it stops a header made from the wrong archive), got {}".format(who, repr(least)))

def check_has_sources(who, parts, refuse = fail):
    """A library has a source. `parts` are the lists `srcs` is made of (a list, and each arm of each `select()`): when none of them names a file, no platform has one, and
    the library would be an empty archive (the prelude refuses it with a message about a sub-target, not about the library). An arm that is empty beside others that are
    not is a library with no source on that platform, which the archive of that platform shows."""
    if not any([len(p) > 0 for p in parts]):
        refuse("{}: srcs names no file, in any arm of its select(): a native_library has at least one source (.c, .cc, .cpp, .cxx, .c++, .S, .s)".format(who))

def check_asm_split(who, patterns, srcs, refuse = fail):
    """`asm_split` names the sources whose preprocessed text has its `;` turned into line breaks before it is assembled (rules/cxx/asm_split.zig): by the beginning of the
    path (`s2n-bignum/arm/`). A source it names must be a `.S` file, the only kind that is preprocessed. `srcs` are the files of one resolved arm."""
    if type(patterns) != "list":
        refuse("{}: asm_split is {}, a list of path beginnings".format(who, repr(patterns)))
        return
    for p in patterns:
        if type(p) != "string" or not p or p.startswith("/") or ".." in p.split("/"):
            refuse("{}: asm_split {} is not the beginning of a path below the package or the upstream tree".format(who, repr(p)))
            return
    for s in srcs:
        if is_split(patterns, s) and not s.endswith(".S"):
            refuse("{}: asm_split names {}, which is not a .S file (only a .S file is preprocessed)".format(who, s))
            return

def is_split(patterns, src):
    """Whether `asm_split` names the source `src`."""
    return any([src.startswith(p) for p in patterns])

def check_asm_split_matched(who, patterns, parts, refuse = fail):
    """Every `asm_split` pattern names a source: `parts` are the lists `srcs` is made of (a list, and each arm of each `select()`). A pattern that begins no path of any of them
    (a typo: `s2n-bignum/arn/`) would leave the macros unsplit, which on Mach-O arm64 is a routine that assembles and computes the wrong thing."""
    for p in patterns:
        if not any([s.startswith(p) for part in parts for s in part]):
            refuse("{}: asm_split {} is the beginning of no source, in any arm of srcs: the sources it was meant to name are not split".format(who, repr(p)))
