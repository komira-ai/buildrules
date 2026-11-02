"""What mopm's unit graph says about linking (formats 4 and 5; docs/contract.md, section 12.4).

    {"id": "native:p/shim", "kind": "native", "soname": "libshim.a", "provided": true, ...}      format 4: the archive is a target of the build, not compiled from sources
    {"id": "p@1.0.0#mojo1.0.0/test:t", "kind": "test", "natives": [...], "link": ["c++", "m"]}  format 5: the system libraries the unit's final link adds

`link` is mopm's, whole: the `link` of the unit's natives (`[native.<id>] link = ["c++"]` in mopm.toml, carried by the metadata of a published package and by the lock), each name once,
in mopm's order (c++, dl, m, pthread). The unit rule writes it as the end of the link line (rules/native/link.bzl) and nothing else decides it. A graph is held to what mopm prints:
`link` only in a graph of format 5 and never on a native unit (an archive is not linked), `provided` only in format 4 or later and only on a native unit.
"""

load("//rules/native:link.bzl", "check_link_names")
load(":system_libs.bzl", "LINK_FORMAT", "PROVIDED_FORMAT")

def unit_link(u):
    """The system libraries of the unit's final link, in mopm's order (empty for a unit that has no `link`: a graph made before the key existed)."""
    return list(u.get("link", []))

def is_provided(u):
    """Whether `u` is a native unit whose archive a rule of the build supplies."""
    return u.get("provided", False) == True

def check_link_keys(who, graph, refuse = fail):
    """The `link` and `provided` keys of every unit of `graph` are what mopm prints: `link` a list of the closed list's names, none twice, in a graph of format 5 and not on a native
    unit; `provided` true on a native unit of a graph of format 4 or later (false is what a unit without the key says). `refuse` is `fail` in a build; a test passes a recorder
    (rules/rust/refusal.bzl)."""
    fmt = graph["unit_graph"]
    for u in graph["units"]:
        here = "{}: {}".format(who, u["id"])
        link = u.get("link")
        if link != None:
            check_link_names(here, link, refuse)
            if type(link) == "list" and link:
                if fmt < LINK_FORMAT:
                    refuse("{} has `link` in a graph of format {}; it is a format {} key: run `buildrules mojo sync`".format(here, fmt, LINK_FORMAT))
                if u["kind"] == "native":
                    refuse("{} is a native unit and has a `link`: an archive is not linked, the units that link it have it".format(here))
        provided = u.get("provided")
        if provided != None:
            if type(provided) != "bool":
                refuse("{} has `provided` {}, which is not true or false".format(here, repr(provided)))
            elif provided:
                if u["kind"] != "native":
                    refuse("{} has `provided`, which is a key of a native unit".format(here))
                if fmt < PROVIDED_FORMAT:
                    refuse("{} has `provided` in a graph of format {}; it is a format {} key: run `buildrules mojo sync`".format(here, fmt, PROVIDED_FORMAT))

def check_same_links(graphs, base, refuse = fail):
    """Every graph gives each unit the same `link` (and the same units provided): a subdir changes the file of a library, never what its final link adds. `graphs` is
    `{subdir: graph}`, `base` the subdir the others are held to."""
    want = {u["id"]: (unit_link(u), is_provided(u)) for u in graphs[base]["units"]}
    for sd in sorted(graphs.keys()):
        got = {u["id"]: (unit_link(u), is_provided(u)) for u in graphs[sd]["units"]}
        for uid in sorted(want.keys()):
            if uid in got and got[uid] != want[uid]:
                refuse("the unit graph of {} gives {} the link {} (provided: {}) and the graph of {} gives it {} (provided: {}): run `buildrules mojo sync`".format(
                    sd,
                    uid,
                    got[uid][0],
                    got[uid][1],
                    base,
                    want[uid][0],
                    want[uid][1],
                ))

def slice_has_provided(units):
    """Whether one of `units` (the units of a graph slice) is a provided native unit: its slice then says the format that has the key."""
    return any([is_provided(u) for u in units])
