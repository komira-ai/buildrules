"""The `unpack` program as a pinned download, one release asset per host (tools/bootstrap).

Every action that unpacks an archive needs a program that can unpack before anything else has been unpacked, and Buck2 has none of its own (its `download_file` does not
extract; the prelude's unarchive shells out to the host's `tar`). So `unpack` is built by this repository's own tooling from tools/bootstrap/src, and the three builds
(linux x86_64, linux aarch64, macOS aarch64) are published as assets of a release of this repository under a tag of their own, `UNPACK_TAG`, one asset per host named
`unpack-<host>`. The rows below pin each asset by sha256 and size, as every other download here is.

The rows are the bytes the source makes: the build is reproducible, and //ci:unpack_pin_check (tools/bootstrap:pin_check_unit) builds the program for each host from the tree
and requires the sha256 and size here to be its. When the source changes the check is red, naming the new values; the new programs are published under the next tag
(`unpack-2`, ...: a release asset is never replaced), `UNPACK_TAG` and the rows are updated together. The upload is a step the repository owner runs
(tools/held/publish_unpack.zig); until the asset exists these rows cannot be fetched on a machine whose cache lacks it, so no target in the default build uses them.
"""

UNPACK_TAG = "unpack-1"

UNPACK_PINS = {
    "linux-x86_64": {
        "url": "https://github.com/komira-ai/buildrules/releases/download/unpack-1/unpack-linux-x86_64",
        "sha256": "34918575b510f72891731f1da2e9e9326c8fd1dbab5438d0593561371fcd654b",
        "size": 143112,
    },
    "linux-aarch64": {
        "url": "https://github.com/komira-ai/buildrules/releases/download/unpack-1/unpack-linux-aarch64",
        "sha256": "18a3f7f94b14a4bfdefc0098ff43ec5d08ae792305e2e780a257638f417191b7",
        "size": 129192,
    },
    "macos-aarch64": {
        "url": "https://github.com/komira-ai/buildrules/releases/download/unpack-1/unpack-macos-aarch64",
        "sha256": "b0fd4c225ec7cbbc7c649e566a350013cd9c0d00927a799f3566570866101944",
        "size": 163320,
    },
}
