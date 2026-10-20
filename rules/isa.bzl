"""ISA levels: one table, every compiler's flags, and the selects that use it.

A target platform picks an instruction-set level with the `isa_level` constraint (platforms/BUCK builds one platform
per level: `buildrules//platforms:linux_x86_64_v3`). The level is in the Buck2 configuration, so a v1 and a v3 build
have different output paths and different action keys, and it is in the compilers' argv, so they differ again.

`ISA_LEVELS` is the ONE table behind rustc, zig cc and Mojo. A level never passes `native`: a farm matches a request
"at least, within the family" (a v3 test runs on a v3 or v4 worker, x86 never serves Arm), and code tuned to the
build host would be cached under a lower level's key.

Compile actions never ask for a level: they run on the ISA-agnostic execution platform (`ISA=x86-64`), because a
compiler emits v3 code on any worker. TEST actions of a target at level vN (N >= 2) run on the execution platform
of that level (`ISA=x86-64-vN`), chosen by `exec_compatible_with = test_exec_compatible_with()`; the farm then schedules them on a
worker that reports at least that level. x86-64-v1 is the baseline every x86-64 worker has, so it needs no platform of its own.

Verified on the farm: `rustc -C target-cpu=x86-64-vN` and `zig cc -mcpu=x86_64_vN` (docs/contract.md section 11).
Mojo: the x86-64 spellings are verified on the farm (`mojo build --target-cpu x86-64-v3` is accepted and changes the test binary, rules/mojo); the Arm spellings are not.
"""

# level -> id (target-name suffix), family, the cpu constraint value, and each tool's flags.
# `property` is the REAPI `ISA` value a farm matches workers on ("x86-64" alone means the architecture only).
ISA_LEVELS = {
    "x86-64-v1": {"id": "x86_64_v1", "family": "x86_64", "property": "x86-64", "rustc": ["-C", "target-cpu=x86-64"], "zig": "-mcpu=x86_64", "mojo": ["--target-cpu", "x86-64"]},
    "x86-64-v2": {"id": "x86_64_v2", "family": "x86_64", "property": "x86-64-v2", "rustc": ["-C", "target-cpu=x86-64-v2"], "zig": "-mcpu=x86_64_v2", "mojo": ["--target-cpu", "x86-64-v2"]},
    "x86-64-v3": {"id": "x86_64_v3", "family": "x86_64", "property": "x86-64-v3", "rustc": ["-C", "target-cpu=x86-64-v3"], "zig": "-mcpu=x86_64_v3", "mojo": ["--target-cpu", "x86-64-v3"]},
    "x86-64-v4": {"id": "x86_64_v4", "family": "x86_64", "property": "x86-64-v4", "rustc": ["-C", "target-cpu=x86-64-v4"], "zig": "-mcpu=x86_64_v4", "mojo": ["--target-cpu", "x86-64-v4"]},
    "armv8.0-a": {"id": "armv8_0", "family": "aarch64", "property": "armv8.0-a", "rustc": ["-C", "target-cpu=generic"], "zig": "-mcpu=generic", "mojo": ["--target-cpu", "generic"]},
    "armv8.1-a": {"id": "armv8_1", "family": "aarch64", "property": "armv8.1-a", "rustc": ["-C", "target-cpu=generic", "-C", "target-feature=+v8.1a"], "zig": "-mcpu=generic+v8_1a", "mojo": ["--target-cpu", "generic", "--target-features", "+v8.1a"]},
    "armv8.2-a": {"id": "armv8_2", "family": "aarch64", "property": "armv8.2-a", "rustc": ["-C", "target-cpu=generic", "-C", "target-feature=+v8.2a"], "zig": "-mcpu=generic+v8_2a", "mojo": ["--target-cpu", "generic", "--target-features", "+v8.2a"]},
    "armv8.3-a": {"id": "armv8_3", "family": "aarch64", "property": "armv8.3-a", "rustc": ["-C", "target-cpu=generic", "-C", "target-feature=+v8.3a"], "zig": "-mcpu=generic+v8_3a", "mojo": ["--target-cpu", "generic", "--target-features", "+v8.3a"]},
    "armv8.4-a": {"id": "armv8_4", "family": "aarch64", "property": "armv8.4-a", "rustc": ["-C", "target-cpu=generic", "-C", "target-feature=+v8.4a"], "zig": "-mcpu=generic+v8_4a", "mojo": ["--target-cpu", "generic", "--target-features", "+v8.4a"]},
}

_PLATFORMS = "buildrules//platforms:"

def isa_is(level):
    """The config_setting that is true for a target at `level`."""
    return _PLATFORMS + "isa_is_" + ISA_LEVELS[level]["id"]

def isa_exec(level):
    """The constraint value only the execution platform of `level` carries."""
    return _PLATFORMS + "exec_isa_" + ISA_LEVELS[level]["id"]

def test_levels():
    """The levels whose tests need an execution platform of their own: all but x86-64-v1, which runs on any x86-64 worker."""
    return [l for l in ISA_LEVELS if l != "x86-64-v1"]

def exec_levels():
    """The levels with a registered execution platform: x86-64 v2..v4. Arm has none (no Arm worker is configured), so an
    Arm test finds no execution platform and is refused, rather than run on a machine that cannot execute it."""
    return [l for l in test_levels() if ISA_LEVELS[l]["family"] == "x86_64"]

def isa_select(per_level, default):
    """A `select` over the target's ISA level: `per_level(level)` for each, `default` when the platform has none."""
    m = {isa_is(l): per_level(l) for l in ISA_LEVELS}
    m["DEFAULT"] = default
    return select(m)

def rustc_isa_flags():
    """rustc flags for the target's ISA level (empty on a platform without one: today's keys are unchanged)."""
    return isa_select(lambda l: list(ISA_LEVELS[l]["rustc"]), [])

def zig_cpu():
    """zig cc `-mcpu` value for the cxx toolchain, as `cxx_toolchains(target_cpu =)` spells it (dashes)."""
    return isa_select(lambda l: ISA_LEVELS[l]["zig"][len("-mcpu="):].replace("_", "-"), "x86-64")

def required_isa():
    """The level a target at this platform requires, as its REAPI `ISA` value ("" when none)."""
    return isa_select(lambda l: ISA_LEVELS[l]["property"], "")

def test_exec_compatible_with():
    """`exec_compatible_with` of a TEST run target: the execution platform of the target's level (none = any worker)."""
    return isa_select(lambda l: [isa_exec(l)] if l in test_levels() else [], [])

def _ladder(family):
    return [v["property"] for v in ISA_LEVELS.values() if v["family"] == family]

def isa_satisfies(have, required):
    """True when an execution platform reporting `have` (an `ISA` value) can run code built for `required`: the same family and
    at least that level. The farm makes the same decision at scheduling time; this is the analysis-time copy that catches a test
    rule whose target level never reached its execution platform."""
    if not required:
        return True
    for family in ["x86_64", "aarch64"]:
        ladder = _ladder(family)
        if required in ladder:
            return have in ladder and ladder.index(have) >= ladder.index(required)
    fail("unknown ISA value " + repr(required))

def expected_vector_width():
    """What a binary built for the target's level must contain: "avx2" (256-bit `ymm` code, x86-64-v3 and up) or "none" (no `ymm`)."""
    return isa_select(lambda l: "avx2" if l in ["x86-64-v3", "x86-64-v4"] else "none", "none")
