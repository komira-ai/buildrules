"""The names of packages in mopm's unit graph (mopm's spec/unit-graph.md, "Names").

A graph of format 6 names every package by its full name, `<namespace>/<name>` (`example/json`): the unit ids (`example/json@0.1.0#mojo1.0.0/lib`), a unit's `package`,
the `package` of a native entry, a native unit's id (`native:example/json/<id>`) and the root `package`. Each unit also says its `import`, the part after the `/`: the name
Mojo code imports, the library's directory (`src/json`), its `.mojoc` (`json.mojoc`) and the directory its sources are staged in. Two packages of one import name never
meet in one graph (mopm refuses the closure), so the import name alone names a library within a package's build.

A graph before format 6 names a package by its import name alone, and has no `import`. So `import_name` of a package name is the same function for every format, and
every target name, file name and directory these rules make from a package is made from it: a package of an older graph keeps every name it had.
"""

# The first format whose packages have full names and whose units say `import`.
NAMES_FORMAT = 6

def import_name(package):
    """The import name of the package `package`: the part after the last `/` of a full name (`json` for `example/json`), or the whole of a name of a graph before
    format 6, which has none."""
    return package.rpartition("/")[2]

def check_import_names(who, graph, refuse = fail):
    """Every unit of `graph` has the `import` mopm prints: in a graph of format 6 a string, the name of its package's full name `<namespace>/<name>`; before format 6
    none (`import` is a format 6 key). The rules stage and name a library by it, so a graph that says another would build a `.mojoc` its importers do not look for.
    `refuse` is `fail` in a build; a test passes a recorder (rules/rust/refusal.bzl)."""
    fmt = graph["unit_graph"]
    for u in graph["units"]:
        package = u.get("package", "")
        if fmt < NAMES_FORMAT:
            if "import" in u:
                refuse("{}: {} has `import` in a graph of format {}; it is a format {} key: run `buildrules mojo sync`".format(who, u["id"], fmt, NAMES_FORMAT))
        elif "import" not in u:
            refuse("{}: {}, a unit of a graph of format {}, has no `import`: run `buildrules mojo sync`".format(who, u["id"], fmt))
        elif "/" not in package or u["import"] != import_name(package):
            refuse("{}: {} has `import` {} but its package is {}: in a graph of format {} a package is `<namespace>/<name>` and its import name is the name".format(
                who,
                u["id"],
                repr(u["import"]),
                repr(package),
                fmt,
            ))
