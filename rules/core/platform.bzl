"""The constraint values of the execution platform that runs actions (every rule: linux x86_64; the other hosts have pins and a platform only).

A target whose actions run a binary built for that platform states `exec_compatible_with =
LINUX_X86_64`. The values are the ones of `//platforms:linux_x86_64`, which is also the
configuration of the execution platform (`//platforms/exec`), so a tool built to run in an action
is configured exactly like a target built for that platform.
"""

LINUX_X86_64 = ["buildrules//platforms:linux", "buildrules//platforms:x86_64"]

# The other hosts (rules/pins/hosts.bzl). No rule is `exec_compatible_with` them yet; a toolchain for one lists its constant.
LINUX_AARCH64 = ["buildrules//platforms:linux", "buildrules//platforms:aarch64"]
MACOS_AARCH64 = ["buildrules//platforms:macos", "buildrules//platforms:aarch64"]
