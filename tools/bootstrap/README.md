# tools/bootstrap: `unpack`

The one program an action can run before anything else has been unpacked: tar, tar.gz, tar.xz and zip. Written in Zig 0.15 with its own DEFLATE and gzip decoder and tar and zip
readers; the xz decoder is the standard library's. It reads the archive into memory (at most 1 GiB), so it needs no host tool and no temporary file.

```
unpack [--strip-components N] [--sha256 HEX] [--size BYTES] [--format tar|tar.gz|tar.xz|zip] <archive> <dest>
unpack --check [options] <archive>
```

The size and sha256 are checked first (a wrong one writes nothing); the format is told by the file's magic. `--check` reads the archive to the end, applying every rule, and writes nothing.
Exit status 0, or 2 with a message naming the archive and the entry.

## What it refuses, and the test that holds each

| rule | test file, test |
|---|---|
| an entry named with `..` anywhere (also under `--strip-components`, which would otherwise launder `../x`), or an absolute name | `tar_test.zig` "tar-slip: ...", `paths_test.zig`, `zip_test.zig` "zip-slip: ..." |
| a symbolic link whose target is absolute, or climbs above the destination, or uses `..` after a name (a link to `.` would turn `s/..` into the destination's parent) | `tar_test.zig` "tar-slip: a symbolic link ...", `paths_test.zig` "link targets: ..." |
| an entry written through a symbolic link an earlier entry made (or one already in the destination) | `tar_test.zig` "never written through a symbolic link", `extract_test.zig` |
| a cut-off archive: tar ending inside a header, its data or its padding, or between its two zero blocks; gzip and xz ending anywhere; zip structure past the end | `tar_test.zig` "truncated tar", `inflate_test.zig` and `xz_test.zig` "truncated ...: no proper prefix of a stream is accepted", `zip_test.zig` |
| a wrong gzip CRC-32 or length, bytes after the last member or stream, a wrong xz check, a wrong zip member CRC-32 or length | `inflate_test.zig`, `xz_test.zig`, `zip_test.zig` |
| a wrong archive size or sha256 | `main_test.zig` "a wrong size or sha256 is refused before anything is written" |
| devices, FIFOs, sparse files and unknown tar types; encrypted zip members and methods other than stored and deflate; an archive with no entry | `tar_test.zig`, `zip_test.zig` |

What it keeps: regular files with their permission bits `0o777` (the umask does not apply; set-uid, set-gid and sticky are dropped), symbolic links as links, hard links as copies. Directories
are made with the default mode; times, owners and groups are not restored.

## Not covered yet

`conda_unpack` (`rules/zig/conda_unpack.zig` and `rules/mojo/tools/conda_unpack.zig`) is not absorbed by this change. `unpack` reads the zip of a `.conda` package, but a package's members
are zstd-compressed tars, which `unpack` does not read, and the two copies hold policy that is not unpacking (the closure of the Mojo compiler, the install-prefix rewrite of
`modular.cfg`). Editing the Mojo copy re-keys every Mojo action (its header says so). The next step moves the zip walk onto this tool and leaves the policy where it is.

## Tests that run the built program

`real_test.zig` runs the built `unpack` on the pinned zig tarball (against the zig distribution the build unpacks today), the pinned actionlint tarball (against busybox), and a conda package.
`xz_speed_test.zig` times the real xz tarball against busybox's `xzcat`. `pin_check_test.zig` holds the pins to the built programs (docs/pins.md, "unpack").

## Publishing

The three programs are the assets of the release `UNPACK_TAG` of `rules/pins/bootstrap.bzl`. A person cannot create that tag (the tag ruleset lets only the release bot create one), so the
release is made by the dispatch workflow `.github/workflows/publish-unpack.yml`, which runs `tools/held/publish_unpack.zig` on a hosted runner (local mode):

```
gh workflow run publish-unpack.yml -R OWNER/REPO -f apply=false     # builds the programs, checks them against the pins, reads the release; changes nothing
gh workflow run publish-unpack.yml -R OWNER/REPO -f apply=true      # the same, then creates the release, uploads the assets it lacks, downloads and verifies each
```

(`OWNER/REPO` are the two path segments of `https://github.com/komira-ai/buildrules`; the scrub of this repository allows the project's name only in that address.)

Run it with `apply=false` first and read the job's output: it says what `apply=true` would do. The workflow runs only from `main` and only when dispatched. The release bot's token (the mint
step of release.yml's `tag` job, for this repository alone with `contents: write`) is minted only when `apply` is true, after the dry run has passed, and only the last step holds it. The
release points at the commit the programs were built from, and nothing is ever replaced or deleted: a second `apply=true` only verifies what is there. If the programs the tree builds are
not the pinned ones, nothing is uploaded and the output names the values to write (the new programs go under the next tag). `ci/publish_unpack_check.zig` holds the workflow to all of this.

## Limits, and what a failure leaves behind

- **Memory.** The archive is read into memory (at most 1 GiB, refused above). gzip and zip are decoded through a 64 KiB window, so a tar.gz costs about its own size: rustc 1.95.0 (`.tar.gz`, 128 MiB) peaks at 129 MiB. The standard library's xz decoder decodes a whole xz block before it
  returns any of it, and a tarball made with `xz -9` is one block, so a tar.xz costs about three times its decompressed size: the zig 0.12.0 tarball (43 MiB, about 260 MiB out) peaks at 754 MiB and rustc 1.95.0 (`.tar.xz`, 76 MiB) at 1142 MiB.
  Measured on the farm by `mem_*_unit` (`src/mem_test.zig`), which fails above 2 GiB. A faster or leaner xz path, if it is needed, replaces `src/xz.zig`; nothing else depends on how it decodes.
- **`--max-output BYTES`** refuses an archive that holds more decompressed bytes than that, in every format: the decoded tar stream (headers included) as it is produced, or the sizes a zip declares (a deflate stream that holds more than its header declared is corrupt).
  A gzip bomb stops at the limit; for a tar.xz the limit stops the writing, not the memory of the block in hand. Without it there is no limit.
- **A failed extraction leaves a partly written destination.** The files before the failing entry are there. The caller discards the destination (a Buck2 action's output is discarded when the action fails); `unpack` never deletes anything.
- **`--strip-components` counts `.`** as a component, as GNU tar and busybox do (`./a/b` under 1 is `a/b`); it never keeps one.
- **Huffman codes are checked like zlib's `puff.c`:** an over-subscribed code is refused, and so is an incomplete one except a single code of length 1 (or none, for a block without matches); the code-length code must be complete.
- **Names with a backslash.** A tar entry's name is taken as it is (on Linux and macOS a backslash is a character of a file name, which is what GNU tar does); a zip member's name with a backslash is refused, since the zip format's separator is `/` and a backslash there comes from a program that wrote Windows paths.
