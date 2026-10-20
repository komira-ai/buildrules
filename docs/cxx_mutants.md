# rules/cxx: planted defects (all run on the farm, `local: 0`)

| # | mutant | target | red because |
|---|---|---|---|
| 1 | last hex digit of the aws-lc tarball sha256 changed | `//third_party/aws-lc:src` | the pinned download's digest does not match |
| 2 | `umodti3.c` returns `r + 1` | `:crypto` | `selfcheck` prints `bn: got 79 186405112 want 78 509977877`; `selfcheck_runs` fails |
| 3 | `__umodti3` removed from `crypto_symbols` `allow` | `:crypto_symbols` | `archive_check RED: 1 defined symbols without the prefix: __umodti3` |
| 4 | `exported_preprocessor_flags` (renaming header) removed from `crypto_prefixed` | `:crypto` | `only 0 defined symbols start with buildrules_awslc (at least 1000 expected)` |
| 5 | `expected_stdout` of `selfcheck_runs` shortened | `:crypto` | `c_check: expected '...bn' but ... printed '...bn gcm'` |
| 6 | `selfcheck_floor` `max = "2.17"` | `:selfcheck_floor` | `glibc_floor: needs GLIBC_2.34.0, newer than the floor 2.17` |

Not covered: a toolchain `target` with a higher floor still passes `selfcheck_floor` unless the binary uses a newer
symbol; the check holds the result, not the flag.
