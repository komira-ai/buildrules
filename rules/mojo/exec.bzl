"""Where the actions of a Mojo package run: on the execution platform of the target platform's kind (docs/contract.md, sections 12 and 14).

Mojo cannot cross-compile a `.mojoc`, so a package built for linux aarch64 is compiled on a linux aarch64 worker and one built for macOS arm64 on a macOS arm64
worker; linux x86_64 (at any ISA level) and every platform with no worker of its own stay on linux x86_64, with the action keys they always had.

    compile, test run, gated library, `.conda`, prebuilt unpack     `unit_exec()` / `test_exec()`: the host of the target platform
    toolchain closure                                               `exec_for_target()` (rules/core/platform.bzl), read in the configuration of the
                                                                    execution platform that runs the compile, so the closure is unpacked by a tool
                                                                    for that host
    the tools those actions run (mopm, mojo_compile, mojo_launch,   a `select` on the same configuration: the pin of the host (rules/mopm/hosts.bzl),
    conda_unpack, prebuilt_unpack, check)                           the zig target of the host (rules/mojo/BUCK)
    `:check`, `:table`, `:workspace`, the coverage floor            linux x86_64 always: they read files and compare hashes of the committed table
    coverage and branch coverage                                    linux x86_64 only (kcov and the pinned llvm run there)

A farm registers a host's execution platform by `[buildrules_re] linux_aarch64_properties` or `macos_aarch64_properties` (rules/platforms.bzl). When the key of
the target platform's host is not set, no execution platform of that kind exists and Buck2 could only say that none is compatible. So `unit_exec()` keeps linux
x86_64 for such a platform, and `unsupported_exec()`, which `:check` is given, makes every target of the package fail analysis naming the key.
"""

load("//rules:isa.bzl", "ISA_LEVELS", "isa_exec", "test_levels")
load("//rules:platforms.bzl", "exec_platform_missing", "exec_platform_ready")
load("//rules/core:platform.bzl", "LINUX_AARCH64", "LINUX_X86_64", "MACOS_AARCH64", "by_host")

def unit_exec():
    """`exec_compatible_with` of a rule that runs the Mojo compiler or what it built, for the target platform: its host when a farm has workers of it, else linux x86_64."""
    return by_host(
        LINUX_X86_64,
        LINUX_AARCH64 if exec_platform_ready("linux-aarch64") else LINUX_X86_64,
        MACOS_AARCH64 if exec_platform_ready("macos-aarch64") else LINUX_X86_64,
    )

def test_exec():
    """`exec_compatible_with` of a test run: `unit_exec()`, and for a target at an ISA level the execution platform of the level (rules/isa.bzl, `test_exec_compatible_with`).

    The Arm levels have no execution platform (no Arm worker reports an `exec_isa`), so an Arm test is refused as it always was. The `select` has a key for each Arm
    level that is also an aarch64 platform (`linux_aarch64_isa_is_<level>`), so that key, which is the more specific, is the one a platform at that level matches."""
    m = {}
    for level, row in ISA_LEVELS.items():
        want = [isa_exec(level)] if level in test_levels() else []
        if row["family"] == "x86_64":
            m["buildrules//platforms:isa_is_" + row["id"]] = want
        else:
            host = LINUX_AARCH64 if exec_platform_ready("linux-aarch64") else LINUX_X86_64
            m["buildrules//platforms:linux_aarch64_isa_is_" + row["id"]] = host + want
    m["buildrules//platforms:is_linux_aarch64"] = LINUX_AARCH64 if exec_platform_ready("linux-aarch64") else LINUX_X86_64
    m["buildrules//platforms:is_macos_aarch64"] = MACOS_AARCH64 if exec_platform_ready("macos-aarch64") else LINUX_X86_64
    m["DEFAULT"] = []
    return select(m)

def unsupported_exec(who):
    """What `:check` is given as `exec_missing`: empty on a target platform whose host has an execution platform, else the refusal that names the key."""
    return by_host("", exec_platform_missing("linux-aarch64", who), exec_platform_missing("macos-aarch64", who))
