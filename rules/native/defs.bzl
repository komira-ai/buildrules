"""`native_library`: a C, C++ and assembly static library, from the package's files and a pinned upstream archive, built by the pinned zig for the target platform.

    native_library(
        name = "zlib",
        upstream = {"url": "https://zlib.net/fossils/zlib-1.3.1.tar.gz", "sha256": "...", "size": 1512791, "strip": "zlib-1.3.1", "files": ZLIB_FILES},
        srcs = ZLIB_SRCS,
        includes = ["."],
        exported_includes = ["."],
        cflags = ["-O3", "-DZ_HAVE_UNISTD_H"],
    )

builds, in the calling package:

    :zlib_upstream_download<ext>, :zlib_upstream   the pinned download, and the files of `upstream.files` as one tree (an input of every compile)
    :zlib_cxx                                      the `cxx_library` of the sources
    :zlib_archive                                  its `native_archive`: `libzlib.a`, behind the checks of rules/cxx/archive
    :zlib                                          the archive with `NativeLibraryInfo` (rules/cxx/providers.bzl)

and the default output of `:zlib` is the one static archive `libzlib.a`.

What each argument is, and what may differ per platform:

    upstream           a pinned tarball: `url` (https), `sha256`, `size` (bytes), `strip` (the directory every file is below), `files` (the explicit list staged; nothing else is).
    srcs               sources: a file of `upstream.files` (a path in the tree) or a file of the package. `.c`, `.cc .cpp .cxx .c++` (C++) and `.S .s` (assembly, assembled
                       by the pinned zig).
    hdrs               headers of the package the sources include (private).
    exported_headers   headers of the package a dependent includes: a list, or a dict `{"<include name>": "<file>"}`.
    includes           directories of the upstream tree given to this library's compiles as -I (`.` is the tree).
    exported_includes  directories of the upstream tree given to a dependent's compiles as -I, and to those of its dependents that re-export (`exported_deps`).
    cflags, cxxflags, asm_flags   flags of the C, the C++ and the assembly compiles, after the defaults (-O2), so a later -O3 wins.
    deps               other `native_library` targets: this library's compiles see their exported headers and includes, and their archives follow this one's on the link line.
    exported_deps      like `deps`, and a dependent of this library sees their exported headers too.
    cxx_runtime        optional statement of what the sources are: true when any source is C++ (a program that links the library then links the C++ runtime, once); a statement that
                       is not what the sources are is refused. The value is derived from the sources whether it is stated or not.
    soname             the archive's file name (default `lib<name>.a`).
    allow              symbols the archive check may find undefined (something it cannot see provides them).

`srcs`, `hdrs`, `exported_headers`, `includes`, `exported_includes`, `cflags`, `cxxflags` and `asm_flags` may each be a `select()` (or a list plus one) on the target platform's OS and CPU:
`buildrules//platforms:linux`, `:macos`, `:x86_64`, `:aarch64` are separate constraint values, and `:is_linux_x86_64`, `:is_macos_aarch64`, ... select a pair (platforms/BUCK).
Every arm is checked.

For macOS arm64 the pinned zig, on the linux execution platform, compiles for `aarch64-macos` at its generic arm64 CPU (rules/cxx/toolchain.bzl); the C++ runtime a program then links is the host's libc++.
"""

load("//rules:isa.bzl", "ISA_LEVELS", "isa_select")
load("//rules/core:pinned_file.bzl", "pinned_file")
load("//rules/core:platform.bzl", "LINUX_X86_64", "by_os_cpu")
load("//rules/cxx:archive.bzl", "archive_files")
load("//rules/cxx:native.bzl", "native_archive")
load(":checks.bzl", "archive_extension", "check_sources", "check_upstream", "cxx_label")
load(":library.bzl", "native_library_rule")

def _baseline():
    """The CPU flag of the platform's baseline (as rules/cxx/native.bzl): a library other people link must run on any machine of the family."""
    return by_os_cpu({
        "macos_aarch64": ["-mcpu=generic"],
        "DEFAULT": isa_select(lambda l: ["-mcpu=x86_64"] if ISA_LEVELS[l]["family"] == "x86_64" else ["-mcpu=generic"], ["-mcpu=x86_64"]),
    })

def _each(x, f):
    """`f` over the list or dict `x`, or over every arm of the `select()` it is (or is part of)."""
    if type(x) in ("selector", "Select", "select"):
        return select_map(x, f)
    return f(x)

def native_library(
        name,
        srcs = [],
        hdrs = [],
        exported_headers = [],
        includes = [],
        exported_includes = [],
        cflags = [],
        cxxflags = [],
        asm_flags = [],
        upstream = None,
        deps = [],
        exported_deps = [],
        cxx_runtime = None,
        soname = None,
        allow = [],
        validate = True,
        file_prefix = None,
        visibility = ["PUBLIC"]):
    who = "{}:{}".format(native.package_name(), name)
    files = []
    tree = None
    if upstream != None:
        check_upstream(who, upstream)
        files = list(upstream["files"])
        ext = archive_extension(upstream["url"])
        pinned_file(
            name = name + "_upstream_download" + ext,
            url = upstream["url"],
            sha256 = upstream["sha256"],
            size_bytes = upstream["size"],
        )
        archive_files(
            name = name + "_upstream",
            exec_compatible_with = LINUX_X86_64,
            archive = ":" + name + "_upstream_download" + ext,
            files = files,
            one_tree = True,
            strip_prefix = upstream.get("strip", ""),
            visibility = visibility,
        )
        tree = ":" + name + "_upstream"

    # Every arm of every list is checked, against the upstream files and the list's own kind.
    def checked(kind, value):
        def f(v):
            check_sources(who, files, kind, v)
            return v

        return _each(value, f)

    srcs = checked("srcs", srcs)
    hdrs = checked("hdrs", hdrs)
    exported_headers = checked("exported_headers", exported_headers)
    includes = checked("includes", includes)
    exported_includes = checked("exported_includes", exported_includes)

    def source_label(s):
        return "{}[{}]".format(tree, s) if s in files else s

    def tree_flags(dirs):
        return ["-I$(location {}){}".format(tree, "" if d == "." else "/" + d) for d in dirs]

    if file_prefix == None:
        file_prefix = native.package_name()

    # The compiler records the paths it was given (__FILE__, assert); the package and the tree are mapped to fixed names so a copy of the library built at another
    # path gives the same bytes.
    ffile = ["-ffile-prefix-map={}=.".format(file_prefix)] if file_prefix else []
    if tree:
        ffile.append("-ffile-prefix-map=$(location {})=upstream".format(tree))

    # Flags of a language come before the target's `compiler_flags`, which the prelude puts last, so the defaults are the first of each language's own.
    base = _baseline()
    c_flags = ["-O2", "-fno-sanitize=undefined"] + base + cflags
    cxx_flags = ["-O2", "-fno-sanitize=undefined", "-std=c++17"] + base + cxxflags
    asm_all = base + asm_flags

    native.cxx_library(
        name = name + "_cxx",
        srcs = _each(srcs, lambda l: [source_label(s) for s in sorted(l)]),
        headers = _each(hdrs, lambda l: sorted(l)),
        exported_headers = exported_headers,
        # A header is included by the name it is given (`exported_headers = {"zlib.h": ...}`); the prelude otherwise puts the package path in front.
        header_namespace = "",
        deps = [cxx_label(d) for d in deps],
        exported_deps = [cxx_label(d) for d in exported_deps],
        preprocessor_flags = ffile + _each(includes, tree_flags),
        exported_preprocessor_flags = _each(exported_includes, tree_flags),
        lang_compiler_flags = {
            "assembler": asm_all,
            "c_cpp_output": c_flags,
            "cxx_cpp_output": cxx_flags,
        },
        preferred_linkage = "static",
        visibility = visibility,
    )
    soname = soname or "lib{}.a".format(name)
    native_archive(
        name = name + "_archive",
        lib = ":" + name + "_cxx[static-pic]",
        soname = soname,
        sources = srcs,
        # The prelude archives the objects in the order of `srcs`, and a `select()` of lists cannot be sorted by the name of the object each makes.
        members_any = True,
        needs = deps + exported_deps,
        allow = allow,
        validate = validate,
        visibility = visibility,
    )
    native_library_rule(
        name = name,
        archive = ":" + name + "_archive",
        deps = deps,
        exported_deps = exported_deps,
        exported_includes = exported_includes,
        include_tree = tree,
        cxx_runtime = cxx_runtime,
        visibility = visibility,
    )
