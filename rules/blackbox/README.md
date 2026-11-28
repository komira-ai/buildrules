# blackbox

A black-box test as one `buck2 test` target: a base image, the packages put onto it (the service under test and every fake the test wants), and a
driver run in it once they are there. The target carries its own remote-execution properties and runs on the farm.

```
load("@buildrules//rules/blackbox:defs.bzl", "blackbox_test")
```

This directory holds the rule (`defs.bzl`, `checks.bzl`), the runner `blackbox_run` (the Zig sources below, `BUCK`), the toy that proves it
(`toy/`, `tests/`) and its tests.

## A service repository's test

```
blackbox_test(
    name = "store_blackbox",
    # The base image, by digest (a tag is refused). Today, the farm's one base image (below).
    image = "docker://docker.io/library/ubuntu@sha256:<64 hex digits>",
    # The packages put onto the image, in this order: the service under test, then the fakes. Each is pinned, or built in the same build.
    packages = [
        {
            "url": "https://github.com/<owner>/<repo>/releases/download/v1.4.0/store_1.4.0_amd64.deb",
            "sha256": "<64 hex digits>",
            "size": 8812345,
            # A release passes the package it is about to publish by these keys (below).
            "candidate": "store",
        },
        "//tests/fakes:object_store_deb",
    ],
    # The program run once the packages are on the image; the test is its status.
    driver = "//tests/blackbox:store_driver",
)
```

| argument | what it is |
|---|---|
| `image` | `[docker://]<repository>@sha256:<64 lower-case hex>`. A tag, alone or beside the digest, a missing or malformed digest, and a missing repository are refused when the BUCK file loads. |
| `packages` | a non-empty list. Each is a pin `{"url", "sha256", "size"}` (an https url, 64 lower-case hex digits, a positive length) with an optional `"candidate"`, or the label of a target whose output is a `.deb` built in the same build. The runner checks the size and sha256 of a pinned package again before it puts anything onto the image. |
| `driver` | a binary target. It is run with one argument, the root the packages were put onto (`/` on a farm), and the test passes when it exits 0. |

What a service is, its flags, which address each fake listens on, and starting and stopping them, are the driver's: the packages put the programs at
their paths, and the driver runs them.

A pin with `"candidate": "store"` is replaced, when they are given, by `-c blackbox.store_url=... -c blackbox.store_sha256=... -c blackbox.store_size=...`.
None given: the pin. All three given: they pin the package and are checked as the pin is. One or two given, or one given empty, is refused: a release
whose value went missing must not test the last release in its place. A release job, after it built the package and before it publishes it:

```
buck2 test //tests/blackbox:store_blackbox \
  -c blackbox.store_url=<where the job put the .deb> -c blackbox.store_sha256=<its sha256> -c blackbox.store_size=<its size>
```

The values change the target's inputs (the package is a pinned download of them), so a result is the result of those bytes. `ci/blackbox_candidate.bxl`
holds which package a test runs with and without the keys.

## Where it runs: the farm

The test's executor is its own: `ExternalRunnerTestInfo(default_executor = CommandExecutorConfig(local_enabled = False, remote_enabled = True,
remote_execution_properties = ...))`. Buck2 replaces the execution platform's executor with it and keeps nothing of the platform's property set, so the
rule starts from the workers' whole set (`[buildrules_re] linux_x86_64_properties`, every key: `OSFamily`, `ISA` and the rest) and sets
`container-image` to the test's image. The test's result is never cached. The runner checks that it is a farm job whose frontend received that image
(below) and prints the job's action digest. It runs nowhere else: in local mode the run fails, saying it is not a farm job, before it writes anything.

`buck2 build` of a `blackbox_test` runs nothing: a test target has no output. A check calls `buck2 test` (on a farm, `local: 0`) and reads its result.

What a test can and cannot do today, as measured on the farm:

- The image is the farm's one base image (Ubuntu 24.04, the linux-amd64 manifest). The farm's frontend refuses an action that names another digest (its
  check of the base image: `the action's container-image ... is not the base environment this executor serves`), and the test is red with that message.
- The packages are unpacked, not installed: each package's files (its data member) are put over the job's root at the paths they name. There is no
  `dpkg -i`, no maintainer script, no systemd, and no root: the job is an ordinary user with no capabilities. The job's root is the image's, and the job
  may write it (it is the job's own copy), so a package's `/usr/bin/<name>` and `/etc/<name>` are where the package says.
- Linux x86-64 only.
- Loopback works and there is no other network.

An unset `[buildrules_re] linux_x86_64_properties` fails the target when it is analysed (the package still loads, so a query of it works).

## The runner, `blackbox_run run`

```
blackbox_run run --image REF --root DIR --package FILE [--sha256 HEX --size N] [--package FILE [--sha256 HEX --size N]]... --driver PROGRAM [--farm]
```

The rule builds this argument list (`--root /`, `--farm`); nothing else needs to. In order:

1. `--farm`: require the job's directory (the one top-level `.<name>/` holding `action` and `command`, farm.zig), print the action digest and the
   property set, and require `container-image` to be the test's image.
2. Read every package; refuse one whose `--sha256` and `--size` (the pin of the `--package` before them) are not its own. Nothing is written before
   every package is checked.
3. Unpack each package (deb.zig) over DIR, in the order given, so a later package's file replaces an earlier one's; without dpkg, which the image need
   not have and the job could not run. The `ar` archive's `data.tar`, `data.tar.gz` or `data.tar.xz` is read by the extractor of `unpack`
   (tools/bootstrap): an absolute name, a `..`, a link that climbs out and an entry written through a link are refused, set-uid, set-gid and sticky bits
   are dropped. `data.tar.zst` is refused by name. The control member (the maintainer scripts) is not read.
4. Run PROGRAM with DIR, made absolute, as its one argument, with this process's environment and streams, and wait for it.

The status is the driver's when it failed, 1 when anything else failed (a package that is not the pinned one or cannot be unpacked, a driver that
cannot be started, a farm job that is not the test's), 2 for a wrong command line, 0 for a pass.

## The toy, and what it proves

`farm_probe_test` (`tests:farm_probe`) is the first test of this repository that carries its own executor, with the workers' own property set. It
passes only as a farm job whose frontend received exactly that set: `blackbox_run probe --expect NAME=VALUE...` reads the job directory of a farm job's
root (the REAPI Action and Command; a root with two is refused), prints the action digest (the sha256 of the Action's bytes and their length, the
digest `buck2 log what-ran` prints for the run) and the Action's platform (the Command's when the Action has none, as Buck2 sends it), and fails unless
the Command's arguments are its own and the set is exactly the `--expect` pairs. A local run has no such files; writing them takes root on that machine
and the bytes of an Action whose Command is that run's own argument list. Every `blackbox_test` makes the same check for its image.

`tests:toy` is the toy (`toy/`) as a black-box test: two packages, the toy service at `usr/bin/toy-service` (a service with one outside call) and the
toy fake at `usr/bin/toy-fake`, and the toy driver (`toy/driver.zig`), which starts the fake and the service from the root, points the service at the
fake, and passes only when the service's answer went through the fake. `//ci/faulty:blackbox_test_whose_driver_fails` is the same test with a driver
that expects another answer, red by design.

## Tests

The unit tests (`*_test.zig`, one target per part and `all_unit`) run every part in-process on a scripted platform (`testkit.zig`: no process is
started); `plat_test.zig` runs the real platform with a real program. `blackbox_exe_test` runs the built runner on the toy's two packages and its driver
on a root of its own: a pass, a driver that fails, a package that is not the pinned one, a driver that is not there. `tests:all` holds every refusal of
the rule's checks (`rules/rust/refusal.bzl`), each beside its accepted form. The coverage (`:coverage`) is held at `coverage_floor.txt`; `main.zig`
only forwards to `cli.zig` and is compiled into no unit test.
