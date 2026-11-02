"""CI matrix: build the same targets under another Rust version or ISA level, in ONE `buck2 build`.

A target platform selects the Rust version (`rust_version`) and the ISA level (`isa_level`). To build under several of them at once
the build needs a configuration transition, which is what these rules are: `rust_at` and `isa_at` depend on `deps` configured
for the same target platform with one constraint value replaced, and build them. Nothing else about the targets changes, so
each cell of the matrix is an ordinary configured target with its own action keys and its own cache entries.

    rust_at(name = "oldest", version = RUST_OLDEST, deps = ["//examples/hello:hello_runs"])

`buck2 build //ci:oldest` is then the same as `buck2 build --target-platforms buildrules//platforms:linux_x86_64_rust_1_85_0
//examples/hello:hello_runs`, which is how a developer reproduces one cell.
"""

load("//rules/rust:pins.bzl", "RUST_VERSIONS")

def _impl(platform, refs):
    val = refs.value[ConstraintValueInfo]
    constraints = dict(platform.configuration.constraints)
    constraints[val.setting.label] = val
    # A transition must be idempotent: applying it to its own output gives the same platform, so the tag is added once.
    tag = "+" + val.label.name
    label = platform.label if tag in platform.label else platform.label + tag
    return PlatformInfo(
        label = label,
        configuration = ConfigurationInfo(constraints = constraints, values = platform.configuration.values),
    )

# A transition must be assigned to a variable of its own, so each cell is spelled out. A version or level added to
# rules/rust/pins.bzl or rules/isa.bzl without a line here is refused at load (below).
_RUST_1_95_0 = transition(impl = _impl, refs = {"value": "buildrules//platforms:rust_1_95_0"})
_RUST_1_85_0 = transition(impl = _impl, refs = {"value": "buildrules//platforms:rust_1_85_0"})
_ISA_X86_64_V1 = transition(impl = _impl, refs = {"value": "buildrules//platforms:isa_x86_64_v1"})
_ISA_X86_64_V2 = transition(impl = _impl, refs = {"value": "buildrules//platforms:isa_x86_64_v2"})
_ISA_X86_64_V3 = transition(impl = _impl, refs = {"value": "buildrules//platforms:isa_x86_64_v3"})
_ISA_X86_64_V4 = transition(impl = _impl, refs = {"value": "buildrules//platforms:isa_x86_64_v4"})

def _macos_impl(platform, refs):
    os = refs.os[ConstraintValueInfo]
    cpu = refs.cpu[ConstraintValueInfo]
    constraints = dict(platform.configuration.constraints)
    constraints[os.setting.label] = os
    constraints[cpu.setting.label] = cpu
    tag = "+macos_aarch64"
    label = platform.label if tag in platform.label else platform.label + tag
    return PlatformInfo(
        label = label,
        configuration = ConfigurationInfo(constraints = constraints, values = platform.configuration.values),
    )

# The OS and the CPU of the target platform replaced: the same targets built for macOS on Apple silicon (the Mojo rules then run on the macOS worker).
_MACOS_AARCH64 = transition(impl = _macos_impl, refs = {"cpu": "buildrules//platforms:aarch64", "os": "buildrules//platforms:macos"})

_DEP_ATTRS = ["deps", "macos_aarch64", "isa_x86_64_v1", "isa_x86_64_v2", "isa_x86_64_v3", "isa_x86_64_v4", "rust_1_85_0", "rust_1_95_0"]

def _group_impl(ctx):
    outs = []
    for name in _DEP_ATTRS:
        for d in getattr(ctx.attrs, name, []):
            outs += d[DefaultInfo].default_outputs
    return [DefaultInfo(default_outputs = outs)]

# One rule, one list attribute per cell: each attribute carries its own transition.
_at = rule(
    impl = _group_impl,
    attrs = {
        "macos_aarch64": attrs.list(attrs.transition_dep(cfg = _MACOS_AARCH64), default = []),
        "isa_x86_64_v1": attrs.list(attrs.transition_dep(cfg = _ISA_X86_64_V1), default = []),
        "isa_x86_64_v2": attrs.list(attrs.transition_dep(cfg = _ISA_X86_64_V2), default = []),
        "isa_x86_64_v3": attrs.list(attrs.transition_dep(cfg = _ISA_X86_64_V3), default = []),
        "isa_x86_64_v4": attrs.list(attrs.transition_dep(cfg = _ISA_X86_64_V4), default = []),
        "rust_1_85_0": attrs.list(attrs.transition_dep(cfg = _RUST_1_85_0), default = []),
        "rust_1_95_0": attrs.list(attrs.transition_dep(cfg = _RUST_1_95_0), default = []),
    },
)

_RUST_CELLS = ["1.85.0", "1.95.0"]
_ISA_CELLS = ["x86_64_v1", "x86_64_v2", "x86_64_v3", "x86_64_v4"]

[fail("rules/matrix.bzl has no transition for Rust " + v) for v in RUST_VERSIONS if v not in _RUST_CELLS]

def rust_at(name, version, deps, **kwargs):
    """Builds `deps` with the Rust `version` (one of `RUST_VERSIONS`; the platform constraint `rust_<v>`)."""
    if version not in _RUST_CELLS:
        fail("rust_at: {} is not a version buildrules pins ({})".format(version, ", ".join(_RUST_CELLS)))
    _at(name = name, **dict(kwargs, **{"rust_" + version.replace(".", "_"): deps}))

def isa_at(name, level_id, deps, **kwargs):
    """Builds `deps` at the ISA level whose id is `level_id` (`x86_64_v3`: the platform constraint `isa_<id>`)."""
    if level_id not in _ISA_CELLS:
        fail("isa_at: {} has no transition ({})".format(level_id, ", ".join(_ISA_CELLS)))
    _at(name = name, **dict(kwargs, **{"isa_" + level_id: deps}))

def macos_at(name, deps, **kwargs):
    """Builds `deps` for macOS on Apple silicon (`buildrules//platforms:macos_aarch64`), whatever platform the build is for."""
    _at(name = name, **dict(kwargs, **{"macos_aarch64": deps}))

def group(name, deps, **kwargs):
    """Builds `deps` as they are (the default cell of a matrix)."""
    _group(name = name, deps = deps, **kwargs)

_group = rule(impl = _group_impl, attrs = {"deps": attrs.list(attrs.dep())})
