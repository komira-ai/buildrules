# postgres

A Postgres for the Rust tests of a workspace: a cargo test target whose package declares `postgres = { url-env = "NAME" }` in
`[package.metadata.buildrules]` (or the workspace's) is run by `pg_run`, which starts a private server for that one run and names it in `NAME`.

This directory holds the pinned packages and the tree (`pins.bzl`, `defs.bzl`, `BUCK`: `:prefix`) and the two Zig tools below.

## pg_prefix

```
pg_prefix --out DIR --postgres POSTGRESQL.conda [OTHER.conda]...
```

Unpacks the packages into one tree, as conda would install them. A `.conda` is a zip of stored members: `pkg-<name>.tar.zst` (the payload) and
`info-<name>.tar.zst`. Every payload is written under `DIR` (which must not exist, or be empty): files with mode 0755 when the tar header has an
execute bit and 0644 otherwise, directories, symbolic links as links.

- Refused, naming the member (one line `pg_prefix: ...` on stderr, exit 1, `DIR` removed): a path that is absolute or has a `..` component, a hard
  link, a symbolic link that is absolute or climbs out of `DIR`, a member under a link the tree holds (links that chain could name a directory outside `DIR`), a member over 512 MiB, a path two packages hold with different contents (the same
  contents is kept once), an archive that cannot be read, a `DIR` that is not empty.
- Not written: `info/` (package metadata, never installed: two packages carry different `info/licenses/COPYING`), `include/`, `share/doc/`, `share/man/`, `share/info/`, `share/locale/`, `lib/pkgconfig/`, `lib/cmake/`, `lib/pgxs/`, and every
  file whose name ends in `.a`. The fixture runs the server only.
- `DIR/buildrules-placeholder.txt` holds, with no newline, the prefix placeholder conda-forge compiled into `bin/postgres` and `bin/initdb`, read from
  the `--postgres` package's `info/paths.json` (both listed, `file_mode` "binary", the same placeholder).

A wrong command line is exit 2.

## pg_run

```
pg_run --prefix DIR --url-env NAME -- PROGRAM [ARG]...
```

`DIR` is the tree `pg_prefix` made. One run:

1. The run directory `<base>/buildrules_pg.<8 hex>`, `<base>` being BUCK_SCRATCH_PATH (made absolute), else TMPDIR, else `/tmp`; and a socket
   directory `<TMPDIR or /tmp>/buildrules_pgs.<8 hex>` of its own. A Unix socket path holds 107 bytes at most and a scratch path may be longer than that,
   so the socket is in TMPDIR (21 bytes on the farm). A local action's TMPDIR is its scratch directory under buck-out, which can be too long (151 bytes
   on a hosted runner): then the socket directory is made in `/tmp`, the same fresh directory of its own. A path that fits in neither is refused, naming
   both lengths, before anything is made.
2. `<run>/pg/bin/{postgres,initdb}` are copies of the tree's with the placeholder replaced by `<run>/pg`, the way conda does it for a binary file:
   each C string that holds the placeholder has it replaced and is padded with NULs to its old length, so offsets and size do not change. (The server finds
   its timezone files through that compiled-in path.) `<run>/pg/lib` and `<run>/pg/share` are links to the tree's.
3. `initdb -D <run>/data -U postgres -A trust -E UTF8 --locale=C --no-sync --no-instructions` with `LC_ALL=C`.
4. `postgres -D <run>/data -k <socket dir> -p 5432 -c listen_addresses= -c fsync=off -c synchronous_commit=off -c full_page_writes=off`: no TCP, no
   durability; ready when the 8th line of `postmaster.pid` is `ready` (what `pg_ctl -w` waits for), within 300 s.
5. `PROGRAM` (a path, never looked for in PATH) with `NAME=postgresql://postgres@<socket dir, percent-encoded>:5432/postgres` added to its environment.
6. SIGINT to the server (fast shutdown), SIGKILL after 120 s; both directories removed.

The exit status is `PROGRAM`'s (128+N for signal N, 127 when it is not there, 126 when it cannot be run), unless the fixture failed (initdb or the
server failing, not ready in time, gone while the test ran, failing when stopped): that is said in one line `pg_run: ...` and is exit 1. A wrong
command line is exit 2.

Processes and time go through a platform struct (`pg_run.zig` `Plat`); `pg_plat.zig` is the real one and the unit tests use a fake with a clock that
only counts, so no test waits or asserts a time.

## Tests

| file | what it runs |
|---|---|
| `conda_test.zig` | the zip walk (stored members, zip64, refusals), member paths, links, `info/paths.json` |
| `pg_prefix_test.zig` | the tool on `.conda` files built in memory (`conda_fixture.zig`): tree, modes, links, drops, conflicts, each refusal, every allocation failing in turn |
| `pg_run_test.zig` | the tool with a fake platform: the patch, the URL, the whole run, every fixture failure, every allocation failing in turn |
| `pg_plat_test.zig` | the real platform on real processes (the toolbox's `true`, `false`, `sleep`; `fake_pg`) |
| `pg_exe_test.zig` | the built `pg_prefix` and `pg_run` as processes, with `fake_pg` as the server |

`fake_pg.zig` is a stand-in for the server and initdb of the process tests; it is never an input of a rule. The coverage is measured on `all_test.zig`
(every case of the first four files in one test program); the floor in `coverage_floor.txt` is exact, as everywhere (`rules/coverage/README.md`).
