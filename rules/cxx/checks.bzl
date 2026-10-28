"""What the C/C++ rules refuse at analysis (archive.bzl), as functions of plain values.

Each check takes the values it judges and `refuse`, which is `fail` in a rule: the build stops at the first refusal, with its message. A test passes a
recorder instead (rules/rust/refusal.bzl) and reads what was refused (rules/cxx/tests).
"""

def check_tree_dirs(who, one_tree, tree_dirs, refuse = fail):
    """`tree_dirs` are sub-targets of the one tree, so they need `one_tree = True`."""
    if tree_dirs and not one_tree:
        refuse("{}: tree_dirs needs one_tree = True".format(who))

def check_listed_once(who, name, taken, refuse = fail):
    """A file or template is listed once: `name` is a sub-target, and `taken` holds the sub-targets so far."""
    if name in taken:
        refuse("{}: {} is listed twice".format(who, name))

# The language of a native static library (rules/cxx/native.bzl): `c` or `c++`, the standard it is compiled to, and the file names that language takes.
NATIVE_LANGS = ["c", "c++"]

_C_STDS = ["c99", "c11", "c17", "c23", "gnu99", "gnu11", "gnu17", "gnu23"]
_CXX_STDS = ["c++11", "c++14", "c++17", "c++20", "c++23", "gnu++11", "gnu++14", "gnu++17", "gnu++20", "gnu++23"]
_CXX_SUFFIXES = [".cc", ".cpp", ".cxx", ".c++", ".cp", ".C"]

def is_cxx_source(path):
    """A file name the compiler takes as C++ (the extension decides, as it does for the compiler)."""
    for s in _CXX_SUFFIXES:
        if path.endswith(s):
            return True
    return False

def check_native_lang(who, lang, std, srcs, refuse = fail):
    """`lang` is `c` or `c++`; `std` (None: the compiler's default) is a standard of that language; a C library has no C++ source, because the C++ runtime is what
    only a C++ library may leave undefined (`archive_check --lang`). `srcs` are all the library's source paths."""
    if lang not in NATIVE_LANGS:
        refuse("{}: lang is {}; a native library is `c` or `c++`".format(who, repr(lang)))
        return
    if std != None and std not in (_CXX_STDS if lang == "c++" else _C_STDS):
        refuse("{}: std {} is not a standard of {} (one of {})".format(who, repr(std), lang, ", ".join(_CXX_STDS if lang == "c++" else _C_STDS)))
    if lang == "c":
        for s in srcs:
            if is_cxx_source(s):
                refuse("{}: {} is C++ source in a library whose lang is `c`: the C++ runtime is not part of what a C library may leave undefined; set lang = \"c++\"".format(who, s))

_SOURCE_KEYS = ["url", "sha256", "size_bytes", "strip_prefix", "srcs", "hdrs", "includes"]

def check_native_source(who, source, refuse = fail):
    """The pinned source archive of a native library: a dict of `url`, `sha256`, `size_bytes` (the pin; rules/core/pinned_file.bzl checks the digest and size),
    `strip_prefix` (the archive's top directory, default none), `srcs` (at least one, paths in the archive after the prefix), `hdrs` (more files of the archive the
    sources include) and `includes` (directories of the archive added to the include path). A path stays below the archive's root."""
    for k in sorted(source.keys()):
        if k not in _SOURCE_KEYS:
            refuse("{}: source has the key {}; the keys are {}".format(who, repr(k), ", ".join(_SOURCE_KEYS)))
    for k in ["url", "sha256", "size_bytes", "srcs"]:
        if k not in source:
            refuse("{}: source has no `{}`".format(who, k))
    if "srcs" in source and not source["srcs"]:
        refuse("{}: source.srcs is empty: a library built from an archive names the files of it that it compiles".format(who))
    if "url" in source and not (source["url"].startswith("https://") and (source["url"].endswith(".tar.gz") or source["url"].endswith(".tgz") or source["url"].endswith(".tar.xz") or source["url"].endswith(".zip"))):
        refuse("{}: source.url {} must be an https URL of a .tar.gz, .tgz, .tar.xz or .zip".format(who, repr(source["url"])))
    listed = {}
    for k in ["srcs", "hdrs", "includes"]:
        for p in source.get(k, []):
            if not p or p.startswith("/") or ".." in p.split("/") or p in (".", "./"):
                refuse("{}: source.{} entry {} must be a path below the archive's root (no leading /, no .., not the root itself)".format(who, k, repr(p)))
            elif k != "includes":
                if p in listed:
                    refuse("{}: {} is listed twice in source".format(who, p))
                listed[p] = True
