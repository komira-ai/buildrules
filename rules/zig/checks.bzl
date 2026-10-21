"""What the Zig rules refuse (zig.bzl), as functions of plain values.

Each check takes the values it judges and `refuse`, which is `fail` in a rule: the build stops at the first refusal, with its message. A test passes a
recorder instead (rules/rust/refusal.bzl) and reads what was refused, so each refusal has a test that goes red when the rule stops refusing
(rules/zig/tests).
"""

# zig's optimization modes, for `optimize`.
ZIG_OPTIMIZE_MODES = ["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"]

# Names zig gives modules of its own: the importing file is `root`, and `std` and `builtin` are always there. A module of one of these names would
# clash with them.
ZIG_RESERVED_MODULES = ["root", "std", "builtin"]

def check_target_triple(who, target, refuse = fail):
    """`target` is spelled like a zig target triple (`x86_64-linux-musl`, `x86_64-linux-gnu.2.34`)."""
    if not regex_match("^[a-z0-9_.-]+$", target):
        refuse("{}: target {} is not a zig target triple".format(who, repr(target)))

def check_optimize(who, optimize, refuse = fail):
    """`optimize` is one of zig's optimization modes."""
    if optimize not in ZIG_OPTIMIZE_MODES:
        refuse("{}: optimize {} is not a zig optimization mode ({})".format(who, repr(optimize), ", ".join(ZIG_OPTIMIZE_MODES)))

def check_module_name(who, name, refuse = fail):
    """A `zig_module` is imported by its target name, which may not be a name zig uses itself."""
    if name in ZIG_RESERVED_MODULES:
        refuse("{}: a zig_module may not be named {} (zig's own module names: {})".format(who, name, ", ".join(ZIG_RESERVED_MODULES)))

def check_unique_imports(who, names, refuse = fail):
    """No two direct `deps` of a `zig_module` are imported under one name."""
    if len(names) != len(set(names)):
        refuse("{}: two deps are imported by one name (a zig_module's import name is its target name): {}".format(who, ", ".join(names)))

def check_unique_dep_names(who, pairs, refuse = fail):
    """No two direct `deps` of a `zig_exe` or `zig_test` are imported under one name: `pairs` are (import name, label) in order."""
    seen = {}
    for name, label in pairs:
        if name in seen:
            refuse("{}: two deps are imported as \"{}\": {} and {} (a zig_module's import name is its target name)".format(who, name, seen[name], label))
            continue
        seen[name] = label

def check_exec_tool_name(who, name, taken, refuse = fail):
    """An `exec_tools` name is an environment variable the test can read, and is not one the action, the runner or `env_tools` already sets
    (`taken`)."""
    if not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
        refuse("{}: exec_tools name {} is not a shell variable name".format(who, repr(name)))
    elif name in taken:
        refuse("{}: exec_tools name {} is set by the action or by env_tools".format(who, name))

def zig_closure(where, deps, refuse = fail):
    """The modules `deps` (ZigModuleInfo of the direct deps, in order) reach,
    each once, direct ones first. Refuses when two different targets of one
    import name are reached."""
    out = []
    labels = {}
    for dep in deps:
        for e in [struct(name = dep.name, label = dep.label, root = dep.root, inputs = dep.inputs, deps = dep.deps)] + dep.closure:
            if e.name in labels:
                if labels[e.name] != e.label:
                    refuse("{}: two different modules are imported as \"{}\": {} and {} (a zig_module's import name is its target name)".format(where, e.name, labels[e.name], e.label))
                continue
            labels[e.name] = e.label
            out.append(e)
    return out

def check_exe_target(who, exe, got, expect, refuse = fail):
    """The executable `exe` is built for the zig target triple `expect`."""
    if got != expect:
        refuse("{}: {} is built for {}, not {}".format(who, exe, repr(got), repr(expect)))

def check_same_tests(who, exe, got_tests, same_as, want_tests, refuse = fail):
    """A cross-built copy of a program waits for exactly the unit tests of the program it copies, and that program has some."""
    if not want_tests or got_tests != want_tests:
        refuse("{}: {} waits for the unit tests {}, not those of {} ({}; an empty list is refused too)".format(who, exe, got_tests, same_as, want_tests))
