# check

What a rule's build action runs instead of a shell script, as one static Zig executable. The runner rules start zig through `run` (`zig_exe`, `c_exe`, `c_shared`, Node's `c_shared_lib`, the Rust toolchain's
`zig_exe`) and the C/C++ toolchain's refusals are `run --refuse`; the section "What differs: the zig and cc runners" below says what changed. Every command writes its output
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

## Tests

The cases start the toolbox (`rules/toolbox`) as the program: `printenv` reads the environment back, `mkdir -p` and `cat` the working
directory, `true`/`false` the status. Digests are the published test vectors. `check_exe_test.zig` runs the built executable.

## What differs: the zig and cc runners

`zig_exe` (rules/zig/zig.bzl), `c_exe` and `c_shared` (rules/cxx/defs.bzl), Node's `c_shared_lib` (rules/node/defs.bzl) and the Rust toolchain's `zig_exe`
(rules/rust/toolchain.bzl) ran `busybox sh -euc SCRIPT`: the script made a scratch directory and a directory of links to every busybox applet, set `PATH` to
that directory, set the cache variables and `HOME`, ran zig and removed the scratch directory. They now run `check run --scratch NAME --dir ...` with zig as the
program (`zig_run` in rules/zig/zig.bzl): the same scratch path (`$BUCK_SCRATCH_PATH/NAME`, `NAME` being `buildrules`, `c_exe`, `c_shared`, `buildrules` and `br`), the same
three variables with the same values, the same working directory. Each difference below was read on the farm, the old script and the new command side by side,
and the executables and libraries they build are the same bytes (compared on the farm with the old command kept for the purpose; the two builds embed the
path of their staged source, which names the target, so a pair built under two target names differs in exactly those characters: 6 bytes of a 188736-byte `c_exe`,
12 of a 4616-byte shared library; `zig_exe`, `c_shared` and the Rust `zig_exe` are byte for byte equal).

| | old (`busybox sh -euc`) | new (`check run`) |
|---|---|---|
| `PATH` | the directory of applet links, in the scratch directory (the Rust toolchain's script left the action's own, which is none) | the action's own, which on the farm is none: zig builds the same bytes without one |
| `PWD`, `SHLVL` | set by the shell (`PWD` the action's root, `SHLVL=1`) | not set |
| other variables | `BUCK_SCRATCH_PATH`, `HOME` (as set below), `HOSTNAME`, the three cache variables | the same, less `PATH`, `PWD` and `SHLVL` |
| working directory | the action's root | the same |
| exit status of zig | `set -e` ended the script with it (3 stays 3) | `run` exits with it (3 stays 3) |
| zig's `argv[0]` | the path as the rule wrote it (relative to the action's root; `sh` printed it so) | absolute (`check run` makes a program with a `/` absolute against the working directory; the stand-in zig checks it) |
| zig not there | `sh: buck-out/nowhere/zig: not found` (the path as written, relative), status 127 | `check run: cannot run <root>/buck-out/nowhere/zig: FileNotFound` (absolute; `<root>` is the action's root), status 127 |
| zig's stdout and stderr | passed through | passed through |
| the Node library's `-o` | an absolute path | the path as the action names it, relative to the same working directory |

The C/C++ toolchain's refusals (`nm`, `objcopy`, `strip`, the prelude's internal tools, the Python bootstrap interpreter) were `busybox sh -c 'echo MESSAGE >&2; exit 2'`
and are `check run --refuse MESSAGE --`: the same message on stderr, nothing on stdout, status 2, and the arguments a prelude action appends to a tool (`-c`,
`--flag=value`, an input, an output) are still ignored, because the command ends with `--` and `--refuse` starts nothing. Without that `--` the first appended
argument is an option `check` does not know, and the message is `check run: unknown option -c` instead.

`check` and `toolbox` are built by `zig_exe(bootstrap = True)`, which runs zig directly with its caches in the action's working directory (as `zig_bootstrap_exe` does): `check run`
builds every other `zig_exe`, so building `check` with it would be a cycle, and the unit tests of `check` start the toolbox.

The rules no longer take a `busybox` attribute: `zig_exe`, `c_exe`, `c_shared`, Node's `c_shared_lib`, the Rust toolchain's `zig_exe`, `zig_cxx_toolchain`,
`no_python_bootstrap_toolchain` and `cxx_toolchains()`. A BUCK file that still passes one is an error when the graph is loaded. Node's `c_shared_lib` takes its compiler as
`zig` (it was the private `_zig`), so a test can give it a stand-in.

## Tests of the runners

`//ci/runners` (built by `//ci:all`) builds each runner rule against a stand-in zig (`ci/runners/stand_in.zig`) that accepts only the command line and the
environment the rule is meant to give: a dropped or changed argument, a missing or misplaced cache directory or `HOME`, a wrong scratch name, or a working directory
that is not the action's, makes the build red, and the message names the difference. `//ci:negative.bxl:check` also builds the planted defects there (`RUNNERS` in
ci/negative.bzl) and requires each one red for its reason: a `zig_exe` given another optimize mode and another strip flag, and every tool the C/C++ toolchain refuses.
