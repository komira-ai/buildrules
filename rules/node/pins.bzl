"""The hermetic Node.js: the runtime and the npm packages, each pinned twice.

Read by this package's BUCK, which declares the downloads and the unpacked
targets. Keeping the runtime and esbuild.
(`pinned_file`, checked when it is fetched). The Node archive's sha256 is the
one its release's signed `SHASUMS256.txt` lists; each npm tarball also carries
the registry's `dist.integrity` (`sha512-<base64>`), which `npm_tarball`
checks again before it unpacks the tarball. `license` is the SPDX expression
README.md records (Licences); `deps` are the packages a package imports at run
time, by `name`.
"""

NODE = {
    "name": "node",
    # Node 24, the active LTS line ("Krypton"), released 2026-09-07; the
    # newest 24.x release in nodejs.org's release index (dist/index.json).
    "version": "24.21.0",
    "archive": "node-v24.21.0-linux-x64.tar.gz",
    "top": "node-v24.21.0-linux-x64",
    "url": "https://nodejs.org/dist/v24.21.0/node-v24.21.0-linux-x64.tar.gz",
    "sha256": "6e1db87ef58b8819e5d5402eff1536491b18edd8eb7bee5ef7897876e88dc5ff",
    "size": 58088022,
    "license": "MIT",
}

def _npm(name, version, url, sha256, size, integrity, license, deps = [], exe = None):
    return {
        "deps": deps,
        "exe": exe,
        "file": "npm-" + url.rsplit("/", 1)[1],
        "integrity": integrity,
        "license": license,
        "name": name,
        "sha256": sha256,
        "size": size,
        "url": url,
        "version": version,
    }

NPM = [
    # esbuild's linux x86_64 binary (a static Go executable), the package the
    # `esbuild` npm package installs on that platform; `exe` must print the
    # version.
    _npm(
        "@esbuild/linux-x64",
        "0.28.2",
        "https://registry.npmjs.org/@esbuild/linux-x64/-/linux-x64-0.28.2.tgz",
        "9573bb2233aab0f9ea7647d5cca9726113cc1768de61d66b17267f4db84488f6",
        4741809,
        "sha512-4xTZr1FUmSoQW4XIWmit3tzQrUTZM+N3P0XV8xROKYF50XfI7xeO90+1bZvNwxIufQ9hDQVRJH5YhgPVF8A/HQ==",
        "MIT",
        exe = "bin/esbuild",
    ),
]

def npm_target(name):
    """The target name of an npm package: its name without the scope's `@`, `/` as `_` (`@esbuild/linux-x64` -> `esbuild_linux-x64`)."""
    return (name[1:] if name.startswith("@") else name).replace("/", "_")
