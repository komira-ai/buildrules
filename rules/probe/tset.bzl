"""P1 probe: does a transitive set, a provider and a record cross cells? Analysis only."""

ProbeTSet = transitive_set()

ProbeInfo = provider(fields = {
    "name": provider_field(str),
    "tset": provider_field(typing.Any),
    "listed": provider_field(list),
})

def _impl(ctx):
    tset = None
    if ctx.attrs.use_tset:
        children = [d[ProbeInfo].tset for d in ctx.attrs.deps]
        tset = ctx.actions.tset(ProbeTSet, value = ctx.label.name, children = children)
    listed = []
    for d in ctx.attrs.deps:
        listed += d[ProbeInfo].listed
    listed.append(str(ctx.label))
    return [DefaultInfo(), ProbeInfo(name = ctx.label.name, tset = tset, listed = listed)]

probe_node = rule(
    impl = _impl,
    attrs = {
        "deps": attrs.list(attrs.dep(providers = [ProbeInfo]), default = []),
        "use_tset": attrs.bool(default = True),
    },
)
