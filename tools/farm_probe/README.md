# farm_probe: what an action may do on the farm

`farm_probe` is a small program that reports, from inside an action, what that action may do where it runs: its user and capabilities,
whether it can write, which network it has, whether it can make a user namespace and mount in it, and the limits it runs under. It is a
measurement, not a check. It passes whatever it finds, and a pull request never runs it (`//tools/farm_probe:probe` is left out of
`//ci:all`; ci/all.bzl says why). The design of black-box test targets rests on the facts below.

## Running it

```
buck2 build //tools/farm_probe:probe -c farm_probe.run=<any new text> --show-output   # as a build action; the report is the output file
buck2 test //tools/farm_probe:probe                                                    # as a test action; buck2 prints the report
```

Both run as ordinary actions on the linux x86_64 execution platform, with no extra properties. `-c farm_probe.run` changes the command
line, so the build action runs again instead of being a cache hit. `buck2 test` ran the test again on every invocation here. `-c farm_probe.egress=A.B.C.D:PORT`
adds one TCP connect to that address (a public address by number; the repository names none). Without it there is no outside connect.

What the probe does to the machine: it reads its own `/proc/self` files, its cgroup's files, `/proc/net/dev` and three sysctls. It
checks `/` and its working directory with `access(W_OK)`, which creates nothing. It makes one file in its working directory, writes a
byte and removes it. It opens `/dev/fuse` and closes it. It listens on 127.0.0.1 port 0 and connects to itself. At the end it makes a
user namespace and, in it, a file and a tmpfs mount on a directory of its working directory, then takes both down again. The mount is
in a mount namespace of its own, which ends with the process. Every name it makes there is `farm_probe_<pid>...`. A build action also
writes its report to its one declared output.

## The report

One `name value` line per fact. A refused call is its error name (`EPERM`). `ok` means the call succeeded.

| line | what it is |
|---|---|
| `probe`, `run` | `build` or `test`, and the `-c farm_probe.run` text |
| `kernel`, `machine` | `uname` release and machine |
| `status.Uid` ... `status.Seccomp_filters` | those fields of `/proc/self/status`: ids (real, effective, saved, fs), the five capability sets, no_new_privs, seccomp mode |
| `uid_map`, `gid_map` | `/proc/self/uid_map` and `gid_map`: the user namespace the action is in |
| `env.names`, `env.PATH`, `env.TMPDIR.length` | the names of the environment's variables, the value of PATH, the length of TMPDIR |
| `cwd.length` | the length of the working directory's path |
| `rlimit.*` | soft and hard limits: CPU seconds, address space, file size, open files, processes, core size |
| `cpus` | CPUs in the affinity mask |
| `cgroup`, `cgroup.*` | the cgroup v2 path, and its `memory.max`, `memory.high`, `memory.swap.max`, `pids.max`, `cpu.max` |
| `root.access_w`, `cwd.access_w` | `access(W_OK)` of `/` and of `.`. `EROFS` is a read-only mount, `EACCES` a mount this user may not write |
| `cwd.create` | a new file made, written and removed in the working directory |
| `dev.fuse.exists`, `dev.fuse.open` | `access(F_OK)` and `open(O_RDWR)` of `/dev/fuse` |
| `net.interfaces`, `lo.flags` | the interfaces of `/proc/net/dev`, and whether `lo` is up and running |
| `loopback` | listen on 127.0.0.1 port 0, connect, accept, move one byte; `ok` or the step that failed |
| `egress` | the one outside connect: `connected`, the error, or no answer within 5 s |
| `sysctl.*` | `user.max_user_namespaces`, `kernel.unprivileged_userns_clone`, `kernel.apparmor_restrict_unprivileged_userns` |
| `userns.*` | `unshare(CLONE_NEWUSER)`; `deny` to `setgroups`; `0 <uid> 1` to `uid_map` and `gid_map`; the uid inside; a file of its own written; `unshare(CLONE_NEWNS)`; a tmpfs mounted, unmounted, its directory removed |

## Measured on 2026-11-27

Six runs on the farm: three build actions and three test actions. `buck2 log what-ran` showed each on the remote executor (`re(...)`),
and each build summary said `local: 0`. The runs saw three kernels, 7.0.0-42, 7.0.0-43 and 7.0.0-44, so at least three workers ran
them. The outside connect was tried in five of the runs: two build actions and the three test actions, each a TCP connect to one public
address on port 443. Every line below was the same in every run that had it. The exceptions were the kernel, the `NPROC` limit (between
962001 and 962339), and the variable `BUCK_SCRATCH_PATH`, which buck2 sets for a build action and not for a test.

| | build action | test action |
|---|---|---|
| uid, gid | 1000, 1000 (real, effective, saved, fs); no supplementary group | the same |
| capabilities | CapInh, CapPrm, CapEff, CapBnd, CapAmb all `0000000000000000` | the same |
| no_new_privs, seccomp | `1`; mode 2 (filter), one filter | the same |
| user namespace | in one: uid and gid 0 map to a subordinate range of 65536 ids, so uid 1000 is not root outside | the same |
| environment | `BUCK_SCRATCH_PATH CLANG_MODULE_CACHE_PATH HOME TMPDIR XDG_CACHE_HOME`; **no PATH**; TMPDIR is 21 bytes | the same without `BUCK_SCRATCH_PATH` |
| `/` writable | `access(W_OK)` ok: a writable mount the action may write (the probe made no file there) | the same |
| working directory writable | `access(W_OK)` ok; a file made, written and removed | the same |
| network | only `lo`, up and running | the same |
| loopback | listen on 127.0.0.1, connect to itself, one byte across: ok | the same |
| outside connect (TCP to one public address, port 443) | `ENETUNREACH`: no route out, as `lo` is the only interface | the same |
| user namespace of its own | `unshare(CLONE_NEWUSER)` ok; setgroups, uid_map, gid_map written; uid 0 inside | the same |
| uid 0 in it writes a file it owns | ok | the same |
| tmpfs mount in it | `unshare(CLONE_NEWNS)` ok, `mount` of a tmpfs ok, unmounted and its directory removed | the same |
| userns sysctls | max_user_namespaces 2147483647, unprivileged_userns_clone 1, apparmor_restrict_unprivileged_userns 1 | the same |
| `/dev/fuse` | absent: `ENOENT` for both access and open | the same |
| cgroup | path `/`; memory.max, memory.high and memory.swap.max `max`; pids.max 32768; cpu.max `max 100000` | the same |
| rlimits | CPU, AS, FSIZE unlimited; NOFILE 65536; CORE 0 | the same |
| CPUs | 88 in the affinity mask | the same |
| time limit | buck2 sends the action with no timeout, as the rule sets none (read in buck2's source). A limit the farm applies itself is not visible from inside and was not measured. RLIMIT_CPU unlimited | 600 s: buck2's test runner gives each test a 600 s timeout unless `--timeout` says otherwise, and sends it with the action (read in buck2's source, not measured). RLIMIT_CPU unlimited |

So a build action and a test action get the same sandbox. The only differences found are the time limit and one variable. The runs
cover the linux x86_64 platform with no extra properties, and one outside address.

What this settles for the two descriptions it was run to decide between:

- "A farm action has its declared inputs and nothing else: no network, no PATH but the busybox directory, no checkout, not root, and a
  TMPDIR about 98 bytes deep". **Right** on the parts measured, for build actions and for test actions: there is no route out, PATH
  is unset in the action, and the action is uid 1000 with no capabilities. Not settled here: whether the action sees only its
  declared inputs or a checkout, which the probe does not look for. The 98 bytes are the depth of the action's scratch path
  (docs/contract.md), which the probe does not print. The bare action's TMPDIR is 21 bytes.
- "A test action runs as uid 0, can reach the outside, and has loopback". **Wrong** on uid 0 and on the outside connect, for both
  kinds of action, in every run here. Loopback does work.

Beyond both: an unprivileged user namespace with a tmpfs mount in it works, and there is no `/dev/fuse`.

## Tests

`probe_unit` (`probe_test.zig`) runs the probe against a fake kernel. The fake answers each system call from a table and logs it, so
every outcome of every step is driven: the whole report byte for byte when everything is allowed and when nothing is; each loopback,
egress and user-namespace step failing in turn; short and failed writes of the report; a command line the usage does not describe.
Each test that runs the whole report also checks that every file and directory the probe made was removed, every mount taken down and
every descriptor closed.
`main.zig`, one system call per method with no decision, is left out of the coverage `expect` (BUCK says why).
