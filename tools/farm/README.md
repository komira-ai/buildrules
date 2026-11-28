# tools/farm: building on the farm from a GitHub Actions job, through a short loss of the connection

A repository that builds with buildrules on the farm takes two steps in its farm workflow: it connects the job to the farm, then runs one
buck2 command there. Both are shared here, so every such repository gets the same waits and the same rules:

- **`.github/actions/farm-connect`** builds the `farm` tool on the runner (from the action's own commit, in local mode: there is no farm
  yet) and runs `farm connect`. The job joins the farm's network in a step of its own before it.
- **`farm connect`** refuses an empty or malformed value (a fork's job gets no repository variables, and buck2 without a farm builds on the
  runner), masks the farm's address in the log, waits until the farm answers on its port, and writes the buckconfig: the remote-execution
  addresses, instance name and `tls`, the worker property set under `[buildrules_re]`, and the keys for a slow connection. It probes every
  5 seconds for `--wait-minutes` (20 by default, at most 120), with a line in the log each minute. When it answered after a wait, the job
  summary says how long; when it does not answer in time, the step fails and nothing is written.
- **`farm run`** runs the build with its output in the job log and in `--log`. A passing run must say `local: 0` (every action ran on the
  farm or came from its cache), or the step fails: it never falls back to building on the runner. A failed `build`, `test` or `bxl` whose
  every failure is a cut connection to the farm waits, for the same bounded time, until the farm answers again, then runs the same command
  once more; the job summary gets one line saying so and how long it waited, and the first run's log is kept as `<name>.first.log`. The
  second run is final, and there is never a third. Anything else is final at once: a real failure beside any number of cuts, a run ended by
  a signal, a cut run that also ran an action on the runner, or another subcommand. A step that publishes or uploads is never a `farm run`,
  so it is never run twice.

What counts as a cut is buck2's own output and nothing looser (classify.zig says it line by line): every failed action or test has buck2's
`Error:` line with `RE channel error: code:` in its head, or is a test buck2 never ran because its run was cut; no test timed out or was
fatal; and every other line is one buck2 prints around such a run, including its client's warnings while it retries (`Error writing chunk
of`, `tcp connect error ... Connection timed out`) and the list `--skip-incompatible-targets` prints. A compiler or a test that quotes the
phrase in its own output does not make a cut.

## Using it

```yaml
jobs:
  build:
    permissions:
      contents: read
      id-token: write   # the farm's network trusts the job's OIDC token
    steps:
      - uses: actions/checkout@<commit>
      # ... install the pinned buck2 at $RUNNER_TEMP/bin/buck2 ...
      # ... join the farm's network (the step that gives this job its route to the farm) ...
      - name: connect to the farm
        uses: <owner>/buildrules/.github/actions/farm-connect@<full commit of this repository>
        with:
          buck2: ${{ runner.temp }}/bin/buck2
          farm-address: ${{ vars.FARM_ADDRESS }}
          farm-instance: ${{ vars.FARM_INSTANCE }}
          farm-properties: ${{ vars.FARM_LINUX_X86_64_PROPERTIES }}
          tls: ${{ vars.FARM_TLS || 'false' }}
      - name: buck2 build //:ci on the farm
        run: '"$RUNNER_TEMP/buildrules-farm" run --config .buckconfig.local --log "$RUNNER_TEMP/build.log" --summary "$GITHUB_STEP_SUMMARY" -- "$RUNNER_TEMP/bin/buck2" build //:ci'
```

The buckconfig is the checkout's `.buckconfig.local` (the action's `config` input), which overrides the repository's `.buckconfig`, so a
`[buildrules_re]` key there that reads the property set from another section is overridden too. A job's `timeout-minutes` must leave room
for two waits and two builds.

## Which repositories change

Each farm workflow below connects through another project's action, which gives up after one minute, and runs its build once. Each pins
a commit of this repository that has the action and changes its `farm.yml`, keeping the step that joins the farm's network:

- **jobscheduler** and **tierstore**: replace the connect step with the network join and this action, and run the `buck2 build //:ci`
  that `cargo xtask farm-build` runs through `farm run` (the table check before it stays theirs).
- **mopm**: replace the connect step with the network join and this action, and replace the step that copies the worker properties
  into `[buildrules_re]` (the action writes them there), the build step and the `local: 0` step with one `farm run --config
  .buckconfig.local ... -- ./buck2 build --skip-incompatible-targets @<targets>` (or `//...` on a push); its `uquery` of the targets
  stays a step of its own.

## Tests

`//tools/farm:farm_unit` runs every case on recorded buck2 output (fixtures/README.md), with a runner that plays it and a wait on a clock
the test moves, so no case waits, reaches a farm or resolves a name; the real runner runs busybox applets and the real probe connects to a
listener on 127.0.0.1 with port 0. `//tools/farm:coverage` holds the package to its floor (`coverage_floor.txt`).
