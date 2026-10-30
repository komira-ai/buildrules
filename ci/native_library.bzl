"""`native_library` (rules/native/defs.bzl) is configured for its target platform: what its `select()`s chose, the flags of each language, and what it provides.

The facts are read off the configured targets, not off the macro: the actions behind `<name>_cxx[static-pic]` (their target argsfiles, one per source extension) and the
`NativeLibraryInfo` of the target.

  - `examples/native/asm:asm_add` has `native/asm_add_x86_64.S` on x86_64 and `native/asm_add_aarch64.S` on arm64 (a `select()` on the CPU constraint value alone), `-DASM_BIAS=7`
    on its assembly, and the toolchain's target of the platform's kind: `x86_64-linux-gnu.2.34` or `aarch64-macos`;
  - `examples/native/zlib:zlib` gets `-D_LARGEFILE64_SOURCE=1` on Linux and not on macOS (a `select()` on the OS), and its `-O3` after the default `-O2`, so it wins;
  - `examples/native/cxx:cxxlib` is compiled as `-std=c++17` with its own `cxxflags` after it; its provider says the C++ runtime is linked, and the C libraries' say it is not;
  - `examples/native/deps:top` (deps `mid`, which re-exports `base`) has the archives of its link in the order top, mid, base.

`native_library_problems` is a part of ci/negative.bxl, which the public CI runs as a part of ci/completeness.bxl.
"""

load("@buildrules//rules/cxx:providers.bzl", "NativeLibraryInfo")

LINUX = "buildrules//platforms:linux_x86_64"
MACOS = "buildrules//platforms:macos_aarch64"

_TRIPLE = {LINUX: "x86_64-linux-gnu.2.34", MACOS: "aarch64-macos"}

def _lines(contents):
    return [l.strip('"') for l in str(contents).strip('"').split("\n") if l]

def _args(ctx, target, platform):
    """`{extension: the lines of its target argsfile}`, `{extension: the lines of its toolchain argsfile}` and the identifiers of the compile actions."""
    node = ctx.configured_targets(target, target_platform = platform)
    if node == None:
        return None, None, None
    target_args = {}
    toolchain_args = {}
    compiles = []
    for a in ctx.aquery().deps(ctx.aquery().all_actions(node.label.with_sub_target(["static-pic"]))):
        kind = str(a.attrs.category)
        ident = str(a.attrs.identifier)
        if kind == "write" and ident.endswith(".target_cxx_args"):
            target_args[ident[:-len(".target_cxx_args")]] = _lines(a.attrs.contents)
        elif kind == "write" and ident.endswith(".toolchain_cxx_args"):
            toolchain_args[ident[:-len(".toolchain_cxx_args")]] = _lines(a.attrs.contents)
        elif kind in ("c_compile", "cxx_compile", "asm_compile"):
            compiles.append(str(a.attrs.identifier))
    return target_args, toolchain_args, compiles

def _before(flags, first, second):
    return first in flags and second in flags and flags.index(first) < len(flags) - 1 - flags[::-1].index(second)

def native_library_problems(ctx):
    """Every way `native_library` is not as its examples say: a list of strings, empty when all is as it must be."""
    problems = []
    for platform in [LINUX, MACOS]:
        triple = _TRIPLE[platform]

        # asm: the source the CPU chose, the flags of the assembly, the toolchain's target.
        who = "examples/native/asm:asm_add on {}".format(platform)
        target, toolchain, compiles = _args(ctx, "//examples/native/asm:asm_add_cxx", platform)
        if target == None:
            problems.append("{}: incompatible with the platform".format(who))
        else:
            want, other = ("asm_add_x86_64.S", "asm_add_aarch64.S") if platform == LINUX else ("asm_add_aarch64.S", "asm_add_x86_64.S")
            if not any([want in c for c in compiles]):
                problems.append("{}: no compile of {}: {}".format(who, want, compiles))
            if any([other in c for c in compiles]):
                problems.append("{}: compiles {}, the source of the other CPU: {}".format(who, other, compiles))
            if "-DASM_BIAS=7" not in target.get(".S", []):
                problems.append("{}: the assembly is not given -DASM_BIAS=7 (asm_flags): {}".format(who, target.get(".S")))
            if "-DASM_BIAS=7" in target.get(".c", []):
                problems.append("{}: the C is given the flags of the assembly: {}".format(who, target.get(".c")))
            tc = toolchain.get(".S", [])
            if "-target" not in tc or tc[tc.index("-target") + 1] != triple:
                problems.append("{}: the assembly is not for {}: {}".format(who, triple, tc))

        # zlib: a select on the OS alone, and the user's -O3 after the default -O2.
        who = "examples/native/zlib:zlib on {}".format(platform)
        target, toolchain, compiles = _args(ctx, "//examples/native/zlib:zlib_cxx", platform)
        if target == None:
            problems.append("{}: incompatible with the platform".format(who))
        else:
            flags = target.get(".c", [])
            large = "-D_LARGEFILE64_SOURCE=1" in flags
            if large != (platform == LINUX):
                problems.append("{}: -D_LARGEFILE64_SOURCE=1 is {} but the OS is {}: {}".format(who, "on" if large else "absent", "Linux" if platform == LINUX else "macOS", flags))
            if not _before(flags, "-O2", "-O3"):
                problems.append("{}: -O3 does not come after the default -O2, so -O2 would win: {}".format(who, flags))

        # C++: the standard, then the target's own flags.
        who = "examples/native/cxx:cxxlib on {}".format(platform)
        target, toolchain, compiles = _args(ctx, "//examples/native/cxx:cxxlib_cxx", platform)
        if target == None:
            problems.append("{}: incompatible with the platform".format(who))
        else:
            flags = target.get(".cc", [])
            if not _before(flags, "-std=c++17", "-fno-omit-frame-pointer"):
                problems.append("{}: the C++ compile is not -std=c++17 and then the cxxflags: {}".format(who, flags))
            tc = toolchain.get(".cc", [])
            if "-target" not in tc or tc[tc.index("-target") + 1] != triple:
                problems.append("{}: the C++ is not for {}: {}".format(who, triple, tc))

        # What the targets provide.
        def info(target):
            node = ctx.configured_targets(target, target_platform = platform)
            return ctx.analysis(node).providers()[NativeLibraryInfo]

        cxx = info("//examples/native/cxx:cxxlib")
        if not cxx.cxx_runtime:
            problems.append("examples/native/cxx:cxxlib on {}: the provider does not say the C++ runtime is linked".format(platform))
        for c in ["//examples/native/asm:asm_add", "//examples/native/zlib:zlib", "//examples/native/deps:top"]:
            if info(c).cxx_runtime:
                problems.append("{} on {}: the provider says the C++ runtime is linked, and no source is C++".format(c, platform))
        names = [str(a).split("build artifact ")[-1].split(" ")[0] for a in info("//examples/native/deps:top").archives]
        if [n for n in names] != ["libtop.a", "libmid.a", "libbase.a"]:
            problems.append("examples/native/deps:top on {}: the archives of the link are {}, not libtop.a, libmid.a, libbase.a".format(platform, names))
        if len(info("//examples/native/zlib:zlib").include_dirs) != 1:
            problems.append("examples/native/zlib:zlib on {}: the exported include directories are {}, not the one directory of the tree".format(platform, info("//examples/native/zlib:zlib").include_dirs))
        if len(info("//examples/native/deps:top").include_dirs) != 0:
            problems.append("examples/native/deps:top on {}: it exports include directories of a tree it has none of".format(platform))
    return problems

# The link line of a Mojo test binary: what its toolchain.cfg says (rules/native/link.bzl, `link_cfg`). Per target: the `link_archive` lines it must have, in order, and whether it
# ends with the C++ runtime.
LINKS = [
    # The graph lists left, right, top. `left` and `right` share `shared_base`: once, after both; `top` has `mid` in `deps` and `mid` has `base`: after `top`. C libraries: no runtime.
    ("//examples/mojo/native_library_deps:test_natlib_deps__bin", ["libshared_base.a", "libmid.a", "libbase.a"], False),
    # A C library over the C++ one: the archive of the C++ library and the runtime come through `deps`.
    ("//examples/mojo/native_library_cuser:test_natlib_cuser__bin", ["libcxxlib.a"], True),
    # The libraries are all named in `natives`, the C++ one among them: nothing to append, and the runtime.
    ("//examples/mojo/native_library:test_natlib__bin", [], True),
]

def _cfg(ctx, node):
    for a in ctx.aquery().all_actions(node.label):
        if str(a.attrs.category) == "write" and str(a.attrs.identifier) == "toolchain.cfg":
            return [l for l in str(a.attrs.contents).strip('"').split("\n") if l]
    return None

def native_link_cfg_problems(ctx):
    problems = []
    for platform in [LINUX, MACOS]:
        for target, archives, cxx in LINKS:
            who = "{} on {}".format(target, platform)
            node = ctx.configured_targets(target, target_platform = platform)
            if node == None:
                problems.append("{}: incompatible with the platform".format(who))
                continue
            cfg = _cfg(ctx, node)
            if cfg == None:
                problems.append("{}: no toolchain.cfg among its actions".format(who))
                continue
            got = [l[len("link_archive=link_archives/000_"):] for l in cfg if l.startswith("link_archive=link_archives/")]
            if got != archives:
                problems.append("{}: the archives appended to the link line are {}, not {}".format(who, got, archives))
            tails = [l for l in cfg if l.startswith("link_tail=")]
            if tails != (["link_tail=-lc++"] if cxx else []):
                problems.append("{}: the link tail is {}, but the link {} the C++ runtime".format(who, tails, "needs" if cxx else "does not need"))
            if cxx and "link_tail=-lc++" in cfg and cfg.index("link_tail=-lc++") < max([i for i, l in enumerate(cfg) if l.startswith("link_archive=")] + [-1]):
                problems.append("{}: the C++ runtime comes before an appended archive: {}".format(who, cfg))
    return problems
