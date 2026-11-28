# blackbox

A black-box test of a service as one `buck2 test` target: the service's released package is unpacked inside a named container image, its program is
started by hand with every outside address it is given pointing at a fake, the fakes are started beside it, and a driver program tests it from the
outside. The target carries its own remote-execution properties, so the same target runs on a farm or, through docker, on any machine.

```
load("@buildrules//rules/blackbox:defs.bzl", "blackbox_test")
```

This directory holds the rule (`defs.bzl`, `checks.bzl`), the runner `blackbox_run` (the Zig sources below, `BUCK`), the toy that proves it
(`toy/`, `tests/`) and its tests.

## A service repository's test

```
blackbox_test(
    name = "store_blackbox",
    # The image the test runs in, by digest (a tag is refused).
    image = "docker://docker.io/library/ubuntu@sha256:<64 hex digits>",
    # The last release, pinned. A release passes the candidate it is about to publish instead (below).
    package = {
        "url": "https://github.com/<owner>/<repo>/releases/download/v1.4.0/store_1.4.0_amd64.deb",
        "sha256": "<64 hex digits>",
        "size": 8812345,
    },
    candidate = "store",
    # The program inside the package, and its flags: every outside address is a fake's.
    service = "usr/bin/store",
    flags = ["--listen", "{addr:service}", "--upstream", "http://{addr:objects}", "--data-dir", "{work}/data"],
    # Each fake is a binary target; by default it is given `--listen {addr:<name>}`.
    fakes = {"objects": "//tests/fakes:object_store"},
    # The test program; by default it is given `--service {addr:service}`. The test passes when it exits 0.
    driver = "//tests/blackbox:store_driver",
)
```

| argument | what it is |
|---|---|
| `image` | `[docker://]<repository>@sha256:<64 lower-case hex>`. A tag, alone or beside the digest, a missing or malformed digest, and a missing repository are refused when the BUCK file loads. |
| `package` | a pin `{"url", "sha256", "size"}` (an https url, 64 lower-case hex digits, a positive length; all three, nothing else), or the label of a target whose output is the package, for a package built in the same build (this repository's own toy). The runner checks the size and sha256 of a pinned package again before it unpacks it. |
| `candidate` | optional: the name of the `-c` keys that replace the pin, `-c blackbox.<candidate>_url=... -c blackbox.<candidate>_sha256=... -c blackbox.<candidate>_size=...`. None set: the pin. All three set: they pin the package, and are checked as the pin is. One or two set, or one set to an empty value, is refused: a release whose value went missing must not test the last release in its place. |
| `service` | the path of the program inside the package (`usr/bin/<name>`), relative, with no empty, `.` or `..` part. |
| `flags` | the service's flags. |
| `fakes` | `{name: binary target}`. A name is lower-case letters, digits, `_` and `-`, and is not `service`. |
| `fake_flags` | `{name: [flags]}`, for a fake that takes others than `--listen {addr:<name>}`. |
| `driver` | the binary target that tests the service; `driver_flags`, default `["--service", "{addr:service}"]`. |
| `ready_timeout_s` | how long each fake and the service are given to take a connection, default 60. A key of `fake_flags` that names no fake is refused when the target is analysed. |
| `labels` | added to `test` and `blackbox`. |

The flags of the service, the fakes and the driver may say `{addr:<name>}` (`127.0.0.1:<port>` of a fake or of `service`), `{port:<name>}` (the port),
`{root}` (the absolute path of the unpacked package), `{work}` (the run's own directory) and `{{` (a `{`). A placeholder that names nothing, or a `{`
that is not closed, is refused when the target is analysed, and again by the runner.

A release job, after it built the package and before it publishes it:

```
buck2 test //tests/blackbox:store_blackbox \
  -c blackbox.store_url=<where the job put the .deb> -c blackbox.store_sha256=<its sha256> -c blackbox.store_size=<its size>
```

The values change the target's inputs (the package is a pinned download of them), so a result is the result of those bytes.

## Where it runs

The place is the configuration's, never the target's, and the target is the same in both.

**On a farm** (remote mode, the default). The test's executor is its own: `ExternalRunnerTestInfo(default_executor = CommandExecutorConfig(local_enabled = False,
remote_enabled = True, remote_execution_properties = ...))`. Buck2 replaces the execution platform's executor with it and keeps nothing of the platform's
property set, so the rule starts from the workers' whole set (`[buildrules_re] linux_x86_64_properties`, every key: `OSFamily`, `ISA` and the rest) and
sets `container-image` to the test's image. The test's result is never cached. The runner checks that it is a farm job whose frontend received that image
(below) and prints the job's action digest. A farm whose executor serves one base image refuses any other: the test fails, red, with the frontend's
message (`the action's container-image ... is not the base environment this executor serves`). On such a farm the test runs only when `image` is that base. An unset
`[buildrules_re] linux_x86_64_properties` fails the target when it is analysed (the package still loads, so a query of it works).

**Through docker** (local mode). The runner runs on the machine running Buck2 and starts itself inside the image:

```
./buck2 test -c buildrules_re.mode=local -c blackbox.docker=/usr/bin/docker //rules/blackbox/tests:toy
```

`blackbox.docker` is the absolute path of the docker program. The run is `docker run --rm --network none --user <this user> --volume <checkout>:<checkout>:ro
--workdir <checkout> --entrypoint <the runner> <image> run ...`: the checkout read-only at its own path (so every path of the command line means what it
meant outside), no network but loopback, this machine's user, and the runner, a static program, as the entry point. Without `blackbox.docker` the run fails
and names the key: a test that names an image never runs outside it. A pull request runs the toy this way on a hosted runner (`.github/workflows/ci.yml`).

## The runner, `blackbox_run run`

```
blackbox_run run --image REF --package FILE [--sha256 HEX --size N] --service PATH [--flag ARG]...
                 [--fake NAME=PROGRAM [--fake-flag NAME=ARG]...]... --driver PROGRAM [--driver-flag ARG]... [--ready-s N]
                 [--farm | --docker DOCKER]
```

The rule builds this argument list; nothing else needs to. In order:

1. `--docker`: start itself inside the image as above, and exit with that run's status. `--farm`: require the job's directory (a top-level `.<name>/` holding
   `action` and `command`, farm.zig), print the action digest and the property set, and require `container-image` to be the test's image.
2. Read the package; with `--sha256` and `--size`, refuse one that is not those bytes. Nothing is written before this.
3. Unpack it (deb.zig) into `<TMPDIR or /tmp>/blackbox.<random>/root`, without dpkg: the image need not have it, and the run is not root. The `ar`
   archive's `data.tar`, `data.tar.gz` or `data.tar.xz` is read by the extractor of `unpack` (tools/bootstrap): an absolute name, a `..`, a link that
   climbs out and an entry written through a link are refused, set-uid, set-gid and sticky bits are dropped. `data.tar.zst` is refused by name. The control
   member (the maintainer scripts) is not read: the program is started by hand.
4. Give each fake and the service a loopback port nothing listens on, and fill in the flags; a flag that names nothing is exit 2 before anything starts.
5. Start each fake, then the service's program (`root/<PATH>`), each in a process group of its own with stdin `/dev/null` and its output in a log of its
   own, and wait until its port takes a connection: a process that exits first, or takes none within `--ready-s` (at most a day), fails the run. Each
   process gets a port no other process of the run has (a port is released once it is read, so one asked for again can be the same: it is asked for
   again, at most 16 times).
6. Run the driver and wait for it (`buck2 test`'s own timeout bounds it: `-- --timeout <s>`, 600 by default).
7. A fake or the service that is gone when the driver ends fails the run. Stop each that is not, the last started first: SIGTERM to its group, and once
   it has stopped (or 30 s later), SIGKILL to the group, so nothing it started outlives the run.
8. On a pass, print the driver's log. On any failure, print every log, each under a line naming it.

The status is the driver's when it failed, 1 when anything else failed, 2 for a wrong command line or a run that cannot be placed (`--docker` empty), 0 for
a pass. The run's environment is the runner's (on a farm, the job's; in docker, the image's), unchanged.

## The toy, and what it proves

`farm_probe_test` (`tests:farm_probe`) is the first test of this repository that carries its own executor, with the workers' own property set. It
passes only as a farm job whose frontend received exactly that set: `blackbox_run probe --expect NAME=VALUE...` reads the job directory of a farm job's root (the one top-level `.<name>/` holding
`action` and `command`, the REAPI Action and Command; a root with two is refused), prints the action digest (the sha256 of the Action's bytes and their length, the digest `buck2 log
what-ran` prints for the run) and the Action's platform (the Command's when the Action has none, as Buck2 sends it), and fails unless the Command's
arguments are its own and the set is exactly the `--expect` pairs. A local run, or one in docker, has no such files; writing them takes root on that machine
and the bytes of an Action whose Command is that run's own argument list. Every `blackbox_test` on a farm makes the same check for its image.

`tests:toy` is the toy service (`toy/toy.zig`: a service with one outside call, a fake of that call, a driver, and the packer that makes the service a
Debian package with its program at `usr/bin/toy`) as a black-box test: the driver passes only when the service's answer went through the fake.
`//ci/faulty:blackbox_test_whose_driver_fails` is the same test with a driver that expects another answer, red by design.

## Tests

The unit tests (`*_test.zig`, one target per part and `all_unit`) run every part in-process on a scripted platform (`testkit.zig`: no process is
started, and the clock is a number the runner's own sleeps move, so no case waits or measures a time); `plat_test.zig` runs the real platform with real
programs, waiting for ports and exits only. `blackbox_exe_test` runs the built runner on the toy's package against the toy's fake and driver: a pass, a
driver that fails, a fake that exits before it is ready, a package that is not the pinned one, a local run with no docker. `tests:all` holds every refusal of
the rule's checks (`rules/rust/refusal.bzl`), each beside its accepted form. The coverage (`:coverage`) is held at `coverage_floor.txt`; `main.zig` only
forwards to `cli.zig` and is compiled into no unit test.
