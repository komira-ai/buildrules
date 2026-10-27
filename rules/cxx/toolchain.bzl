"""`cxx_toolchains()`: the hermetic C/C++ toolchain of the prelude's `cxx_library`, `cxx_binary`, driven by the pinned zig.

A consumer's toolchains/BUCK calls it (next to `rust_toolchains()`):

    load("@buildrules//rules/cxx:toolchain.bzl", "cxx_toolchains")
    cxx_toolchains()

It declares `toolchains//:cxx` (what the prelude's C/C++ rules look up), `:cxx_no_default_deps` (an alias the
prelude's select names in its unconfigured branch) and `:python_bootstrap` (a refusal, see below).

`zig_cxx_toolchain` provides the prelude's C/C++ toolchain providers (`cxx_toolchain_infos`), so `cxx_library`
works unchanged. Every tool it names is an input of the action that runs it, and no action has a PATH:

    compiler, assembler, archiver   `zig_cc_launcher <zig> cc|c++|ar|ranlib`  (pinned zig 0.12.0, rules/pins)
    nm, objcopy, strip              not provided: a refusal (exit 2) naming the tool
    prelude internal tools          not provided: a refusal (exit 2) naming the tool

The prelude's internal tools are Python programs; nothing here runs Python. The features that need them
(dependency files, diagnostics concatenation, compilation databases, header maps, remapping the working
directory, thin LTO) are off, so none is on the path of a compile, an archive or a link. A build that reaches
one fails with `cxx toolchain: <tool> is not provided` instead of searching the worker for it.

zig's clang targets `target` (a glibc-versioned triple, default x86_64-linux-gnu.2.34: the floor the Rust rules
link to) and `target_cpu` whatever worker runs it, and compiles with `-g0`. For a macOS arm64 target platform it targets `aarch64-macos` at zig's generic
arm64 CPU instead (the `macos` attribute, set by a `select` on the target platform): the same zig, on the same linux x86_64 execution platform, writes the object files
and the static archive of a member's native library; no executable or shared library is linked for macOS: debug info would record the
action's working directory. Compiles are position-independent (`-fPIC`), so one archive serves static and
static-pic links. The C++ standard library is zig's libc++, linked statically.
"""

load(
    "@prelude//cxx:cxx_toolchain_types.bzl",
    "AsCompilerInfo",
    "AsmCompilerInfo",
    "BinaryUtilitiesInfo",
    "CCompilerInfo",
    "CxxCompilerInfo",
    "CxxInternalTools",
    "DistLtoToolsInfo",
    "LinkerInfo",
    "LinkerType",
    "PicBehavior",
    "ShlibInterfacesMode",
    "cxx_toolchain_infos",
)
load("@prelude//cxx:headers.bzl", "HeaderMode")
load("@prelude//linking:link_info.bzl", "LinkStyle")
load("@prelude//python_bootstrap:python_bootstrap.bzl", "PythonBootstrapToolchainInfo")
load("//rules/core:platform.bzl", "LINUX_X86_64", "by_os_cpu")

def _refusal(bb, what):
    # A tool the toolchain does not provide. It is still a declared input (the busybox), so reaching it
    # fails the action with a message, never a search of the worker's PATH.
    return RunInfo(args = cmd_args(
        bb,
        "sh",
        "-c",
        "echo \"cxx toolchain: {} is not provided (see rules/cxx/toolchain.bzl)\" >&2; exit 2".format(what),
    ))

def _zig_tool(launcher, zig, sub):
    # `zig_cc_launcher` expands nested response files (zig refuses them) and gives zig a cache directory
    # relative to the action's working directory.
    return RunInfo(args = cmd_args(launcher, zig, sub))

def _zig_cxx_toolchain_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    zig = ctx.attrs.zig[DefaultInfo].default_outputs[0]
    launcher = ctx.attrs.launcher[DefaultInfo].default_outputs[0]
    cc = _zig_tool(launcher, zig, "cc")
    cxx = _zig_tool(launcher, zig, "c++")

    # Flags every compile gets, before the target's own. A macOS arm64 target (`macos`) compiles for `macos_target` at zig's generic arm64 CPU; every other
    # target is the linux one, as it was.
    target = ctx.attrs.macos_target if ctx.attrs.macos else ctx.attrs.target
    cpu = "generic" if ctx.attrs.macos else ctx.attrs.target_cpu.replace("-", "_")
    base = ["-target", target, "-mcpu=" + cpu, "-fPIC", "-g0"]
    c_info = CCompilerInfo(
        compiler = cc,
        compiler_type = "clang",
        compiler_flags = cmd_args(base, ctx.attrs.c_compiler_flags),
        preprocessor_flags = cmd_args(),
    )
    asm_info = AsmCompilerInfo(
        compiler = cc,
        compiler_type = "clang",
        compiler_flags = cmd_args(base),
        preprocessor_flags = cmd_args(),
    )
    as_info = AsCompilerInfo(
        compiler = cc,
        compiler_type = "clang",
        compiler_flags = cmd_args(base),
        preprocessor_flags = cmd_args(),
    )
    cxx_info = CxxCompilerInfo(
        compiler = cxx,
        compiler_type = "clang",
        compiler_flags = cmd_args(base, ctx.attrs.cxx_compiler_flags),
        preprocessor_flags = cmd_args(),
    )
    linker_type = LinkerType("gnu")
    linker_info = LinkerInfo(
        archiver = _zig_tool(launcher, zig, "ar"),
        archiver_type = "gnu",
        archiver_supports_argfiles = True,
        archive_objects_locally = False,
        binary_extension = "",
        generate_linker_maps = False,
        link_binaries_locally = False,
        link_libraries_locally = False,
        link_style = LinkStyle("static_pic"),
        link_weight = 1,
        # A macOS arm64 target gets no linker: the toolchain compiles and archives for it, and a link would write a linux program.
        linker = _refusal(bb, "a linker for macOS") if ctx.attrs.macos else cxx,
        # --strip-debug: zig cc assembles the C runtime start-up objects (crti, crtn, start) at LINK time with default debug info (`-g0` is a compile flag), and
        # the DWARF stamps DW_AT_comp_dir with the action's absolute working directory, so a binary would depend on the path it was linked in (examples/cxx).
        linker_flags = cmd_args("-target", target, "-Wl,--strip-debug"),
        object_file_extension = "o",
        shlib_interfaces = ShlibInterfacesMode("disabled"),
        shared_dep_runtime_ld_flags = [],
        shared_library_name_default_prefix = "lib",
        shared_library_name_format = "{}.so",
        shared_library_versioned_name_format = "{}.so.{}",
        static_dep_runtime_ld_flags = [],
        static_library_extension = "a",
        static_pic_dep_runtime_ld_flags = [],
        independent_shlib_interface_linker_flags = [],
        type = linker_type,
        use_archiver_flags = True,
        is_pdb_generated = False,
    )
    refuse = lambda what: _refusal(bb, what)
    internal_tools = CxxInternalTools(
        check_nonempty_output = refuse("check_nonempty_output"),
        clang_tidy_wrapper = refuse("clang_tidy_wrapper"),
        concatenate_diagnostics = refuse("concatenate_diagnostics"),
        dep_file_processor = refuse("dep_file_processor"),
        dist_lto = DistLtoToolsInfo(
            planner = {linker_type: refuse("dist_lto planner")},
            opt = {linker_type: refuse("dist_lto opt")},
            prepare = {linker_type: refuse("dist_lto prepare")},
            copy = refuse("dist_lto copy"),
            archive_mapper = refuse("dist_lto archive_mapper"),
            compiler_stats_merger = refuse("dist_lto compiler_stats_merger"),
        ),
        filter_argsfile = refuse("filter_argsfile"),
        hmap_wrapper = refuse("hmap_wrapper"),
        make_comp_db = refuse("make_comp_db"),
        remap_cwd = refuse("remap_cwd"),
        serialized_diagnostics_to_json_wrapper = refuse("serialized_diagnostics_to_json_wrapper"),
        stderr_to_file = refuse("stderr_to_file"),
        stub_header_unit = refuse("stub_header_unit"),
    )
    return [DefaultInfo()] + cxx_toolchain_infos(
        internal_tools = internal_tools,
        platform_name = "x86_64",
        c_compiler_info = c_info,
        cxx_compiler_info = cxx_info,
        asm_compiler_info = asm_info,
        as_compiler_info = as_info,
        linker_info = linker_info,
        binary_utilities_info = BinaryUtilitiesInfo(
            dwp = None,
            nm = refuse("nm"),
            objcopy = refuse("objcopy"),
            ranlib = _zig_tool(launcher, zig, "ranlib"),
            strip = refuse("strip"),
        ),
        header_mode = HeaderMode("symlink_tree_only"),
        # Every object is compiled once, position-independent (`-fPIC` above): the same archive serves
        # static and PIC links.
        pic_behavior = PicBehavior("always_enabled"),
        use_dep_files = False,
    )

zig_cxx_toolchain = rule(
    impl = _zig_cxx_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {
        "busybox": attrs.exec_dep(),
        "c_compiler_flags": attrs.list(attrs.string(), default = []),
        "cxx_compiler_flags": attrs.list(attrs.string(), default = []),
        # A `zig_exe` of rules/cxx/zig_cc_launcher.zig.
        "launcher": attrs.exec_dep(),
        # True when the target platform is macOS arm64 (a `select` in `cxx_toolchains`): the compile then targets `macos_target`, and `target` and `target_cpu` are not used.
        "macos": attrs.bool(default = False),
        # zig target triple of a macOS arm64 target: the C is cross-compiled by the pinned zig on the (linux) execution platform of this toolchain.
        "macos_target": attrs.string(default = "aarch64-macos"),
        # zig target triple, with the glibc floor, e.g. x86_64-linux-gnu.2.34.
        "target": attrs.string(),
        # zig's -mcpu without the dashes' meaning: `x86-64` is zig's baseline x86_64, `x86-64-v3` AVX2.
        "target_cpu": attrs.string(),
        "zig": attrs.exec_dep(),
    },
)

def _no_python_bootstrap_toolchain_impl(ctx):
    bb = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    return [
        DefaultInfo(),
        PythonBootstrapToolchainInfo(interpreter = cmd_args(
            bb,
            "sh",
            "-c",
            "echo 'python bootstrap toolchain: no Python interpreter is provided (see rules/cxx/toolchain.bzl)' >&2; exit 2",
            "sh",
        )),
    ]

# `toolchains//:python_bootstrap`. The prelude's `cxx_library` names a few Python helper programs as
# attributes, so configuring one needs this toolchain even though no action of a C/C++ compile, archive or
# link runs them. It provides no interpreter: a helper that does run fails, naming this file, instead of
# finding a Python on the worker.
no_python_bootstrap_toolchain = rule(
    impl = _no_python_bootstrap_toolchain_impl,
    is_toolchain_rule = True,
    attrs = {"busybox": attrs.exec_dep()},
)

def cxx_toolchains(
        target = "x86_64-linux-gnu.2.34",
        target_cpu = "x86-64",
        busybox = "buildrules//rules/pins:busybox",
        zig = "buildrules//rules/pins:zig",
        launcher = "buildrules//rules/cxx:zig_cc_launcher"):
    """Declare `:cxx`, `:cxx_no_default_deps` and `:python_bootstrap` in the calling package.

    Linux x86_64, and macOS arm64 for a static C library (`native_static`; the zig cross-compiles it). `target_cpu` is the CPU every compile targets, whatever worker runs it:
    the default is zig's baseline x86_64, so the result runs on any x86_64 worker.
    """
    zig_cxx_toolchain(
        name = "cxx",
        busybox = busybox,
        launcher = launcher,
        target = target,
        target_cpu = target_cpu,
        zig = zig,
        macos = by_os_cpu({"macos_aarch64": True, "DEFAULT": False}),
        # Linux x86_64 as before, and macOS arm64: the pinned zig (running on the linux execution platform) cross-compiles C for it.
        target_compatible_with = by_os_cpu({"macos_aarch64": [], "DEFAULT": LINUX_X86_64}),
        exec_compatible_with = LINUX_X86_64,
        visibility = ["PUBLIC"],
    )

    # The prelude's C/C++ rules take their toolchain from a select whose other branch, never taken in a
    # configured graph, is `toolchains//:cxx_no_default_deps`. An unconfigured query follows every branch
    # and fails on a label no package declares. `:cxx` adds no default deps, so the variant is `:cxx`.
    native.toolchain_alias(
        name = "cxx_no_default_deps",
        actual = ":cxx",
        visibility = ["PUBLIC"],
    )
    no_python_bootstrap_toolchain(
        name = "python_bootstrap",
        busybox = busybox,
        exec_compatible_with = LINUX_X86_64,
        visibility = ["PUBLIC"],
    )
