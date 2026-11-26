# Recorded buck2 output

Each file is what buck2 printed in one run on the farm, with the farm's address (now 192.0.2.10:50051), its instance name, the build ids
and, in the older recordings, the cell name and action digests replaced; nothing else is changed. The tests change a line where a case
needs another shape, and say which.

| file | the run |
| --- | --- |
| `build_cut.log` | a build whose every failure was a cut connection (two actions in flight, each printed twice) |
| `build_cut_after_file_changes.log` | the same after a step had written files the daemon saw change (progress lines cut to two) |
| `build_cut_and_compile_error.log` | a build with a C compile error beside cuts |
| `build_failed_unknown_target.log` | an analysis failure: a target that does not exist |
| `build_remote.log`, `build_cached.log` | passing builds, on the farm and all from the cache |
| `bxl_remote.log`, `bxl_cached.log` | passing bxl runs, on the farm and with no action |
| `test_cut.log` | a test run whose every test was cut before it ran |
| `test_failed.log` | a test run with one failed test |
| `test_cached_remote.log`, `test_none_ran.log` | passing test runs |
| `cut_chunk_connect.log` | `buck2 build //:ci` of a Rust workspace cut for minutes: 47 actions failed with `RE channel error`, and buck2's client warned of `Error writing chunk of` and of `tcp connect error ... Connection timed out` while it retried |
| `cut_skipped.log` | `buck2 build --skip-incompatible-targets @targets` of mopm cut under one action, with the list of 27 skipped targets |
| `clippy.log` | `buck2 build //:ci` of a Rust workspace failing a clippy lint |
| `rustfmt.log` | `buck2 build //:ci` of a Rust workspace failing its rustfmt check |
