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

_IS_LINUX_AARCH64 = "buildrules//platforms:is_linux_aarch64"
_IS_MACOS_AARCH64 = "buildrules//platforms:is_macos_aarch64"

def by_host(linux_x86_64, linux_aarch64, macos_aarch64):
    """A `select` over the OS and the CPU of the configuration it is resolved in: linux aarch64 and macOS on Apple silicon have their own value, every other
    platform (linux x86_64 at any ISA level, macOS on Intel) has `linux_x86_64`, the value of every platform before the other hosts existed."""
    return select({
        _IS_LINUX_AARCH64: linux_aarch64,
        _IS_MACOS_AARCH64: macos_aarch64,
        "DEFAULT": linux_x86_64,
    })

def exec_for_target():
    """`exec_compatible_with` of an action that runs what is built for the target platform: linux aarch64 -> `LINUX_AARCH64`, macOS arm64 -> `MACOS_AARCH64`,
    anything else `LINUX_X86_64`. A tool (`exec_dep`) is configured as the execution platform of the rule that runs it, so the same `select` in a toolchain
    or a tool chooses its host by the host that runs it."""
    return by_host(LINUX_X86_64, LINUX_AARCH64, MACOS_AARCH64)
