# The files of the repository root (README, LICENSE, .buckconfig, prelude.bzl, tools/buck2, ...), for the scrub (tools/scrub/README.md).
load("@buildrules//tools/scrub:defs.bzl", "scrub_files")

# Read by the CI workflow check (ci/BUCK) and by the buildrules.dev site tests (site/BUCK).
export_file(
    name = "ci.yml",
    src = ".github/workflows/ci.yml",
    visibility = ["//ci:", "//site:"],
)

export_file(
    name = "release.yml",
    src = ".github/workflows/release.yml",
    visibility = ["//ci:", "//site:", "//tools/channels:"],
)

export_file(
    name = "beta.yml",
    src = ".github/workflows/beta.yml",
    visibility = ["//ci:", "//site:"],
)

# Read by the site workflow check (ci/BUCK).
export_file(
    name = "site.yml",
    src = ".github/workflows/site.yml",
    visibility = ["//ci:"],
)

export_file(
    name = "site-publish.yml",
    src = ".github/workflows/site-publish.yml",
    visibility = ["//ci:"],
)

# Read by the advisory workflow check (ci/BUCK).
export_file(
    name = "advisories.yml",
    src = ".github/workflows/advisories.yml",
    visibility = ["//ci:"],
)

# Read by the keyring-rotation workflow check (ci/BUCK).
export_file(
    name = "apt-rotation.yml",
    src = ".github/workflows/apt-rotation.yml",
    visibility = ["//ci:"],
)

# Read by the lintian workflow check (ci/BUCK).
export_file(
    name = "lintian.yml",
    src = ".github/workflows/lintian.yml",
    visibility = ["//ci:"],
)

# Read by the publish-unpack workflow check (ci/BUCK).
export_file(
    name = "publish-unpack.yml",
    src = ".github/workflows/publish-unpack.yml",
    visibility = ["//ci:"],
)

# Read by the publish-unpack workflow check (ci/BUCK), which holds the entries a build leaves in the checkout.
export_file(
    name = "gitignore",
    src = ".gitignore",
    visibility = ["//ci:"],
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
    visibility = ["//site:", "//cli:"],
)

export_file(
    name = "buck2.pin",
    src = "tools/buck2",
    visibility = ["//ci:"],
)

scrub_files(extra = [".buckconfig", ".buckconfig.local.example", ".gitignore", ".github/workflows/ci.yml", ".github/workflows/release.yml", ".github/workflows/beta.yml", ".github/workflows/site.yml", ".github/workflows/site-publish.yml", ".github/workflows/advisories.yml", ".github/workflows/lintian.yml", ".github/workflows/publish-unpack.yml"])
