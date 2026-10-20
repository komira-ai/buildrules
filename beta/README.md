# beta: hello-world repositories that consume buildrules as a user does

Each directory is the files a user writes in a new repository of one language, and `STEPS`, the commands a user types (the format is the comment
at the top of `tools/stage/steps.zig`). The beta job of the automatic release (RELEASING.md) copies a directory to a fresh place outside this
checkout, runs `buildrules init` with the candidate commit as an external cell, runs the steps, builds, runs what it built, and builds a second
time from nothing to see that every output is the same bytes.

| directory | what |
|---|---|
| `rust` | `buildrules cargo new`, `sync`, `check`; build, test, lint and run the binary |
| `cxx` | a C and a C++ program on the pinned zig |
| `zig` | a Zig program with its unit test welded to it |
| `node` | a Node package: `npm sync`, `npm check`, test and build scripts, a `dist` directory |
| `mixed` | a Rust package, a C program, a Zig program and a Node package in one repository |
| `mojo` | a Mojo package; planned until mopm's first release (`planned-until mopm-release`) |

A file named `BUCK.beta` is the user's `BUCK` file: it is kept under that name here so that this repository's own Buck2 graph does not read
a user's repository as packages of its own, and the job writes it as `BUCK`. Nothing in this directory is built by `//ci:all`; the beta job builds
it as a user would (ci/all.bzl lists the directory with its reason, and `//beta:beta_check` checks what this paragraph says).

Run one by hand from a checkout with `buildrules` and `buck2` built or installed:

    stage beta --root . --lang zig --work /path/outside/the/checkout --origin <repository url> --commit <40 hex> \
      --buck2 /path/to/buck2 --buildrules /path/to/buildrules --exec local
