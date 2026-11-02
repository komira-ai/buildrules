"""The constraint values of the execution platform that runs actions (linux x86_64 for every rule but the Mojo ones; the other hosts have pins, a platform, and run Mojo actions).

A target whose actions run a binary built for that platform states `exec_compatible_with =
LINUX_X86_64`. The values are the ones of `//platforms:linux_x86_64`, which is also the
configuration of the execution platform (`//platforms/exec`), so a tool built to run in an action
is configured exactly like a target built for that platform.

A Mojo compile cannot target another platform than the one it runs on, so the Mojo rules state `exec_for_target()`: the execution platform of the
target platform's own kind (rules/mojo/exec.bzl says what happens when no worker of that kind is configured).
"""

LINUX_X86_64 = ["buildrules//platforms:linux", "buildrules//platforms:x86_64"]

# The other hosts (rules/pins/hosts.bzl). A toolchain for one lists its constant; the Mojo rules choose among all three by the target platform (`exec_for_target`).
LINUX_AARCH64 = ["buildrules//platforms:linux", "buildrules//platforms:aarch64"]
MACOS_AARCH64 = ["buildrules//platforms:macos", "buildrules//platforms:aarch64"]

# A target platform states its OS and CPU in this package's constraint values, in the prelude's (a repository that does not know buildrules has only those), or in
# both. platforms/BUCK has three config settings per (OS, CPU) pair, and a `select` that chooses by the host has a branch for each of the three.
_VOCABULARIES = ["is_", "is_prelude_", "is_both_"]

def os_cpu_keys(os_cpu):
    """The three config settings of an (OS, CPU) pair (`linux_x86_64`, `linux_aarch64`, `macos_aarch64`): the platform that states it in this package's constraint
    values, in the prelude's, or in both. A platform matches the first, the second, or all three (the third is the more specific, so the `select` is not ambiguous)."""
    return ["buildrules//platforms:" + v + os_cpu for v in _VOCABULARIES]

def by_os_cpu(branches):
    """A `select` over (OS, CPU) pairs: `branches` maps `linux_x86_64`, `linux_aarch64`, `macos_aarch64` or `DEFAULT` to a value; a pair is chosen by whichever
    vocabulary the target platform states it in (`os_cpu_keys`), and a platform that states none of them takes `DEFAULT`."""
    m = {}
    for k, v in branches.items():
        if k == "DEFAULT":
            m[k] = v
        else:
            for key in os_cpu_keys(k):
                m[key] = v
    return select(m)

def by_host(linux_x86_64, linux_aarch64, macos_aarch64):
    """A `select` over the OS and the CPU of the configuration it is resolved in: linux aarch64 and macOS on Apple silicon have their own value, every other
    platform (linux x86_64 at any ISA level, macOS on Intel, a platform that states neither vocabulary) has `linux_x86_64`, the value of every platform before the
    other hosts existed."""
    return by_os_cpu({
        "linux_aarch64": linux_aarch64,
        "macos_aarch64": macos_aarch64,
        "DEFAULT": linux_x86_64,
    })

def exec_for_target():
    """`exec_compatible_with` of an action that runs what is built for the target platform: linux aarch64 -> `LINUX_AARCH64`, macOS arm64 -> `MACOS_AARCH64`,
    anything else `LINUX_X86_64`. A tool (`exec_dep`) is configured as the execution platform of the rule that runs it, so the same `select` in a toolchain
    or a tool chooses its host by the host that runs it."""
    return by_host(LINUX_X86_64, LINUX_AARCH64, MACOS_AARCH64)

# ---- the tool tier ----------------------------------------------------------------------------------------------------------------------------
# The tools a Mojo action runs (the Zig tools, the pinned zig and busybox, the unpackers, `:check`) are built and run by the execution platform of the machine
# that runs them: on a farm it is linux x86_64 (every tool is cross-compiled there for the host it will run on, and the action keys are what they always were),
# and on a Mac that runs Buck2 itself with `[buildrules_re] mode = local` it is the Mac, the only execution platform that exists.

HOST_NAMES = ["linux-x86_64", "linux-aarch64", "macos-aarch64"]

# `[buildrules_re]` key that names the machine for an analysis on another machine (see `machine_name`).
LOCAL_HOST_KEY = "local_host"

def host_name_of(info):
    """`<os>-<cpu>` of a `host_info()` value (`linux-x86_64`, `linux-aarch64`, `macos-aarch64`, `other-other`)."""
    os = "linux" if info.os.is_linux else ("macos" if info.os.is_macos else "other")
    cpu = "x86_64" if info.arch.is_x86_64 else ("aarch64" if info.arch.is_aarch64 else "other")
    return os + "-" + cpu

def _tool_mode():
    return read_root_config("buildrules_re", "mode", "remote").strip()

def machine_of(real, override, mode):
    """`(machine, refusal)`: the machine local mode runs on, `override` (`[buildrules_re] local_host`) when set, else `real`. Pure, for ci/tool_exec.bzl.

    The override exists so an analysis on one kind of machine can show where the actions of another kind would be placed (ci/tool_exec.bxl). It names a machine
    only in local mode, where the actions run on this machine; anywhere else it is refused, so a farm's configuration never carries it.
    """
    if not override:
        return real, None
    if mode != "local":
        return None, "`[buildrules_re] {}` is `{}` but `[buildrules_re] mode` is `{}`: the key names the machine of local mode, for an analysis on another machine, and means nothing on a farm.".format(LOCAL_HOST_KEY, override, mode)
    if override not in HOST_NAMES:
        return None, "`[buildrules_re] {}` is `{}`: it is one of {}.".format(LOCAL_HOST_KEY, override, ", ".join(HOST_NAMES))
    return override, None

def machine_name():
    """The machine running buck2 as `<os>-<cpu>`: the spelling of tools/buck2 and rules/pins/hosts.bzl. `[buildrules_re] local_host` replaces it for an analysis on another machine (local mode only)."""
    machine, refusal = machine_of(host_name_of(host_info()), read_root_config("buildrules_re", LOCAL_HOST_KEY, "").strip(), _tool_mode())
    if refusal:
        fail(refusal)
    return machine

def tool_exec_for(mode, machine):
    """`exec_compatible_with` of a tool of the Mojo tier: the Mac itself in local mode on macOS arm64, else linux x86_64 (the farm's, and a local Linux machine's)."""
    if mode == "local" and machine == "macos-aarch64":
        return MACOS_AARCH64
    return LINUX_X86_64

def tool_target_for(mode, machine):
    """zig's `-target` of a program that runs on `tool_exec_for(mode, machine)` and has no other target: what a `zig_exe` or `zig_test` is built for by default."""
    if mode == "local" and machine == "macos-aarch64":
        return "aarch64-macos"
    return "x86_64-linux-musl"

TOOL_EXEC = tool_exec_for(_tool_mode(), machine_name())
TOOL_TARGET = tool_target_for(_tool_mode(), machine_name())
