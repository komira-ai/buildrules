"""A Mojo package with a unit graph per conda subdir is configured for each platform and must be built from the graph of that platform (rules/mojo/subdirs.bzl).

There is no execution platform for linux aarch64 or macOS arm64 on the farm yet, so the gate is analysis: `examples/mojo/subdirs` is configured for the platform
of each subdir and what it was built from is read off the configured targets, not off the macro:

  - the graph its library unit is given names the toolchain of the platform's subdir (subdir, compiler triple, closure hash);
  - the toolchain it is built with is the toolchain target of that subdir;
  - the `.conda` it packs goes to that subdir's directory;
  - the whole library analyses on the platform (the toolchain of the subdir is declared and its closure rules analyse);
  - a platform with no graph (macOS on Intel) is refused, and the message names the graphs the package has (ci/negative.bzl CASES holds that).

`subdir_problems` is a part of ci/negative.bxl, which the public CI runs as a part of ci/completeness.bxl.
"""

load("//examples/mojo/subdirs:buildrules.mojo.lock.bzl", "GRAPHS")
load("//rules:platforms.bzl", "LINUX_ARM64_SKIPPED")
load(":exec_select.bzl", "host_refusal_ok")

PACKAGE = "//examples/mojo/subdirs"

# (target platform, conda subdir, compiler triple of the subdir, toolchain target). The ISA-level platform is linux x86_64 and chooses the graph of linux-64 too.
PLATFORMS = [
    ("buildrules//platforms:linux_x86_64", "linux-64", "x86_64-linux-gnu.2.34", "mojo_1_0_0"),
    ("buildrules//platforms:linux_x86_64_v3", "linux-64", "x86_64-linux-gnu.2.34", "mojo_1_0_0"),
    ("buildrules//platforms:linux_aarch64", "linux-aarch64", "aarch64-linux-gnu.2.34", "mojo_1_0_0_linux_aarch64"),
    ("buildrules//platforms:macos_aarch64", "osx-arm64", "aarch64-macos.11.0", "mojo_1_0_0_osx_arm64"),
]

LINUX_AARCH64_PLATFORM = "buildrules//platforms:linux_aarch64"

# The platform that matches no subdir, and what the refusal must say.
UNSUPPORTED = "buildrules//platforms:macos_x86_64"

def _attrs(ctx, label, platform):
    node = ctx.configured_targets(label, target_platform = platform)
    if node == None:
        return None  # incompatible: the linux arm64 switch is off (rules/platforms.bzl)
    # Not `resolved_attrs_eager`: it analyses the dependencies, which a platform whose host has no workers refuses (ci/exec_select.bzl).
    return node.attrs_eager()

def subdir_problems(ctx):
    """Every way a platform is not built from the graph, the toolchain and the `.conda` directory of its subdir: a list of strings, empty when all is as it must be."""
    problems = []
    for platform, subdir, triple, toolchain in PLATFORMS:
        who = "{} on {}".format(PACKAGE, platform)
        if subdir not in GRAPHS:
            problems.append("{}: the lock of the package has no graph for {}".format(who, subdir))
            continue
        lib = _attrs(ctx, PACKAGE + ":lib_ungated", platform)
        if lib == None:
            # Incompatible: the only platform that may be is linux aarch64, while `[buildrules_re] linux_arm64_enabled` is off. It is reported, never counted as held.
            if platform != LINUX_AARCH64_PLATFORM:
                problems.append("{}: the library is incompatible with the platform, which only linux aarch64 is while the linux arm64 switch is off".format(who))
            else:
                ctx.output.print("{}: {} (the graph, toolchain and .conda directory of {} are not checked)".format(who, LINUX_ARM64_SKIPPED, subdir))
            continue
        graph = json.decode(lib.graph.value())
        tc = graph["toolchain"]
        if tc["subdir"] != subdir:
            problems.append("{}: the library is built from the graph of {}, not of {}".format(who, tc["subdir"], subdir))
        if tc["cc_target"] != triple:
            problems.append("{}: the graph's compiler triple is {}, not {}".format(who, tc["cc_target"], triple))
        if tc["closure_sha256"] != GRAPHS[subdir]["toolchain"]["closure_sha256"]:
            problems.append("{}: the graph's toolchain closure is {}, not the one the lock records for {}".format(who, tc["closure_sha256"], subdir))
        if lib.toolchain.value().name != toolchain:
            problems.append("{}: the library is built with {}, not {}".format(who, lib.toolchain.value().name, toolchain))
        conda = _attrs(ctx, PACKAGE + ":conda", platform)
        if conda.subdir.value() != subdir:
            problems.append("{}: the .conda is packed for {}, not {}".format(who, conda.subdir.value(), subdir))
        test = _attrs(ctx, PACKAGE + ":test_tripled__bin", platform)
        if json.decode(test.graph.value())["toolchain"]["subdir"] != subdir:
            problems.append("{}: the test is built from the graph of {}, not of {}".format(who, json.decode(test.graph.value())["toolchain"]["subdir"], subdir))
        # The library analyses on the platform. On an Arm platform whose farm workers are not configured it is refused for that and says which key (ci/exec_select.bzl
        # holds the platform with the workers set, where it must analyse).
        why = host_refusal_ok(ctx, PACKAGE + ":lib_ungated", platform)
        if why != None:
            problems.append("{}: the library does not analyse: {}".format(who, why))
    return problems
