"""Every `[buildrules_re]` key is read from the root cell's configuration, so a cell whose own configuration lacks them sees the same values (rules/platforms.bzl).

`//ci/rootcell` (the cell `rootcell`, declared in .buckconfig) has a .buckconfig with no `[buildrules_re]` section. The check is run with the keys set for the root cell only
(ci/root_keys.bxl), which is the shape of a repository that consumes buildrules through a cell of another repository: the keys are in the root's files, the platforms are
evaluated in another cell. It holds, per state:

  on   the root cell sets the linux arm64 switch (`true`) and the property sets of linux x86_64, linux aarch64 and macOS arm64: `rootcell//:exec` registers the macOS arm64 and
       linux aarch64 execution platforms (and builds its property sets from the root's keys), and the helpers the Mojo rules call (`exec_platform_ready`, `linux_arm64_enabled`,
       `linux_arm64_gate`) answer from the root cell's values.
  off  the root cell sets the macOS arm64 and linux x86_64 sets and leaves the switch off: macOS arm64 is registered and ready, linux aarch64 is neither (and its gate is on).

  local  (the public CI) `mode = local` and the root cell's switch `true`, nothing else: the probe of the cell reports the switch on, and the platform of the machine running buck2 ready.

Evaluated from a cell that reads its own configuration, the platforms fail to load ("`[buildrules_re] linux_x86_64_properties` is not set") before anything is compared.
"""

load("//rules:platforms.bzl", "host_name")

LINUX_AARCH64 = "buildrules//platforms:linux_aarch64"
MACOS_AARCH64 = "buildrules//platforms:macos_aarch64"
LINUX_X86_64 = "buildrules//platforms:linux_x86_64"

def _registered(ctx):
    node = ctx.configured_targets("rootcell//:exec", target_platform = LINUX_X86_64)
    reg = ctx.analysis(node).providers()[ExecutionPlatformRegistrationInfo]
    return {str(p.label).split(" ")[0]: p.executor_config for p in reg.platforms}

def _attrs(ctx):
    node = ctx.configured_targets("rootcell//:probe", target_platform = LINUX_X86_64)
    return node.resolved_attrs_eager(ctx)

def _local_problems(ctx):
    """State `local` (what the public CI runs: `-c buildrules_re.mode=local`, and `linux_arm64_enabled = true` for the root cell only). Local mode registers the platform of
    the machine running buck2 and refuses the property sets, so what is held is the switch: the cell with no section sees the root cell's `true`."""
    problems = []
    attrs = _attrs(ctx)
    for k, v in {"linux_arm64_enabled": "True", "linux_arm64_gate": "[]"}.items():
        got = getattr(attrs, k)
        if got != v:
            problems.append("rootcell//:probe {} is {} in state `local`, not {}: the helper did not read the root cell's `linux_arm64_enabled = true`".format(k, repr(got), repr(v)))
    for host, k in {"linux-aarch64": "linux_aarch64_ready", "macos-aarch64": "macos_aarch64_ready"}.items():
        want = str(host_name() == host)
        if getattr(attrs, k) != want:
            problems.append("rootcell//:probe {} is {} in local mode on a {} machine, not {}".format(k, repr(getattr(attrs, k)), host_name(), want))
    registered = _registered(ctx)
    if LINUX_X86_64 not in registered and host_name() == "linux-x86_64":
        problems.append("rootcell//:exec does not register {} in local mode".format(LINUX_X86_64))
    return problems

def root_key_problems(ctx, state):
    if state == "local":
        return _local_problems(ctx)
    problems = []
    arm64_on = state == "on"
    registered = _registered(ctx)
    attrs = _attrs(ctx)
    want = {
        MACOS_AARCH64: True,
        LINUX_AARCH64: arm64_on,
    }
    for plat, expected in want.items():
        if (plat in registered) != expected:
            problems.append("rootcell//:exec {} {} in state `{}`: the root cell's key for it is set and (linux aarch64) the switch is {}".format(plat, "registers" if plat in registered else "does not register", state, "on" if arm64_on else "off"))
    if LINUX_X86_64 not in registered:
        problems.append("rootcell//:exec does not register {}: the root cell's `linux_x86_64_properties` was not seen".format(LINUX_X86_64))
    expect_attrs = {
        "linux_aarch64_ready": str(arm64_on),
        "linux_arm64_enabled": str(arm64_on),
        "macos_aarch64_ready": "True",
        "macos_aarch64_missing": "",
    }
    for k, v in expect_attrs.items():
        got = getattr(attrs, k)
        if got != v:
            problems.append("rootcell//:probe {} is {} in state `{}`, not {}: the helper did not read the root cell's configuration".format(k, repr(got), state, repr(v)))
    gate = attrs.linux_arm64_gate
    if arm64_on != (gate == "[]"):
        problems.append("rootcell//:probe linux_arm64_gate is {} in state `{}`: it is empty exactly when the root cell turns the switch on".format(repr(gate), state))
    return problems
