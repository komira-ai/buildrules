# The files of the repository root (README, LICENSE, .buckconfig, prelude.bzl, tools/buck2, ...), for the scrub (tools/scrub/README.md).
load("@buildrules//tools/scrub:defs.bzl", "scrub_files")

# Read by the CI workflow check (ci/BUCK).
export_file(
    name = "ci.yml",
    src = ".github/workflows/ci.yml",
    visibility = ["//ci:"],
)

export_file(
    name = "release.yml",
    src = ".github/workflows/release.yml",
    visibility = ["//ci:", "//site:"],
)

export_file(
    name = "beta.yml",
    src = ".github/workflows/beta.yml",
    visibility = ["//ci:", "//site:"],
)

# Read by the buildrules.dev site tests (site/BUCK), which check the Releases section against these.
export_file(
    name = "RELEASING.md",
    src = "RELEASING.md",
    visibility = ["//site:"],
)

export_file(
    name = "VERSION",
    src = "VERSION",
    visibility = ["//site:"],
)

export_file(
    name = "buck2.pin",
    src = "tools/buck2",
    visibility = ["//ci:"],
)

scrub_files(extra = [".buckconfig", ".buckconfig.local.example", ".gitignore", ".github/workflows/ci.yml", ".github/workflows/release.yml", ".github/workflows/beta.yml"])
