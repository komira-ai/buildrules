# rules/coverage: kcov and the coverage path tools

Line coverage of Mojo tests (docs/contract.md, section 12),: the test is a debug build, linked through a `zig` that keeps
the line tables and rewrites the action's directories out of them, run under kcov, its Cobertura report mapped to repository paths. **linux x86_64 only.**

| target | what | origin |
|---|---|---|
| `:kcov` | kcov v42 built from source with the pinned zig 0.12: `bin/kcov`, `lib/libgcc_s.so.1` | `kcov_build`, `conda_payload`, `elf_rpath`, the curl shim; one patch added (`no_aslr_control`) |
| `:debug_relocate`, `:cov_zig` | the `real/zig`-fronting link directory of a coverage build (`cov_link`, one per Mojo version, in `toolchains//:mojo_<v>_cov_link`) | `cov_link` tools |
| `:cov_normalize` | a kcov report in repository paths, with bytes that do not depend on the run | same |
| `:cov_run` | runs one test binary under kcov in a tree of copies of its sources, then `cov_normalize` | new: the part a mopm unit needs |
| `:cov_summary` | the package's lines hit and recorded, from the reports; fails when a source of the library is in none | new |

Every tool is built behind its unit tests; the process cases of `cov_zig`, `debug_relocate` and `cov_normalize` are `zig_test`s that run the executable
and are validations of the public target.

Not included: kcov's own check suite (`kcov_check`, `loader_closure_check`, the identity and reproducibility checks), branch coverage (LLVM profile counters), `covcheck` (policy,
floors, holds, the census, the PR check run). kcov is GPL-2.0 and build-only: it runs in actions and is never packaged.

**The patch.** kcov disables address randomization with `personality(ADDR_NO_RANDOMIZE)`; the farm's worker sandbox answers ENOSYS, and kcov stops. The patch lets the run go on. This is sound here
because the tests are linked at a fixed address (not position independent) and kcov runs with `--skip-solibs`, so randomization does not move the code it plants breakpoints in.
