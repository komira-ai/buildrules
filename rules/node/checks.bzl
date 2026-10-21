"""What the Node rules refuse at analysis (npm.bzl, modules.bzl, defs.bzl), as functions of plain values.

Each check takes the values it judges and `refuse`, which is `fail` in a rule: the build stops at the first refusal, with its message. A test passes a
recorder instead (rules/rust/refusal.bzl) and reads what was refused (rules/node/tests).
"""

# ---- npm_package ---------------------------------------------------------------------------------------------------------------------------

def check_package_path(path, refuse = fail):
    """v0: the BUCK file sits next to package.json."""
    if path not in ("", "."):
        refuse("npm_package: path must be \".\" (the BUCK file next to package.json); got {}".format(repr(path)))

def check_table(table, schema, pinned_node, node_given, refuse = fail):
    """The generated table is given, is of the schema these rules read, and was made for the node they pin (unless the caller names its own `node`)."""
    if table == None:
        refuse("npm_package: `table` is required; load npm_package from the generated buildrules.bzl (`buildrules npm sync` writes it)")
        return
    if table["SCHEMA"] != schema:
        refuse("npm_package: the table has SCHEMA {}, these rules read {}: run `buildrules npm sync`".format(table["SCHEMA"], schema))
    if not node_given and table["NODE"] != pinned_node:
        refuse("npm_package: the table was made for node {} and buildrules pins {}: run `buildrules npm sync`".format(table["NODE"], pinned_node))

def check_srcs_without_package_json(srcs, refuse = fail):
    if "package.json" in srcs:
        refuse("npm_package: srcs must not hold package.json; the steps read the normalized copy (:package.json.steps)")

def check_action(act, chain, steps, reserved, refuse = fail):
    """A policy action is a new name, and a chain of steps."""
    if act in steps or act in reserved:
        refuse("npm_package: the action {} has a step's or a target's name".format(act))
    for s in chain:
        if s not in steps:
            refuse("npm_package: the action {} names {}, which is not a step ({})".format(act, s, ", ".join(steps)))

def merge_staged(dicts, refuse = fail):
    """The files staged for a step, from several maps; one destination with two sources is refused."""
    out = {}
    for d in dicts:
        for k, v in d.items():
            if k in out and out[k] != v:
                refuse("npm_package: {} is staged twice, as {} and as {}".format(k, out[k], v))
                continue
            out[k] = v
    return out

# ---- npm_modules and the tree -------------------------------------------------------------------------------------------------------------

def check_same_packages(where, what, a, b, refuse = fail):
    """Two maps keyed by package (`what` names them) name the same packages."""
    if sorted(a) != sorted(b):
        refuse("{}: {} name different packages".format(where, what))

def check_tarballs_cover(name, keys, tarballs, refuse = fail):
    """Every locked package has a tarball in `tarballs` ({key: label})."""
    for key in keys:
        if key not in tarballs:
            refuse("npm_modules {}: tarballs has no {}".format(name, key))

# ---- node_tree_run and its macros --------------------------------------------------------------------------------------------------------

def check_program_or_script(where, program, script, refuse = fail):
    if (program == "") == (script == None):
        refuse("{}: name exactly one of program and script".format(where))

def check_source(where, what, is_source, refuse = fail):
    """`srcs` are files of the repository: a build output goes in `data`, {dest: source}."""
    if not is_source:
        refuse("{}: {} is a build output; name it in data, {{dest: source}}".format(where, what))

def check_not_listed(where, dest, staged, refuse = fail):
    if dest in staged:
        refuse("{}: {} is listed twice".format(where, dest))

def check_data_is_not_a_source(where, dest, staged, refuse = fail):
    if dest in staged:
        refuse("{}: data destination {} is also a source".format(where, dest))

def check_out_dir(where, out_dir, refuse = fail):
    if out_dir != None and (out_dir == "" or out_dir.startswith("/") or ".." in out_dir.split("/")):
        refuse("{}: out_dir {} must be a relative directory of the package".format(where, repr(out_dir)))

def check_max_workers(name, n, refuse = fail):
    if n < 1:
        refuse("jest_test {}: max_workers must be at least 1".format(name))

# ---- npm_tarball and node_test ---------------------------------------------------------------------------------------------------------------

def check_package_pin(where, k, have, version, refuse = fail):
    """A package is at one version in a closure: `have` is the version already in it (or None)."""
    if have != None and have != version:
        refuse("{}: {} is pinned at {} and at {} in its deps".format(where, k, have, version))

def check_exe(where, exe, refuse = fail):
    if exe == "":
        refuse("{}: exe is empty: name the package's executable, or leave exe out".format(where))

def check_not_own_dep(where, package, closure, refuse = fail):
    if package in closure:
        refuse("{}: {} is in its own deps".format(where, package))

def check_expect_error(where, expect_error, refuse = fail):
    if expect_error == "":
        refuse("{}: expect_error is empty: name the text the script must print on stderr, or leave expect_error out".format(where))

def check_not_a_package(where, k, staged, refuse = fail):
    if "node_modules/" + k in staged:
        refuse("{}: data destination node_modules/{} is also a package of deps".format(where, k))
