"""The constraint values of the execution platform that runs actions (v0: linux x86_64 only).

A target whose actions run a binary built for that platform states `exec_compatible_with =
LINUX_X86_64`. The values are the ones of `//platforms:linux_x86_64`, which is also the
configuration of the execution platform (`//platforms/exec`), so a tool built to run in an action
is configured exactly like a target built for that platform.
"""

LINUX_X86_64 = ["buildrules//platforms:linux", "buildrules//platforms:x86_64"]
