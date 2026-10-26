# check

What a rule's build action runs instead of a shell script, as one static Zig executable. The checks and markers of the rules run it: `run_check`, `c_check`, `mojo_same`, the run and the gate of a Mojo test,
`rust_test` and the Rust test runs (`test_run`, the welded copy), the pinned `rustc --version` and the cargo table check; ci/faulty holds that each is
red when its check fails. Every command writes its output
file only when it succeeded, and whole (a temporary file renamed into place). Exit status: 0 done; 1 the check failed; 2 the command line is
wrong; for `run` and `marker` the program's own status (127 not there, 126 not runnable, 128+signal when a signal ended it).

| command | what it does |
|---|---|
| `run [OPTIONS] -- PROGRAM [ARG]...` | starts the program in a prepared environment and exits with its status. `--refuse MESSAGE` starts nothing: it writes the message and exits 2 (the stand-in for a tool a toolchain does not provide). |
| `expect --want TEXT --out FILE [--prefix] [--name NAME] [OPTIONS] -- PROGRAM...` | the program's stdout, without trailing newlines, equals TEXT (or starts with it); then FILE holds it and a newline. |
| `marker --out FILE [--capture] [--stamp TEXT \| --stamp-log] [OPTIONS] -- PROGRAM...` | runs a test; FILE is written only if it passed. `--capture` holds the output back and writes it to stdout if the test failed. |
| `digest [--out FILE] [--stamp TEXT] (EXPECTED FILE NAME)...` | each file hashes to `sha256:<hex>`, `sha512:<hex>` or an integrity string `sha512-<base64>`. |
| `same --out FILE [--stamp TEXT] A B` | the two files are the same bytes; the first difference is named. |
| `copy SOURCE DESTINATION` | a file copied with its permission bits, whole or not at all. |
| `isa --objdump P --binary F --expect avx2\|none --label L --out REPORT` | runs `P -d --no-show-raw-insn F` and counts `ymm` instructions against the ISA level (what `rules/rust/isa_audit.bzl` does). |

## Starting a program (`run`, `marker`, `expect`)

The environment is built in this order: the process's own (nothing with `--clear-env`); each `--env NAME=VALUE`; each `--dir NAME=SUB` (the
absolute path of SUB in the scratch directory, made); `--tmpdir` (TMPDIR is `$BUCK_SCRATCH_PATH` made absolute); `--ld-library-path DIR`
(replaces, made absolute); each `--abs NAME` and `--abs-prefix PREFIX` (a relative value becomes absolute); each `--mkdir-env NAME` (the
directory it names is made). `--scratch NAME` makes a private directory (`$BUCK_SCRATCH_PATH/NAME`, or `.buildrules_NAME` without one), emptied
before the run and removed after. The program runs in `--cwd`, or the directory `--cwd-env NAME` names, or the working directory. It is never
looked for in a `PATH`: its name must contain a `/`, and a relative one is made absolute first.

`--private-scratch` makes a directory of the run's own, `buildrules_test.<random>` in `$BUCK_SCRATCH_PATH` (made absolute), else `$TMPDIR`, else `/tmp`
(install_root.zig), and removes it after the run. TMPDIR and TEST_TMPDIR are an empty directory in it, HOME another; they are set after `--tmpdir` and replace
what `--env` gave. It is how a Mojo test run is given its scratch (docs/contract.md, section 12.9), so two tests never share one. `--installed` (it needs
`--private-scratch`) runs the program from a fresh root in that directory: the directory that holds the program is copied to `<root>/bin` (the program is
`<root>/bin/<name>`, and its `lib/` is beside it), `--install-share DIR` copies a tree to `<root>/share` (which exists, empty, without it), `--share-env NAME` is
the absolute path of `<root>/share`, and the working directory is `<root>` unless `--cwd` or `--cwd-env` says another. `cov_run` (rules/coverage) makes the same
directories from the same file for the coverage run.

## What differs from the shell script it replaced

The rules that moved from `sh -c` to `check` (`run_check`, `c_check`, `mojo_same`, the Mojo and Rust test runs, the welds, the version and table checks) see these differences:

- The program gets the environment the action has (on the farm only `HOME`, `HOSTNAME` and `BUCK_SCRATCH_PATH`), plus the options above. A shell set `PWD`, `OLDPWD` and `SHLVL` for what it ran, and `PWD` was the package directory for a cargo test after its `cd`; `check` sets none of them, so they are unset. A test that reads `PWD` now finds it unset and must use its working directory.
- In capture mode (`expect`, `marker --capture`) the program's stdin is empty. A shell script left it as the action's own.
- `expect` writes the bytes the program printed, less trailing newlines, and one newline. The old `echo "$GOT" > out` took an output of exactly `-n` for its own flag (`-n x` was printed as it is) and dropped it; `check` keeps it. (The pinned busybox `echo` did not interpret backslash escapes, and neither does `check`.)
- Exit status: `run_check` and the version check exited with the program's status when it failed (N, or 127 when it was not found); `expect` exits 1 for any failure. (`c_check` always exited 1, and still does.)
- A failed `marker` exits with the test's own status. The Mojo run already did; the cargo and Rust test scripts exited 1. What is new in the Mojo run is the `TEST FAILED: <program>` line on stderr.
- The cargo test marker (the test's output, `--stamp-log`) is all of stdout and then all of stderr; the script interleaved them as they came.
- A file `digest` cannot read says `cannot read`; the script said `STALE`, with an empty hash.
- The `same` message (the first difference) is on stderr; `cmp` wrote its own.
- The wording of every message changed. The cases of ci/faulty pin the new wording (ci/negative.bzl, `FAULTY`), so a change of it is a change of those rows.
- The rules no longer take a `busybox` attribute: it is removed from `run_check`, `c_check`, `mojo_same`, `mojo_test_run_rule`, `mojo_gated_lib_rule` and the gate fixture (ci/mojo_gate). A BUCK file that still passes `busybox =` to one of them is an error at once, when the graph is loaded.

## Tests

The cases start the toolbox (`rules/toolbox`) as the program: `printenv` reads the environment back, `mkdir -p` and `cat` the working
directory, `true`/`false` the status. Digests are the published test vectors. `check_exe_test.zig` runs the built executable.
