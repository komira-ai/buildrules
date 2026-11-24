"""The graph of the check set, asked of Buck2 from a BXL script.

`make_graph` is the facade `select` (select.bzl) selects over: owners, packages, the loaders of a `.bzl` and reverse dependencies, all
unconfigured (uquery). `without_left_out` drops the targets the configuration's `excluded` rows name. Both take the `ctx` of the
consumer's BXL script: paths are relative to `ctx.cell_root()`, the root of the cell that script lives in.
"""

def _label(node):
    return str(node.label)

def _is_buck_file(f):
    return str(f).split("/")[-1] == "BUCK"

def make_graph(ctx, scope, excluded):
    """The facade over the real graph. `scope` is a list of target patterns,
    `excluded` a pattern removed from the universe the reverse-dependency
    query answers over (the aggregate's package)."""
    uq = ctx.uquery()
    cell = ctx.cell_root()
    scope_expr = " + ".join(["(" + s + ")" for s in scope])
    state = {}

    def exists(path):
        return ctx.fs.exists(cell + "/" + path)

    def owners(path):
        return [_label(t) for t in uq.owner(path)]

    def package_targets(d):
        return [_label(t) for t in uq.targets_in_buildfile(d + "/BUCK" if d else "BUCK")]

    def including(bzl):
        if "buildfiles" not in state:
            state["buildfiles"] = uq.buildfile(uq.eval(scope_expr))
        loaders = [str(f) for f in uq.rbuildfiles(state["buildfiles"], bzl) if _is_buck_file(f)]
        if not loaders:
            return []
        return [_label(t) for t in uq.targets_in_buildfile(loaders)]

    def rdeps(seeds):
        if "universe" not in state:
            state["universe"] = uq.eval("({}) - {}".format(scope_expr, excluded))
        return [_label(t) for t in uq.rdeps(state["universe"], seeds)]

    return struct(exists = exists, owners = owners, package_targets = package_targets, including = including, rdeps = rdeps)

def without_left_out(ctx, targets, left_out):
    """`targets` (labels) without those the patterns of `left_out` match: the
    selector leaves out what the aggregate leaves out (the `excluded` rows of
    the configuration), so a change to a file an excluded target owns never
    selects it."""
    if not left_out or not targets:
        return list(targets)
    gone = {str(t.label): True for t in ctx.uquery().eval(" + ".join(["(" + p + ")" for p in left_out]))}
    return [t for t in targets if t not in gone]
