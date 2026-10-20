"""`site_preview`: `buck2 run` serves a built site on 127.0.0.1 with the pinned Node.js.

The target builds nothing itself. Its run command is `node serve.js <dist> [port]` (under the pinned busybox's `env`, which sets the library path), where `node` is the hermetic Node.js
of buildrules//rules/node (the same one that built the site) and `<dist>` is the output of the `dist` target, which Buck2
builds on the farm and materializes first. Serving is not a compile: the only local work is a small HTTP server reading
files. Extra arguments go to the server: `buck2 run //site:preview -- 9000` sets the port.
"""

load("@buildrules//rules/node:defs.bzl", "NodeDistInfo")

def _impl(ctx):
    node = ctx.attrs.node[NodeDistInfo]
    busybox = ctx.attrs.busybox[DefaultInfo].default_outputs[0]
    dist = ctx.attrs.dist[DefaultInfo].default_outputs[0]
    return [
        DefaultInfo(),
        RunInfo(args = cmd_args(
            busybox,
            "env",
            # node links the C++ runtime from pinned conda packages, not from the host.
            cmd_args(node.native_libs.project("lib"), format = "LD_LIBRARY_PATH={}"),
            node.root.project("bin/node"),
            ctx.attrs.script,
            dist,
        )),
    ]

site_preview = rule(
    impl = _impl,
    attrs = {
        "busybox": attrs.exec_dep(default = "buildrules//rules/pins:busybox"),
        "dist": attrs.dep(),
        "node": attrs.exec_dep(providers = [NodeDistInfo], default = "buildrules//rules/node:node"),
        "script": attrs.source(),
    },
)
