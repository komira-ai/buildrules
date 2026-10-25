"""What a Mojo test is given besides its binary: the files it reads, and the variables it sees (docs/contract.md, section 12.9).

    mojo_package(
        path = ".",
        test_data = {
            "*": {"fixtures/spec.thrift": "//third_party/parquet:parquet.thrift"},          # every test of the package
            "tests/test_tool.mojo": {"bin/tool": "//tools:tool", "golden/out.txt": "golden/out.txt"},   # one test
        },
        test_env = {"MODE": "strict"},                                                       # every test of the package
        test_defines = {"TRACE": True, "LEVEL": 3},                                          # `-D TRACE=true -D LEVEL=3` on every test build
    )

All three are pure functions of the arguments, so every refusal is an analysis test (rules/mojo/tests/BUCK) and a refusal stops the load of the package:
`refuse` is `fail` in a build, a recorder in a test (rules/rust/refusal.bzl).
"""

load("//rules/core:test_runtime.bzl", "RUNNER_ENV", "check_data_destinations")

# The variable that names the directory a test is given its data in. In the default layout a test runs with that directory as its working directory, so a
# relative path and this variable reach the same files; in the installed layout it is `<root>/share`, and the working directory is `<root>`. It is set only
# for a test that has data.
DATA_ENV = "BUILDRULES_TEST_DATA"

# The layouts a test is run in (`mojo_package(test_layout = ...)`, docs/contract.md section 12.9): `default` is the data directory as the working directory;
# `installed` is a fresh root per test with the binary at `<root>/bin/<exe>`, the data under `<root>/share`, and `<root>` as the working directory.
LAYOUT_DEFAULT = "default"
LAYOUT_INSTALLED = "installed"
LAYOUTS = [LAYOUT_DEFAULT, LAYOUT_INSTALLED]

# In the installed layout the root holds `bin/` and `share/` of its own; the coverage run's root also holds the sources the line tables name.
INSTALLED_NAMES = ["bin", "share"]

def check_test_layout(where, layout, refuse = fail):
    """`test_layout` is one of LAYOUTS. Returns whether it is."""
    if type(layout) != "string" or layout not in LAYOUTS:
        refuse("{}: test_layout {} is not one of {}".format(where, repr(layout), ", ".join(LAYOUTS)))
        return False
    return True

def check_installed_tree(where, names, refuse = fail):
    """The installed coverage root holds the sources of the test and of the library at the names the line tables use (`names`, paths relative to the root), next
    to its own `bin/` and `share/`: a source whose first directory is one of those would be merged into them. Refused, naming it."""
    for name in sorted(names):
        top = name.split("/")[0]
        if top in INSTALLED_NAMES:
            refuse("{}: the source {} is in {}/, which the installed layout keeps for the binary and the data (bin/, share/): the coverage run's root would merge them".format(where, name, top))

# The names `test_env` may not set: the runner's own (rules/core/test_runtime.bzl) and the ones these rules set (the data directory, the nonce of a
# unit action, the scratch path Buck2 gives an action).
OWN_ENV = RUNNER_ENV + [DATA_ENV, "BUILDRULES_UNIT_NONCE", "BUCK_SCRATCH_PATH"]

def check_test_env(where, env, refuse = fail):
    """`test_env` is `{NAME: value}`: every name a shell variable name the runner does not set itself, every value a string."""
    if type(env) != "dict":
        refuse("{}: test_env must be a dict {{NAME: value}}, not {}".format(where, type(env)))
        return
    for name in sorted(env.keys()):
        if type(name) != "string" or not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
            refuse("{}: test_env name {} is not a shell variable name".format(where, repr(name)))
            continue
        if name in OWN_ENV:
            refuse("{}: test_env sets {}, which the test runner sets itself (runner-owned: {})".format(where, name, ", ".join(OWN_ENV)))
            continue
        if type(env[name]) != "string":
            refuse("{}: test_env {} must be a string, not {}".format(where, name, type(env[name])))

# The defines `test_defines` may not set: the unit's profile passes `-D ASSERT=<level>` to every test and binary build (mopm unit build), so a second one
# would be two values for one name.
OWN_DEFINES = ["ASSERT"]

def check_test_defines(where, defines, refuse = fail):
    """`test_defines` is `{NAME: value}`, the compile-time defines of the package's test builds (`mojo build -D NAME=value`). Returns the compiler
    arguments, `["-D", "A=1", "-D", "B=true", ...]` in the order of the names, and `[]` after a refusal.

    A name is an identifier (letters, digits and `_`, not starting with a digit) that the profile does not set (OWN_DEFINES). A value is a string, a bool
    (`true` or `false`) or an int, written as the compiler reads it; a string is one or more printable characters with no space, because the value travels
    as one line of the toolchain file and one argument of the compiler (a space or a line break would end it or start another key)."""
    if type(defines) != "dict":
        refuse("{}: test_defines must be a dict {{NAME: value}}, not {}".format(where, type(defines)))
        return []
    args = []
    bad = False
    for name in sorted(defines.keys()):
        value = defines[name]
        if type(name) != "string" or not regex_match("^[A-Za-z_][A-Za-z0-9_]*$", name):
            refuse("{}: test_defines name {} is not a define name (letters, digits and `_`, not starting with a digit)".format(where, repr(name)))
            bad = True
            continue
        if name in OWN_DEFINES:
            refuse("{}: test_defines sets {}, which the unit's profile sets itself (profile-owned: {})".format(where, name, ", ".join(OWN_DEFINES)))
            bad = True
            continue
        if type(value) == "bool":
            text = "true" if value else "false"
        elif type(value) == "int":
            text = str(value)
        elif type(value) == "string":
            text = value
        else:
            refuse("{}: test_defines {} must be a string, a bool or an int, not {}".format(where, name, type(value)))
            bad = True
            continue
        if not regex_match("^[!-~]+$", text):
            refuse("{}: test_defines {} is {}: a value is one or more printable characters with no space or line break".format(where, name, repr(text)))
            bad = True
            continue
        args += ["-D", "{}={}".format(name, text)]
    return [] if bad else args

def _overlaps(dest, held):
    """`dest` is `held`, inside it or holds it (a file cannot be a directory)."""
    return dest == held or held.startswith(dest + "/") or dest.startswith(held + "/")

def stage_test_data(where, tests, test_data, held = {}, refuse = fail):
    """The data of each test: `{test source: {staged path: label or file}}`.

    `tests` are the test sources as the graph names them (`tests/test_x.mojo`, relative to the package directory). `test_data` is
    `{"<test source>" or "*": {"<staged path>": "<label or file>"}}`; `*` is every test, and a test's own entries are added to it. `held` is
    `{test source: [paths already in the tree its coverage run is given]}`: the coverage run's working directory also holds the test's source and the
    library's sources, so a staged path may not be one of them or inside one. Refused: a key that is no test (a mistyped path would stage nothing), a
    staged path that is absolute, empty, ends in `/`, holds `..` or `.`, or is both a file and a directory, one path staged twice for a test (by `*` and by
    the test), and a value that is not a string."""
    if type(test_data) != "dict":
        refuse("{}: test_data must be a dict {{\"<test source>\" or \"*\": {{staged path: label or file}}}}, not {}".format(where, type(test_data)))
        return {}
    staged = {t: {} for t in tests}
    for key in sorted(test_data.keys()):
        files = test_data[key]
        here = "{}: test_data[{}]".format(where, repr(key))
        if key != "*" and key not in staged:
            refuse("{}: names no test of the package; its tests are {} (a test source relative to the package, or \"*\" for all of them)".format(here, ", ".join(sorted(tests)) or "(none)"))
            continue
        if type(files) != "dict":
            refuse("{} must be a dict {{staged path: label or file}}, not {}".format(here, type(files)))
            continue
        for dest in sorted(files.keys()):
            if type(files[dest]) != "string":
                refuse("{}: {} must be a label or a file name (a string), not {}".format(here, repr(dest), type(files[dest])))
        for t in (sorted(tests) if key == "*" else [key]):
            for dest in sorted(files.keys()):
                if dest in staged[t]:
                    refuse("{}: {} is staged twice for {} ({} and {}): one path has one source".format(here, repr(dest), t, repr(staged[t][dest]), repr(files[dest])))
                else:
                    staged[t][dest] = files[dest]
    for t in sorted(tests):
        # The paths of each test as a whole, so `*` staging `a` and a test staging `a/b` is seen.
        check_data_destinations("{}: the data of {}".format(where, t), staged[t].keys(), refuse)
        for dest in sorted(staged[t].keys()):
            for h in held.get(t, []):
                if _overlaps(dest, h):
                    refuse(("{}: test_data stages {} for {}, but the tree of its coverage run (:coverage) already holds {} (the test's source and the library's " +
                            "sources, under the names the line tables use): stage it under another path").format(where, repr(dest), t, repr(h)))
    return staged
