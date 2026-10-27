"""A workspace member's own C library (`[native.<id>]`) is compiled for the target platform's kind (rules/cxx/native.bzl, rules/cxx/toolchain.bzl).

`examples/mojo/member_native_macos/cshim:native_shim_cxx` is configured for each platform and the commands of its actions are read off the configured target, not off
the macro:

  - on macOS arm64 (this package's constraint values, the prelude's, or both) the target is compatible, its C compile is the pinned zig's `cc` for `aarch64-macos` at
    zig's generic arm64 CPU, and its archive is written by the pinned zig's `ar`; no flag of the linux x86_64 baseline is on it;
  - on linux x86_64 (this package's constraint values or both vocabularies, and the ISA-level platform) the compile is the same zig `cc` for `x86_64-linux-gnu.2.34` at the x86-64 baseline, as
    it was before macOS arm64 was supported: no flag of the macOS target is on it.

`native_macos_problems` is a part of ci/negative.bxl, which the public CI runs as a part of ci/completeness.bxl.

The toolchain's linker follows the same platform: on macOS arm64 it is a refusal (the toolchain links no executable or shared library for it, and a link would write a linux program), on linux x86_64 it is zig's `c++`.
"""

load("@prelude//cxx:cxx_toolchain_types.bzl", "CxxToolchainInfo")

TOOLCHAIN = "toolchains//:cxx"
TARGET = "//examples/mojo/member_native_macos/cshim:native_shim_cxx"

# (target platform, the compiler triple its C is built for, the CPU flag the compile must carry last, the flags that must not be on it)
PLATFORMS = [
    ("buildrules//platforms:macos_aarch64", "aarch64-macos", "-mcpu=generic", ["-mcpu=x86_64", "x86_64-linux-gnu.2.34"]),
    ("//ci/platforms:prelude_macos_aarch64", "aarch64-macos", "-mcpu=generic", ["-mcpu=x86_64", "x86_64-linux-gnu.2.34"]),
    ("//ci/platforms:both_macos_aarch64", "aarch64-macos", "-mcpu=generic", ["-mcpu=x86_64", "x86_64-linux-gnu.2.34"]),
    ("buildrules//platforms:linux_x86_64", "x86_64-linux-gnu.2.34", "-mcpu=x86_64", ["aarch64-macos", "-mcpu=generic"]),
    ("buildrules//platforms:linux_x86_64_v3", "x86_64-linux-gnu.2.34", "-mcpu=x86_64", ["aarch64-macos", "-mcpu=generic"]),
    ("//ci/platforms:both_linux_x86_64", "x86_64-linux-gnu.2.34", "-mcpu=x86_64", ["aarch64-macos", "-mcpu=generic"]),
]

def _lines(contents):
    """The arguments of a written argsfile, one per line, without the quotes the prelude puts round some."""
    return [l.strip('"') for l in str(contents).strip('"').split("\n") if l]

def _facts(ctx, node):
    """What the actions behind `node[static-pic]` say: `(compile command, archive command, the toolchain's flags, the target's flags)`, each `None` or `[]` when absent.
    The compile reads its flags from a written argsfile (the toolchain's, the dependencies', the target's), whose contents are the `write` actions' own."""
    compile = None
    archive = None
    toolchain = []
    target = []
    deps = ctx.aquery().deps(ctx.aquery().all_actions(node.label.with_sub_target(["static-pic"])))
    for action in deps:
        kind = str(action.attrs.category)
        if kind == "c_compile" and compile == None:
            compile = str(action.attrs.cmd).lstrip("[").rstrip("]").split(", ")
        elif kind == "archive" and archive == None:
            archive = str(action.attrs.cmd).lstrip("[").rstrip("]").split(", ")
        elif kind == "write" and str(action.attrs.identifier) == ".c.toolchain_cxx_args":
            toolchain = _lines(action.attrs.contents)
        elif kind == "write" and str(action.attrs.identifier) == ".c.target_cxx_args":
            target = _lines(action.attrs.contents)
    return compile, archive, toolchain, target

def native_macos_problems(ctx):
    """Every way the C library of a member is not compiled for its target platform's kind: a list of strings, empty when all is as it must be."""
    problems = []
    for platform, triple, cpu, absent in PLATFORMS:
        who = "{} on {}".format(TARGET, platform)
        node = ctx.configured_targets(TARGET, target_platform = platform)
        if node == None:
            problems.append("{}: the C library is incompatible with the platform".format(who))
            continue
        compile, archive, toolchain, target = _facts(ctx, node)
        if compile == None or not toolchain or not target:
            problems.append("{}: no C compile with the toolchain's and the target's flags (compile {}, toolchain {}, target {})".format(who, compile, toolchain, target))
            continue
        # The launcher runs zig, and zig runs `cc`: the argument after the zig binary.
        if "cc" not in compile or not compile[1].endswith("/zig"):
            problems.append("{}: the C compile does not run the pinned zig's cc: {}".format(who, compile))
        if "-target" not in toolchain or toolchain[toolchain.index("-target") + 1] != triple:
            problems.append("{}: the C compile is not for {}: the toolchain's flags are {}".format(who, triple, toolchain))
        flags = toolchain + target
        cpus = [a for a in flags if a.startswith("-mcpu=")]
        if not cpus or cpus[-1] != cpu:
            problems.append("{}: the last -mcpu of the C compile is {}, not {}".format(who, cpus[-1] if cpus else "absent", cpu))
        for a in absent:
            if a in flags:
                problems.append("{}: the C compile carries {}, which belongs to the other kind of platform: {}".format(who, a, flags))
        if archive == None or "ar" not in archive or not archive[1].endswith("/zig"):
            problems.append("{}: the archive is not written by the pinned zig's ar: {}".format(who, archive))
        tc = ctx.configured_targets(TOOLCHAIN, target_platform = platform)
        if tc == None:
            problems.append("{}: the toolchain {} is incompatible with the platform".format(who, TOOLCHAIN))
            continue
        linker = str(ctx.analysis(tc).providers()[CxxToolchainInfo].linker_info.linker)
        refused = "is not provided" in linker
        if refused != triple.startswith("aarch64-macos"):
            problems.append("{}: the linker is {}, but it must be {}: {}".format(who, "a refusal" if refused else "a real one", "a refusal" if triple.startswith("aarch64-macos") else "a real one", linker))
    return problems
