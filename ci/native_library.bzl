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
load("//examples/mojo/native_library:buildrules.mojo.lock.bzl", NATLIB_GRAPH = "GRAPH")
load("//examples/mojo/native_library_cuser:buildrules.mojo.lock.bzl", NATLIB_CUSER_GRAPH = "GRAPH")
load("//examples/mojo/native_library_deps:buildrules.mojo.lock.bzl", NATLIB_DEPS_GRAPH = "GRAPH")
load("//examples/mojo/sys_app:buildrules.mojo.lock.bzl", SYS_APP_GRAPH = "GRAPH")

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

# The link line of a Mojo test binary: what its toolchain.cfg says (rules/native/link.bzl, `link_cfg`). Per target: the `link_archive` lines it must have, in order, and the system
# libraries that end the line (`link_tail=-l<name>`, once each, after every archive): the `link` of the test's unit in the committed graph, which is mopm's field and the only
# source of them. A package whose graph has no `link` has no tail, whatever its archives are.
LINKS = [
    # The graph lists left, right, top. `left` and `right` share `shared_base`: once, after both; `top` has `mid` in `deps` and `mid` has `base`: after `top`. C libraries: no `link`, no tail.
    ("//examples/mojo/native_library_deps:test_natlib_deps__bin", ["libshared_base.a", "libmid.a", "libbase.a"], [], NATLIB_DEPS_GRAPH),
    # A C library over the C++ one: the archive of the C++ library comes through `deps`, and mopm's list names the C++ runtime and the three others, in its order.
    ("//examples/mojo/native_library_cuser:test_natlib_cuser__bin", ["libcxxlib.a"], ["c++", "dl", "m", "pthread"], NATLIB_CUSER_GRAPH),
    # The libraries are all named in `natives`, the C++ one among them: nothing to append, and `link = ["c++"]` of its `[native.cxxlib]`.
    ("//examples/mojo/native_library:test_natlib__bin", [], ["c++"], NATLIB_GRAPH),
    # A package of registry archives and no `link`: no tail either (its configuration is what it was before `link` existed).
    ("//examples/mojo/sys_app:test_sys_app__bin", [], [], SYS_APP_GRAPH),
]

def _cfg(ctx, node):
    for a in ctx.aquery().all_actions(node.label):
        if str(a.attrs.category) == "write" and str(a.attrs.identifier) == "toolchain.cfg":
            return [l for l in str(a.attrs.contents).strip('"').split("\n") if l]
    return None

def _test_unit(graph, target):
    stem = target.split(":")[-1][:-len("__bin")]
    for u in graph["units"]:
        if u["kind"] == "test" and u["outputs"][0] == stem + ".pass":
            return u
    return None

def native_link_cfg_problems(ctx):
    problems = []
    # Linux only: the configuration of a Mojo unit for macOS needs a macOS execution platform (a runner in local mode has none, and analysis refuses it); the lines are the same
    # for both, and the macOS run of the packages is //ci:mojo.
    for platform in [LINUX]:
        for target, archives, link, graph in LINKS:
            who = "{} on {}".format(target, platform)
            unit = _test_unit(graph, target)
            if unit == None:
                problems.append("{}: no test unit of that name in the committed graph".format(who))
                continue
            if unit.get("link", []) != link:
                problems.append("{}: the committed graph gives the test the link {}, not {}".format(who, unit.get("link", []), link))
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
            if tails != ["link_tail=-l" + n for n in link]:
                problems.append("{}: the link tail is {}, but the unit's link is {}".format(who, tails, link))
            last_archive = max([i for i, l in enumerate(cfg) if l.startswith("link_archive=")] + [-1])
            if tails and cfg.index(tails[0]) < last_archive:
                problems.append("{}: a system library comes before an appended archive: {}".format(who, cfg))
            # What `mopm unit build` is given: no `link` (the unit rule writes the tail, so mopm adds none, once after the archives and not twice), no `loads`, and a format that has
            # `provided` only when the slice holds a provided native unit.
            slice = json.decode(node.attrs_eager().graph.value())
            if [u["id"] for u in slice["units"] if "link" in u]:
                problems.append("{}: the unit's graph slice holds `link` on {}: mopm would add the libraries before the appended archives, and the tail would repeat them".format(who, [u["id"] for u in slice["units"] if "link" in u]))
            provided = any([u.get("provided", False) for u in slice["units"]])
            want = 4 if provided else 2
            if slice["unit_graph"] != want:
                problems.append("{}: the unit's graph slice is format {}, not {} (a slice with a provided native unit is format 4, any other format 2)".format(who, slice["unit_graph"], want))
    return problems
