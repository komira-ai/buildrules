# Releasing buildrules

A release is automatic. Every push to `main` is tested in stages, and a green one that changes more than documentation or CI is released with
no human action: a tag, and a GitHub release carrying a source archive, the command line for three platforms (`buildrules-cli-<version>-<target>.tar.gz` for
`linux-x86_64`, `linux-aarch64` and `macos-arm64`), the Debian packages of the two Linux ones (`buildrules_<version>_amd64.deb` and `buildrules_<version>_arm64.deb`),
`SHA256SUMS` over those six files, a keyless signature and a build provenance attestation of each of those seven files, and the notes. After the release exists, two
channels follow it: the Homebrew formula, as a pull request in the organisation's tap, and the Debian packages, in the apt repository the organisation's products
share (see "The Homebrew tap" and "The apt repository": both do nothing until the repository owner has made their settings). A consumer of the rules pins the tag and the archive's sha256 (or the tag's commit); a user of the command line unpacks
the tarball of the platform. A pull request runs none of this: it runs build and unit tests only (see "The tiers").

`.github/workflows/release.yml` is the pipeline. `tools/release` and `tools/stage` (Zig, tested as build actions) do each step, `tools/channels` makes the `.deb` and the formula and `tools/deploy` publishes them; the workflow's `run:` lines are
one invocation each. `ci/release_check.zig` and `ci/stages_check.zig` (part of `//ci:workflow`) hold `release.yml` and `beta.yml` to what is written here.

## The stages

| job | what it does | token |
|---|---|---|
| `gate` | the PR gate: calls `ci.yml`, the whole tree (`//ci:all`) and the completeness check, in local mode on the runner. It is also the whole check of a pull request (`ci.yml` runs there on its own, see "The tiers") | read |
| `tool` | builds `tools/release`, `tools/stage`, `tools/channels` (the `.deb` and the formula) and `tools/deploy` (the tap pull request and the apt publish) with buck2 and hands the binaries to the later jobs, before any job that writes holds a token | read |
| `plan` | read-only; decides whether this commit is released and which version; creates nothing. It is the one job that reads `RELEASE_FREEZE` (see "The freeze") | read |
| `build-cli` | builds `//cli:release_binaries` (the command line for the three release targets in one directory) from the tested commit with the planned version stamped in (`-c buildrules.release_version=<version>`), in local mode, and packages the three tarballs (`release package-all`) and, from the same two Linux binaries, the two `.deb`s (`release debs`, which runs `channels deb-package`). The linux-x86_64 binary is also uploaded as the file the beta will run, and the directory of all three as `release-cli-bins` (the native legs run two of them) | read |
| `beta` | calls `beta.yml` with that linux-x86_64 binary and the directory of the three: hello-world repositories per language consume the candidate commit as a user would and are built twice, the second time in another directory (see "The beta stage") | read, `id-token` for its farm leg |
| `gamma` | builds our own repositories with the candidate on the farm; fails the release when the farm is not configured (see "The gamma stage") | read, `id-token` write |
| `archive` | `git archive` of the tested commit (its sha, not a tag) under `buildrules-<planned version>/`, compressed by the tool's own gzip; checks that the linux-x86_64 tarball holds the very file the beta ran and lets through only the tarballs a user beta ran (`release record`, `release tested`); the two `.deb`s must hold the program of the tarball of their architecture (`release tested`); `SHA256SUMS` over the archive, the three tarballs and the two `.deb`s | read |
| `attest` | only on a push to `main`: a keyless cosign signature (`<file>.sigstore.json`) of the seven files and a build provenance attestation of all seven | `id-token`, `attestations` write |
| `verify` | read-only, only on a push to `main`; checks everything below before a file is published, and builds the three binaries and the two `.deb`s again to compare | read, `attestations` read |
| `tag` | the annotated tag at that sha, made only after everything is built, tested, signed and verified, with the release bot's token (see "The tag ruleset"). It fetches the tags again first and settles the race of two pushes that planned the same number (see "Two pushes at once"); its outputs `tag`, `number` and `superseded` are what `site`, `publish` and `bump` use | read; the write is the bot's token, minted in this job and used by the tag step alone |
| `site` | read-only; skipped when `tag` ended as superseded; the page of the release (the pin snippet) as an artifact; nothing deploys it | read |
| `publish` | needs `tag` and `verify`; skipped when `tag` ended as superseded; takes the tag from `tag`'s output; checks the tag peels to the verified sha, then creates the GitHub release from the verified files: the archive, the three tarballs, the two `.deb`s, `SHA256SUMS` and the seven signature bundles | `contents: write` |
| `bump` | needs `plan`, `tag`, `publish` and `tool`; skipped when `tag` ended as superseded; takes the tag from `tag`'s output; opens the pull request that moves the internal repository's `buildrules` submodule to the released commit, with auto-merge (see "The submodule bump"). Nothing waits for it | read; the write is the bot's token for the internal repository, minted in this job and used by the bump step alone |
| `tap` | needs `plan`, `tag`, `publish` and `tool`; the exact `if:` of `publish`; renders `Formula/buildrules.rb` from the verified `SHA256SUMS` (`channels formula`) and opens the pull request that adds it to the organisation's Homebrew tap, with auto-merge when the tap allows it (see "The Homebrew tap"). Nothing waits for it | read; the write is the bot's token for the tap repository, minted in the second to last step and used by the last |
| `apt-deploy-read`, `apt-index`, `apt-deploy-write` (and the same three with `-2` and `-3`) | after `publish`: the `.deb`s go into the apt repository, in up to three attempts of three jobs (see "The apt repository"). Until the owner has made the settings every one ends green with a notice and writes nothing. Nothing waits for them | read; `id-token` write in the two `apt-deploy-*` jobs of an attempt, which hold the cloud role and no key; the `apt-index` job holds the signing key and no role |

The order is `gate`, `plan`, `build-cli`, `beta`, `gamma`, `archive`, `attest`, `verify`, `tag`, `publish` (`tool` beside `gate`; `site` after `tag` and `verify`; `bump`, `tap` and the apt jobs after `publish`);
a job runs only if the one before it succeeded. **Nothing before `tag` waits for it, so a failure in the build, the beta, the gamma, the archive, the signing or the
verification leaves no tag behind**: the tag is the first thing in the pipeline that cannot be taken back, and it is made last but for the release
(`ci/release_check.zig` refuses a `needs: tag` in any job before it). The plan comes before the build because it only reads: the version it decides is what the
binaries are stamped with, so the bytes the beta runs are the bytes that are released. Once the plan has said a commit is not released (documentation and CI alone, or
a freeze), the build, the beta and the gamma do not run for it.
A `GITHUB_TOKEN` write scope exists only in `publish` (`contents`), in `attest` (`id-token`, `attestations`), and `id-token` also in `gamma` and in the call of `beta`
(the farm's network trusts the job's OIDC token; neither has `contents: write`) and in the `apt-deploy-*` jobs (the cloud role is assumed by OIDC; they have no `contents: write` either); `tag`, `attest`, `verify`, `publish`, `bump`, `tap` and the first `apt-deploy-read` are each under the exact `if:` of
a push to `main`, not a fork, and a commit the plan released; and the workflow is triggered by a push to `main` alone, so no pull request runs any of it. The jobs that write run no buck2 and use only the checkout and
artifact actions (`attest` also the cosign installer and the attestation action); `gamma` runs no buck2 itself, the stage tool does. Every action is pinned by commit, but one: the
farm-connect action is checked out of the repository and commit that two repository variables name, the checkout is verified to be that commit before the action
runs, and it is then used from the checkout. Two runs never tag at once (concurrency group `release`, nothing cancelled); two pushes that planned the
same number are settled inside that group (see "Two pushes at once"). The workflow's own concurrency is one group for every push and cancels nothing (see "Two pushes at once"). No job of the workflow carries `continue-on-error` (or only `false`), and no `run:` line
expands a repository variable or event field inline: the values go through `env:` (`ci/release_check.zig` and `ci/stages_check.zig` refuse both).

## The tiers

Three tiers, and each runs where it is cheapest to be wrong:

| tier | what it is | where it runs |
|---|---|---|
| unit | each library: build and unit tests (a coverage measurement joins this tier where a library has one) | every pull request (`ci.yml`: `//ci:all`, the completeness check, `host_arm`) |
| beta | each component, as a user starts it: the hello-world repositories per language, built twice (see "The beta stage") | the `beta` stage of `release.yml`, on a push to `main` after the merge |
| gamma | the whole system with real consumers: our own repositories on the farm (see "The gamma stage") | the `gamma` stage of `release.yml`, on a push to `main` after the merge |

A pull request runs `ci.yml` and nothing else: it builds `//ci:all` (the unit tests of every package and the lints of every workflow, `release.yml` and `beta.yml` among them, so a broken
`release.yml` is red before the merge) and runs the completeness check and the aarch64 host leg. It does not run the beta, the gamma, the signing, the attestation, the reproduction or the
verification of a release: those happen once, in the release run on the push to `main`, and a red one there leaves no tag. `release.yml` and `beta.yml` have no `pull_request` trigger
(`ci/release_check.zig` and `ci/stages_check.zig` refuse one), and `ci.yml` calls neither (`ci/workflow_check.zig` refuses the call of `beta.yml`, a build of the stage tool or the release
tool, `id-token` and a cosign or attestation action there).

## The freeze

The repository variable `RELEASE_FREEZE` set to `true` stops every release: the plan says the commit is not released, so no later stage runs and nothing is built, tagged or published (a
re-run of an old run is frozen too: unfreeze to finish it). Empty, unset and `false` mean not frozen; any other value fails the plan, since a misspelt freeze must stop the pipeline and not release.
Only the plan job reads the variable (`ci/release_check.zig` refuses it anywhere else), and nothing but a push to `main` reads it.

## The beta stage

`beta.yml` is called by the release, after the merge and not on a pull request, with the linux-x86_64
command line that `build-cli` built: the workflow input `cli-artifact` names the artifact that holds that one file, the `tools` job downloads it instead of building the program, and every
leg below runs it. It is the file the release ships: `archive` later requires the linux-x86_64 tarball to hold exactly those bytes (`release record --ran-binary`), so what a user beta ran is what is attested. A hello-world repository per language is made
the way a user makes one: `beta/<lang>/` holds the files the user writes, and `beta/<lang>/STEPS` the commands the user types (`buildrules init . --git
<repository> --commit <candidate>`, `buildrules cargo new`, `npm sync`, `mojo sync` and so on). `tools/stage` copies the directory to a new place
outside the checkout, runs the steps with the `buildrules` built from the candidate, builds the targets, runs what it built and checks what it prints,
and then, from nothing, builds again.

| leg | what | runs |
|---|---|---|
| `rust` | `cargo new`, `sync`, `check`; build, test, lint and run the binary | ubuntu x86_64 |
| `cxx` | a C and a C++ program on the pinned zig | ubuntu x86_64 |
| `zig` | a Zig program with its unit test welded to the executable | ubuntu x86_64 |
| `node` | a Node package: `npm sync`, `npm check`, test and build scripts, a `dist` directory | ubuntu x86_64 |
| `mixed` | a Rust package, a C program, a Zig program and a Node package in one repository | ubuntu x86_64 |
| `mojo` | a Mojo package, built by the pinned mopm 0.0.24 release | ubuntu x86_64 |
| `ubuntu-24.04-arm`, `macos-14` (native) | `zig` and `cxx`, with the command line the release ships for `linux-aarch64` and `macos-arm64`, run on that machine: `--version` says the planned version, `init` writes the same bytes in two directories, Buck2 loads the candidate as the external cell and lists the targets. **No build**: see "The native legs" | arm Linux, macOS (Apple silicon) |
| farm | the ubuntu legs again, built on the farm | only when the repository variables `FARM_ADDRESS` and `FARM_CONNECT_REF` are set |

The runner legs run every action on the runner (`-c buildrules_re.mode=local`; nothing is built anywhere else), and each is built **twice, in two different
directories**: after the first build the tool records the sha256 of every output (a file's bytes, or a directory's names and bytes), stops the daemon, copies the
repository without `buck-out` to a sibling directory (the work directory with `-second` appended), builds there from nothing, and compares. A second build in the
same directory could not see an output that depends on the path it was built at (a compile directory in debug info, a path in a manifest); this one can.
Any difference is red, with both digests and both directories. A leg whose build declares no output at all is red as well (`tools/stage` fails it, on the farm too): two empty lists compare equal, so the check would pass having compared nothing. The Mojo leg builds the package's `.mojoc` (`//hello:lib`) beside `//hello:ci` for that reason.

C and C++ outputs used to depend on the path: zig cc assembles the C runtime's start-up objects at link time with debug info, whatever `-g0` said for the compiles,
and that DWARF names the action's working directory. The toolchain now links with `-Wl,--strip-debug`, and `hermetic_check` (`examples/cxx`, a validation in `//ci:all`)
fails a C or C++ binary that has a `.debug_*` section or contains the path of the directory it was linked in (shown red without the flag and green with it, on the farm).
What this establishes is that those two defects are gone and that each environment's two builds are compared across two paths. It does not establish that a binary
built on a GitHub runner and one built on the farm are the same bytes: no run compares a runner leg with a farm leg (a farm leg does not repeat the build, below), so that
claim is made only if a beta run shows it.
A farm leg does not repeat the build, since the farm's cache would answer it; it requires every build to report `local: 0`.

The Mojo job runs: `beta/mojo/STEPS` no longer carries `planned-until mopm-release`, and `tools/stage plan` reports the leg ready (mopm 0.0.24, the
published release, is pinned in `rules/mopm/pins.bzl`).
The farm leg, when `FARM_ADDRESS` or `FARM_CONNECT_REF` is empty, is skipped and the `tools` job says so with a notice.

`beta/` is not part of this repository's Buck2 graph and is not built by `//ci:all` (`ci/all.bzl`, `OUTSIDE_THE_GRAPH`, says why): a user's `BUCK` file
is kept as `BUCK.beta`, so that the directories are not packages here. `//beta:beta_check` holds it to that.

### The native legs (`beta_arm`, `beta_macos`)

The release ships a command line for `linux-aarch64` and `macos-arm64`; these legs run that very file, on a runner of that kind (`ubuntu-24.04-arm`, `macos-14`), so a binary
that does not start, or says another version, is red before the tag. `tools` builds `stage` for both hosts (`//tools/stage:stage_linux_aarch64`, `stage_macos_arm64`, cross-compiled on the
x86_64 runner like the command line) and takes the files of the release (`release-cli-bins`, the directory `build-cli` packaged the tarballs from; built from the commit when the call names none),
and the buck2 that `tools/buck2` pins for each host (url and sha256, checked before use). On the host, `stage native` does, for `beta/zig` and `beta/cxx` (the languages whose STEPS need only
`buildrules init` and `config` before their first `build`; the others run `cargo new`, `npm sync` or `mojo sync` first, each of which builds a pinned tool):

1. `buildrules --version` prints `buildrules <the version the x86_64 command line prints>` (`tools` reports it as an output); the machine must be the host the job names.
2. The repository is made twice, in two directories, by the steps of `STEPS` up to the first `build`, and the two have the same bytes (a hash of every file).
3. `buck2 targets` of the targets the STEPS file builds, in the first one, loads the candidate commit as the external cell (a git fetch of it) and the `BUCK` file of the hello-world repository, and lists them.

**What they do not do is build, and why.** Every toolchain of the rules is `exec_compatible_with` linux x86_64 (`rules/core/platform.bzl`), and the execution platform that local mode registers on these hosts is
`platforms:linux_aarch64` or `platforms:macos_aarch64` (`rules/platforms.bzl`), so a build has no execution platform for any action. The `platforms/BUCK` that `buildrules init` writes passes no platform for these hosts, so Buck2 refuses to load it there in local mode
(`rules/platforms.bzl`: "buildrules knows linux-x86_64 and no other host"); `stage native` therefore names the leg's targets and does not load `//...`. Behind that, every unpack action runs under the pinned busybox,
and none exists for these hosts (`docs/pins.md`, "Other hosts"): the zig, node and rust downloads for them are pinned and verified (`//rules/pins:host_downloads`, the `host_arm` job of `ci.yml`) and nothing unpacks them.
So on these hosts: rust (`cargo new` builds the pinned cargo), cxx and zig builds, node, mixed and Mojo (Linux x86_64 only, by the Mojo toolchain) do not build, and the legs say "no build yet" in their names. A leg turns into
a build leg when the busybox for the host exists and the toolchains list the host in `exec_compatible_with`. `release tested --targets` stays `linux-x86_64`: a tarball is attested as walked by a user beta only when its binary
built the hello-world repositories, and the native legs only start it.

The native legs run only after the merge, like every beta leg, and a red one blocks the tag (the beta comes before it).

## The gamma stage

`gamma` builds our own repositories with the candidate, one after the other, in the order the repository variable `GAMMA_REPOS` gives. For each:
the repository is cloned, the `commit_hash` of `[external_cell_buildrules]` in its `.buckconfig` is set to the candidate in the working copy (nothing
is committed), the farm's settings are written as its `.buckconfig.local`, and `buck2 build` of its targets (`GAMMA_TARGETS`, default `//...`) must succeed
and print `local: 0`. A repository with no buildrules cell in its `.buckconfig` is refused, since building it says nothing about the candidate: today the
mopm repository has one and the other repository planned for this stage does not, so `GAMMA_REPOS` is the mopm repository alone until the other uses buildrules.

**With no farm configured gamma fails**, and so no release is made: its first step names every repository variable that is empty. The repository owner sets these
(Settings, Secrets and variables, Actions, Variables):

| variable | what |
|---|---|
| `FARM_ADDRESS`, `FARM_INSTANCE` | the remote-execution service as a URL with a port, and its instance name |
| `FARM_LINUX_X86_64_PROPERTIES` | the worker property set |
| `TS_CLIENT_ID`, `TS_AUDIENCE` | the workload-identity credential the farm's network trusts for this repository (a new trust entry for this repository, as the other repositories have) |
| `FARM_CONNECT_REPO`, `FARM_CONNECT_REF` | the repository holding the farm-connect action, and the full commit of it to use (a commit that has the `tls` input) |
| `GAMMA_REPOS` | the repositories to build, as `owner/name owner/name`, in order |
| `GAMMA_TARGETS` | optional; the targets to build in each (`//...`) |
| `FARM_TLS` | optional; `true` when the farm speaks TLS (default `false`) |
| `RELEASE_FREEZE` | optional; `true` stops every release (read by the plan alone; see "The freeze"). Empty and `false` mean not frozen |
| `RELEASE_BOT_APP_ID` | the App id of the release bot whose token the `tag` job makes the tag with (with the secret `RELEASE_BOT_PRIVATE_KEY`, an environment secret of `release`; see "The tag ruleset"); not the farm's, and read by `tag`, `bump` and `tap` |
| `BUMP_REPOSITORY` | the name, without its owner, of the internal repository whose `buildrules` submodule the `bump` job moves to each release (see "The submodule bump"); read by `bump` alone |
| `APT_PUBLISH_ROLE_ARN`, `APT_BUCKET`, `APT_DISTRIBUTION_ID`, `APT_HOSTNAME` | optional; variables of the environment `apt-publish`: the role the `apt-deploy-*` jobs assume by OIDC, the bucket and the CDN distribution of the apt repository, and its host name. All four make the apt channel work; any one missing and every apt job ends green with a notice and writes nothing (see "The apt repository") |
| `APT_GPG_FINGERPRINT` | optional; the fingerprint of the apt signing subkey (during a key rotation a comma-separated list of the old and the new one: the index is then signed by each), as a variable or as a secret of the environment `apt-signing` (with the secrets `APT_GPG_PRIVATE_KEY` and `APT_GPG_PASSPHRASE`); read by the `apt-index` jobs alone |

No endpoint or property set is written in this repository, and the farm's values are passed to steps as `${{ vars.X != '' }}` or read from the file the
farm-connect action writes, so none is printed in a log by this repository's workflows. `FARM_ADDRESS` and `FARM_CONNECT_REF` together turn on the beta farm leg (it is skipped, with a notice, when either is empty; gamma fails instead).

## The release page

For every release the `site` job writes `site/releases/<tag>/index.html` from the verified `SHA256SUMS`: the tag, the commit to pin in `.buckconfig`
(the `[external_cell_buildrules]` lines), the archive's URL and its sha256, and the commands that check them. It is uploaded as the artifact
`release-site` of the run. The workflow `site` (see "The site") uploads it with the rest of the site.

## The site

The website, buildrules.dev, is published by two workflows, apart from `release.yml` (which keeps its job order and its token scopes, and whose `ci/release_check.zig` is unchanged by them):

- `.github/workflows/site.yml` runs when a `release` run finishes for a push to `main` and is green (and from the Actions tab, for `main`, with the input `claims_only`). Its `plan` job lets a commit
  through only if it is still the tip of `main` (a superseded run says so in a notice and deploys nothing) and the environment `prod` exists. Its `build` job checks the commit out and builds
  `//site:test //site:dist` on the runner in local mode, adds the `release-site` artifact of the triggering run when that run released, and uploads both as the artifact `site-dist`. It holds no cloud token.
- `.github/workflows/site-publish.yml` is the reusable workflow the call makes: one job, in the environment `prod`, with `id-token: write`. It asks GitHub for a token for the audience `sts.amazonaws.com`,
  exchanges it for the role `buildrules-prod-publish` (one hour; no third-party action), uploads the stylesheet with the hash in its name first and immutable, then the pages (pruned, but not the
  hashed stylesheets and not `releases/`), then the page of the release (never pruned), flushes the CloudFront cache, and fetches the site back until the edge serves the bytes that were uploaded
  (the home page, the 404 page, the `Content-Security-Policy` header and the page of the newest release).

The call is `uses: ./.github/workflows/site-publish.yml`, which for a run from `main` is the file `.github/workflows/site-publish.yml@refs/heads/main` that the role trusts. The one-time setup is `infra/site/README.md`
(steps 0 to 4, run by an administrator of the repository and of the AWS account: the environment, the zone, the stack and three variables of the environment `prod`); step 5 there is a manual run of `site` with `claims_only`, which prints the claims of the token
(never the token) to compare with the role's `sub`. **Until the setup is done the workflows deploy nothing and fail nothing**: with no environment `prod` the plan job gives a notice, with a variable of it
empty the publish job gives a notice, and both end green, so a release is never made red by the site. `ci/site_check.zig` (part of `//ci:workflow`) holds both files to this, to the triggers (no pull request, no push), to
the one place the token is held, to the environment and workflow file that `infra/site/lib/config.ts` makes the role trust, to the masks, to the order of the uploads, and plants a defect for each.

## The version

A version is `v<MAJOR>.<MINOR>.<PATCH>`.

- `MAJOR.MINOR` is the file `VERSION` (`0.0` today), changed by a normal pull request.
- `PATCH` is the highest existing `v<MAJOR>.<MINOR>.N` plus one, and 1 when there is none. The first automatic release is `v0.0.1`; then `v0.0.2`.
  Other tags (`v1`, `v0.0.1-rc1`, `latest`) are not releases and are ignored.

To bump `MAJOR.MINOR`, edit `VERSION` (`0.1`, `1.0`) in a pull request. `VERSION` is not documentation, so merging it releases: the first
release of the new line is `v0.1.1`, and `PATCH` counts again from 1. A `VERSION` lower than a tag that exists is refused (the plan job fails
and says so) rather than released.

### The version of the command line

`buildrules --version` prints `buildrules <version>`, and the version is stamped when the program is built (`cli/version.bzl`, the module `buildrules_version`):

- a release build passes the planned version, `-c buildrules.release_version=<MAJOR.MINOR.PATCH>` (`build-cli` and, for the second build, `verify` do; nothing else sets it), and the program prints that number;
- any other build (a checkout, your own farm) prints `<MAJOR.MINOR>-dev` of the `VERSION` file, so a program that was not released never claims a release number.

`cli/src/version_test.zig` holds the stamp to that shape against the `VERSION` file, as a test welded to the program. The release holds the other end: `verify` builds the three binaries again, runs
the linux-x86_64 one (which must be the file inside the linux-x86_64 tarball, and the tarballs must be the same bytes as the ones that ship) and fails the release unless it prints the release's own number.
`//cli:header_unit` also requires every built binary to hold its version (`<MAJOR.MINOR>-dev` outside a release) as a string of its own, with a NUL before and after it, which is the check `release package`
makes of a binary it cannot run.

### The command-line binaries

`cli/BUCK` builds the program for the three release targets, from one source and the same tests (only zig's `-target` differs; all are built on the Linux execution
platform, as a pure-Zig program needs no SDK to cross-compile):

| release target | target | zig `-target` |
|---|---|---|
| `linux-x86_64` | `//cli:buildrules_linux_x86_64` | `x86_64-linux-musl` |
| `linux-aarch64` | `//cli:buildrules_linux_aarch64` | `aarch64-linux-musl` |
| `macos-arm64` | `//cli:buildrules_macos_arm64` | `aarch64-macos` |

Two tests hold each target to its name. An analysis test per target (`zig_exe_target_test`, spelled with the triple again, so a change to one side alone is red) checks the triple the
rule was given; `//cli:header_unit` reads the three built files and requires an ELF of the right machine with no dynamic loader (Linux), or a 64-bit Mach-O executable of the
right cpu (macOS), and that no binary passes as another target's (`tools/release/binhdr.zig`).
A third (`same_tests_as` of the same rule) requires each cross executable to wait for exactly the unit tests of `//cli:buildrules`, and not for none, so a cross binary cannot be built with fewer tests than the program that is tested.

`//cli:release_binaries` copies the three into one directory, `<release target>/buildrules` for each (`cli/release.bzl`), so that `build-cli` and the second build of `verify` are one command each
(`buck2 build --out DIR //cli:release_binaries`); `//cli:header_unit` holds each file of the directory to the header of its path. `zig_exe_target_test` takes `same_tests_as` as a required
attribute (no default), and `ci/negative` holds a planted copy of a program with other tests that the rule must refuse. `tools/release` packages them (`binaries.zig`); the release workflow calls it as follows.

- `release package --version V --target T --binary PATH --license PATH --out DIR --exec native|none` writes `buildrules-cli-V-T.tar.gz` holding `buildrules-cli-V-T/buildrules` (0755)
  and `LICENSE`, every entry with time 0 and the tool's own gzip, so the same inputs make the same bytes. The name keeps the tarball apart from the source archive
  `buildrules-V.tar.gz`. It refuses a binary whose header is another target's, and one that does not say `buildrules V`: with `--exec native` it runs `--version`; with `--exec none`
  (a binary this machine cannot run) it looks in the file for the version as a string of its own (the version with a NUL right after it and a NUL, or the start of the file, right before it: `0.0.7` is not found in `0.0.70`, `10.0.7`, `x0.0.7` or `0.0.7-dev`), a weaker check that a run on the target's own platform must back. (The program prints `buildrules ` and its version as two strings, so `buildrules <V>` is not contiguous in the file.)
- `release package-all --version V --bins DIR --license PATH --out DIR [--native T,T]` is `package` for the three targets from `DIR/<target>/buildrules`; it runs only the binaries named by `--native`
  (`linux-x86_64`, which the runner can run) and checks the others by header and version text.
- `release debs --version V --bins DIR --channels PATH --packaging DIR --out DIR` writes `buildrules_V_amd64.deb` and `buildrules_V_arm64.deb` into `--out` by running
  `channels deb-package` (`tools/channels`) on `DIR/linux-x86_64/buildrules` and `DIR/linux-aarch64/buildrules`, the binaries the tarballs were packaged from, with the package metadata in
  `packaging/deb` (the control fields, the copyright file, the lintian overrides). The package is written by another tool and another zig, byte for byte the same for the same inputs, and the
  release tool does not trust it: `release tested` (below) reads each `.deb` back (`tools/release/debs.zig`) and requires its control file to say `Package: buildrules`, this version and its
  architecture, and `/usr/bin/buildrules` to be, byte for byte, the program inside the tarball of its target. `channels` that fails, or leaves no file or an empty one, is an error.
- `release record --tarball PATH --out DIR [--ran-binary PATH]` writes the sha256 of a tarball a user-beta leg ran (with `--ran-binary`, only if the tarball's `buildrules` is that very file), and
  `release tested --dist DIR --tested DIR [--targets T,T]` refuses unless the tarballs to attest are, byte for byte, the ones recorded for the targets walked, of one version, and nothing else is recorded. The
  targets that a user beta can walk are `linux-x86_64`, `linux-aarch64` and `macos-arm64`; **the release walks `linux-x86_64` only** (`--targets linux-x86_64`):
  the native beta legs for the Arm Linux and macOS platforms only start the binary and load a repository (see "The native legs"; they cannot build yet), so the other two tarballs are attested and verified
  (header, version, reproduction) and started on their own platform, but not walked by a user beta. The workflow names the targets, so the day a leg builds the list grows with it. `tested` also requires, for the two `.deb`s of `DIR`, that each holds the program of the tarball
  of its architecture (the user beta ran `linux-x86_64`, so the `amd64` package carries the very file it ran; the `arm64` one carries the aarch64 file that is attested but not walked).
- `release sums --dist DIR` writes `SHA256SUMS` over the source archive, the three tarballs and the two `.deb`s in name order (six lines) and reads it back; it refuses a missing, stray or other-version tarball or `.deb`.
- `release sign --dist DIR [--cosign PATH] [--dry true|false]` runs keyless `cosign sign-blob` on those six files and `SHA256SUMS`, and refuses a bundle that is missing, empty or already there. With `--dry true` it makes every check and the list of files it would sign, and runs no `cosign`; `release.yml` always passes `--dry false`, as it passes it to `plan` and `verify`, since no pull request runs it (the dry form stays in the tool and its tests, and nothing in the workflow uses it).

## What is released

A green commit on `main` is released when the files changed since the last release tag include one that is not documentation or CI. The
filter (`isDocOrCi` in `tools/release/version.zig`, tested path by path) excludes:

- `docs/`, every `*.md` (READMEs and this file), `LICENSE` and `.gitignore`;
- `.github/` and `ci/` (the workflows, the CI target groups, the completeness and workflow checks).

Everything else is released: the rules, the pins and toolchains, the command line, `VERSION`, `tools/` (the release tool too), the examples, and
also `site/` and `infra/`, which are built and tested code. The comparison is with the last release tag, not with the previous commit: a
docs-only push after a release makes nothing, and the next code push releases the lot. A commit that is not after the last release tag (an older run
finishing late) is skipped, never released out of order. A re-run of a released commit creates no tag and carries on with the one it has.

## What a release holds

- `buildrules-<version>.tar.gz`: the tracked files of the tested commit under `buildrules-<version>/`, e.g. `buildrules-0.0.1/`.
- `buildrules-cli-<version>-<target>.tar.gz` for `linux-x86_64`, `linux-aarch64` (static musl executables) and `macos-arm64`: a directory of that name holding `buildrules` (0755) and `LICENSE`,
  every entry with time 0 and the tool's own gzip. `buildrules --version` prints `buildrules <version>`. The macOS program is for Apple silicon (arm64); there is no program for an Intel Mac. It is not code-signed or notarised.
- `buildrules_<version>_amd64.deb` and `buildrules_<version>_arm64.deb`: the Debian package of the command line for the two Linux targets (`/usr/bin/buildrules`, the copyright file, a changelog and the lintian
  overrides, from the metadata in `packaging/deb`), made from the same binaries as the tarballs and checked against them. The `.deb` of a pre-release would be named with `~`; the versions of the scheme have none.
- `SHA256SUMS`: six lines, the sha256 of the archive, of the three tarballs and of the two `.deb`s in name order (`sha256sum --check` reads it).
- `<file>.sigstore.json` for each of those seven files: a keyless cosign signature (Sigstore) made by the `attest` job, whose identity is this workflow on `refs/heads/main`.
- The notes: how to pin it, the tarballs with their sha256, how to verify, and the commit subjects (no merge commits) since the previous tag.
- A build provenance attestation (GitHub's, signed with the workflow's identity) of each of the seven files.
Fourteen files in all; `publish` refuses a release that would hold any other. (The release before the `.deb`s held ten; the asset count changed on purpose, and `ci/release_check.zig` pins the files each step handles.)

The archive is reproducible, with one stated dependence. `git archive` writes the tar with a fixed prefix, a fixed modification time, the modes of
umask 022, and `core.autocrlf=false` and `core.eol=lf` (so no setting of the runner converts a line ending); the tool compresses it with its own gzip (a
fixed 10-byte header with no name and no time, one DEFLATE block with a fixed Huffman code over a greedy LZ77 parse), so no `gzip` or zlib of the
runner enters the bytes. The tar bytes themselves are git's: the same tag archived by another git version could differ in the tar, so the archive is
made once, by `archive`, and `verify` builds it a second time from the commit, with the same git on the same runner, and requires the same bytes. A
consumer relies on the published file and its sha256, not on making the file again.

`verify` checks, and `publish` refuses to go on without:

1. `SHA256SUMS` is exactly the sha256 of the archive, of the three tarballs and of the two `.deb`s, one line each in name order, and nothing else (`verify` and `publish` read all six lines; the one-line reader of the
   earlier releases is gone), and the three tarballs and the two `.deb`s are those of this version, once each;
2. the checkout is the commit that was tested (no tag exists yet; `publish` later requires the annotated tag to peel to that sha);
3. the attestations of all seven files verify (`gh attestation verify`), pinned to this workflow, the commit, and `refs/heads/main`, and so do the seven keyless signatures (`cosign verify-blob`, pinned to the
   identity of this workflow on `refs/heads/main`, the issuer, the commit, the push trigger and this repository) (`verify`, with `--dry false`);
4. building the archive again from the commit gives the same bytes;
5. building the three binaries again from the commit, on another runner with the same stamp, packaging them, gives the same three tarballs and the same two `.deb`s byte for byte, and each `.deb` is the package of its
   version and architecture and holds the very `buildrules` of the tarball of its target;
6. the program built in that second build prints the release version (`buildrules --version` is `buildrules <MAJOR.MINOR.PATCH>`, the planned number: see "The version of the command line") and is the very file the
   linux-x86_64 tarball holds, so the version checked is the version of the file that ships;
7. the archive's file list equals `git ls-tree -r` of the commit (a missing, extra or repeated file is a failure);
8. the scrub (`tools/scrub`: dates, names, addresses and the like that a public repository must not hold) passes on the archive's contents.

**The retry of `cosign verify-blob`.** Each of the seven signatures is checked with one `cosign verify-blob`. When cosign cannot fetch the Sigstore
trusted root (the TUF repository), the call is tried up to 3 times, waiting 2 s and then 4 s between the tries. Only the final line of cosign's error
output decides: it must hold `tuf refresh failed`, `Could not fetch trusted_root.json` or `error getting live trusted root`. Any other refusal, a
signature or certificate mismatch above all, is a finding on the first try; so is a mismatch that follows the legacy-bundle
`Could not fetch trusted_root.json ... Continuing` warning. One more shape is retried: cosign v3.0.6 (the version the release installs) ends a failed fetch with `trusted root is required when using new bundle format` (the fetch error is only the warning line before it), and that final line retries only when an earlier line holds one of the three fetch texts; alone it is a finding. An outage longer than about 6 s still fails the release, and the finding says it is "a network
failure, not a verdict on the signature"; re-run the job.

`publish` repeats the check of `SHA256SUMS` and requires all seven signature bundles to be there and not empty.

A re-run creates no second release and replaces no asset. If the release exists, each of the seven files it already holds (the archive, the three tarballs,
the two `.deb`s and `SHA256SUMS`) must have the sha256 of ours or the job fails and changes nothing; a file it lacks is added. A signature bundle is the one
file that may differ: every signing makes a new bundle (a new certificate and a new transparency-log entry), so a re-run of a released commit, which rebuilds the
same seven files and signs them again, keeps the bundle the release holds when the file it signs is held with the same bytes, and ends green. A bundle beside a
file that differs, or beside a file the release lacks, still fails the job. A release is never edited by the pipeline.

## Pinning a release

From another repository, in one of three ways, each naming a tag and something that cannot move:

**The commit, in `.buckconfig`** (what `buildrules init --git` writes). Take the tag's commit and pin it:

```
git ls-remote https://github.com/komira-ai/buildrules 'refs/tags/v0.0.1^{}'
```

```
[external_cells]
  buildrules = git
[external_cell_buildrules]
  git_origin = https://github.com/komira-ai/buildrules
  commit_hash = <the 40-hex commit that line printed>
```

**The archive, with its hash.** Download, check, unpack into the directory the cell points at (`buildrules init --path`):

```
https://github.com/komira-ai/buildrules/releases/download/v0.0.1/buildrules-0.0.1.tar.gz
sha256sum --check SHA256SUMS
tar -xzf buildrules-0.0.1.tar.gz
gh attestation verify buildrules-0.0.1.tar.gz --repo OWNER/REPO
```

(`OWNER/REPO` are the two path segments of the repository URL above.)

**The tag and the hash, written down.** Keep `v0.0.1` and the sha256 from the release notes in your own pin file; the commit above is the
same fact in git's terms.

## Installing the command line

Pick the tarball of your platform from the release (`linux-x86_64`, `linux-aarch64`, `macos-arm64`), check it, unpack it and put `buildrules` on your `PATH`:

```
curl -fsSLO https://github.com/komira-ai/buildrules/releases/download/v0.0.1/buildrules-cli-0.0.1-linux-x86_64.tar.gz
curl -fsSLO https://github.com/komira-ai/buildrules/releases/download/v0.0.1/SHA256SUMS
sha256sum --check --ignore-missing SHA256SUMS
tar -xzf buildrules-cli-0.0.1-linux-x86_64.tar.gz
buildrules-cli-0.0.1-linux-x86_64/buildrules --version
gh attestation verify buildrules-cli-0.0.1-linux-x86_64.tar.gz --repo OWNER/REPO
```

(`v0.0.1` and `0.0.1` stand for the release you take.) With Homebrew or apt, **after setup** (see "The Homebrew tap" and "The apt repository"): `brew install <owner>/tap/buildrules`, or
`sudo apt install buildrules` from the apt repository, or `sudo apt install ./buildrules_0.0.1_amd64.deb` (`arm64` on Arm) with the file of a release, checked as above. `--version` prints `buildrules <version>`, the number of the release. The program is static, so it needs nothing else on the machine. The macOS program
is not code-signed or notarised, and the release is not a promise that it runs: the user beta walks the linux-x86_64 program only (see "The command-line binaries").

The same steps are the install script, `site/static/install.sh`, which the site serves as `https://buildrules.dev/install.sh` once it is published: `curl -fsSL https://buildrules.dev/install.sh | sh` picks the tarball of the machine (Linux x86_64 and arm64, macOS arm64; an Intel Mac is refused by name before any request), checks it against `SHA256SUMS`, and installs `~/.buildrules/bin/buildrules` (`--prefix DIR` for another place, `--version V` for another release). `--verify` also runs `cosign verify-blob` with the tarball's `.sigstore.json` bundle, the identity of the release workflow on `refs/heads/main` and the Actions issuer, and stops if `cosign` is not installed. The sha256 check proves the tarball is the one `SHA256SUMS` lists from the same place; `--verify` proves who signed it; neither is a promise about macOS code signing. `tools/install` tests the script as a build action against fake releases over loopback and plants a defect for each of its checks (`buck2 build //tools/install:install_script_test`).
## The tag ruleset

A ruleset on the repository lets only one GitHub App, the release bot (the repository owner's release bot, installed on this repository), create, update or delete a
`v*` tag; GitHub does not accept the Actions integration as a bypass. So the `tag` job holds `contents: read` from `GITHUB_TOKEN` and mints the bot's
installation token with `actions/create-github-app-token` (pinned by commit), restricted to this repository (`owner: ${{ github.repository_owner }}`, `repositories: buildrules`)
and to `permission-contents: write`, from two things the repository owner creates **before the next release run**:

| name | kind | what |
|---|---|---|
| `RELEASE_BOT_APP_ID` | repository variable | the App id of the release bot |
| `RELEASE_BOT_PRIVATE_KEY` | secret of the environment `release` | the App's private key (PEM); not a repository secret |

The key lives in the environment `release`. Restricting that environment to the `main` branch (deployment branches: `main` only) is a setup step for the repository owner; **this repository does not set it and no check here sees it**, and until it is made a workflow run from another branch that declares the environment can read the key. The repository-level copy is removed (the owner's held script creates the environment, moves the secret into it and deletes the repository copy). `tag` and `bump`, the only jobs that read `RELEASE_BOT_*`, declare `environment: release`; no other job declares an environment. `ci/release_check.zig` holds this: exactly the jobs that read `RELEASE_BOT_*` declare `environment: release`, any other job with an environment is a finding, a job that reads them without it is a finding, and `ci/workflow_check.zig` refuses an `environment:` in `ci.yml`. Until that script has run, a job that declares `environment: release` still reads the repository-level secret (GitHub creates an empty environment on first use), so the order is: merge the change, then run the script.

Only the `tag` step receives that token (`GH_TOKEN: ${{ steps.bot.outputs.token }}`); `publish` keeps `GITHUB_TOKEN` with `contents: write`, which is enough
because `gh release create --verify-tag` aborts when the tag does not exist and creates no tag (the tool passes it, `tools/release/cmds.zig`). If either name is
missing the token step fails, `tag` is red, **no tag is made and nothing is published**; fix the name and re-run the failed jobs. `ci/release_check.zig` holds
the workflow to all of this: `tag` is the only job that mints this token (`bump` and `tap` mint their own, for their repositories), with exactly these inputs, the key is read once in that job (and once in each of the other two), the token output is
used by the tag step alone, `tag` holds `contents: read` and no job but `publish` may hold `contents: write`.

## The submodule bump

The repository owner's internal repository holds this repository as the submodule `buildrules`. The last job of a release, `bump`, moves that submodule to
the released commit: `tool/release bump-internal` (a copy of the tool the sibling tool's release uses, with no dependency on it) opens a pull request in the
internal repository on the branch `bump/buildrules-v<semver>` that changes **one path, the gitlink `buildrules`**, and turns auto-merge on. The internal
repository merges it when its required checks pass, among them its bump guard. The guard admits a pull request of the release bot only when exactly one
path changed and it is a gitlink of a submodule listed in `.gitmodules`; the branch is `bump/<submodule>-v<semver>`; the new commit descends from the old
one; and this repository's tag `v<semver>` names the new commit. The tool refuses, before it writes anything, whatever the guard would refuse:

1. the tag `v<semver>` of this repository names `--sha` (`gh api repos/<repo>/commits/<tag>`), which is why `bump` waits for `tag` and `publish`;
2. an open or merged bump pull request for this or a **newer** version means there is nothing to open (an open one for this version without auto-merge gets
   it); versions are compared as numbers, so `1.10.0` is newer than `1.2.3`;
3. a branch `bump/buildrules-v<semver>` that an earlier run pushed and stopped at is reused when its gitlink is `--sha` and refused when it is another commit;
   otherwise a shallow clone of the internal repository (no submodule initialised), the gitlink set with `git update-index --cacheinfo 160000,<sha>,buildrules`,
   a check that the staged change is exactly one modified gitlink at that path, a check that `--sha` is **ahead of** the old gitlink (GitHub's compare), the
   commit by the release bot, and a push of the branch that is never forced;
4. `gh pr create`, then `gh pr merge --auto --merge`, then a check that auto-merge is on;
5. every older open bump pull request is closed in favour of the new one.

A re-run opens nothing twice. `bump` runs after `publish` and nothing waits for it, so a failed bump is a red run that un-releases nothing: fix the cause and
re-run the failed job.

The token is the release bot's installation token for the internal repository, minted by a second use of `actions/create-github-app-token` (the same
pinned commit and the same two names as the tag token) with `repositories: ${{ vars.BUMP_REPOSITORY }}`, `permission-contents: write` and
`permission-pull-requests: write`. The tool puts it in `GH_TOKEN` for `gh`, and gives `git` an HTTP header through `GIT_CONFIG_*` in its environment; it is
never an argument of any process, and the tool refuses to run a command whose arguments contain it. The commit is authored and committed by the bot user
(its login and the noreply address of its user id, both spelled in parts in `tools/release/bump.zig`).

What the repository owner creates **before the next release run** (in addition to the two names of "The tag ruleset"):

| name | kind | what |
|---|---|---|
| `BUMP_REPOSITORY` | repository variable | the name (no owner) of the internal repository; the owner is this repository's own |

and the release bot App installed on the internal repository with `contents` and `pull requests` write. A first step of `bump`, `tool/release bump-check`, refuses
an empty or malformed name **before the token is minted**: a token minted for an empty `repositories` list reaches every repository of the installation.
`ci/release_check.zig` holds the workflow to all of this: `bump` holds `contents: read`, is under the exact `if:` of `tag` and `publish`, waits for `plan`, `tag`,
`publish` and `tool`, and nothing waits for it; the key is read three times (`tag`, `bump` and `tap`), each token is minted with exactly its inputs and used by one step;
the repository is the owner's own plus the variable; and the arguments of the bump step are the ones the guard depends on.

## The Homebrew tap

After `publish`, the `tap` job (a push to `main` only, `contents: read`, in the environment `release`) renders `Formula/buildrules.rb` and opens a pull request with it in the
organisation's Homebrew tap, the repository `<owner>/homebrew-tap` that `brew tap <owner>/tap` reads. `tool/tap` (`tools/deploy/tap.zig`; `gh` and `git`, no shell) does the pull request;
`tool/channels formula` (`tools/channels/formula.zig`) renders the file. Both are built by `tool` before any job holds a token.

- **Where the checksums come from.** The job downloads `release-dist` (the files `verify` checked and `publish` released) and runs `channels formula` on its `SHA256SUMS`. Nothing is downloaded or hashed
  anew: the formula can only say what the verified `SHA256SUMS` says. The command is fixed by `ci/release_check.zig` (`tap_render`): the name `buildrules`, the asset stem `buildrules-cli` (the tarballs are
  `buildrules-cli-<version>-<target>.tar.gz`; the source archive owns `buildrules-<version>.tar.gz`), no `version` line (`--no-explicit-version`: `brew audit --strict` refuses one that repeats the
  release url's), this repository's release urls, and the three targets `macos-arm64`, `linux-aarch64` and `linux-x86_64`, with `bin.install "buildrules"` and a test that runs `buildrules --version`.
- **The tap's guard.** The tap admits a pull request only through its path guard (`.github/guard/guard.js` there): the bot's branch `bump/<formula>-v<version>`, exactly one file `Formula/<formula>.rb`, the file the
  renderer's output line for line (an exact allow-list), a version above the formula on `main`, and the tag `v<version>` in `<owner>/<formula>`. `tools/channels/channels_cli_test.zig` reads the render
  command out of `release.yml`, runs it on the fixture sums, and requires the formula the guard is to accept (`tools/channels/testdata/tap_guard_buildrules.rb`) byte for byte.
  **The guard does not admit it yet.** Its template builds the tarball names as `<formula>-<version>-<target>.tar.gz`, so `buildrules-cli-...` is refused. The smallest change is a per-formula
  asset-name map in the guard, `const ASSET_STEMS = { buildrules: 'buildrules-cli' }; const stem = (name) => ASSET_STEMS[name] || name;`, used where `template()` writes the `url` lines and in the url
  pattern of `baseVersion()`, with the fixture and its tests. It is a change to the tap, not to this repository, and it is not made here. Until it is made, the pull request that `tap` opens stays open
  with a red `guard` check and merges nothing; the release is not affected.
- **The token.** As for `bump`: in the second to last step `actions/create-github-app-token` (pinned by commit; `owner: ${{ github.repository_owner }}`, `repositories: homebrew-tap`,
  `permission-contents: write`, `permission-pull-requests: write`) gives the release bot's installation token for the tap repository alone to the last step, which runs `tool/tap`, as `GH_TOKEN`; it is never an
  argument. The job holds `contents: read` of its own and runs nothing after the token exists. `ci/release_check.zig` holds all of that: the exact inputs, the mint immediately before the last step,
  the token used once, by that step, the key read once in the job, the environment `release` (where the key lives; restricting it to `main` is the owner's setup step), the render step before the mint, and the arguments the guard depends on.
  The App must be installed on the tap repository; if it is not, the mint fails, `tap` is red and nothing else is affected.
- **What the tool does.** It checks that the file is the formula of this version (every url `.../releases/download/v<V>/buildrules-cli-<V>-<target>.tar.gz`, one `<V>`, no `version` line) and that the tag exists;
  reads `Formula/buildrules.rb` on the tap's `main` and **refuses (red) when its version is above this release's** (a tap never moves down; the same version means it is already there: nothing to open); lists
  the tap's pull requests; clones shallowly, writes only `Formula/buildrules.rb`, checks that the staged change is that one added or modified file, commits `buildrules <version>` as the bot, pushes
  `bump/buildrules-v<version>` (never forced), opens the pull request and asks for `gh pr merge --auto --squash`.
- **Idempotent.** An open or merged pull request for this or a newer version means there is nothing to open (an open one for this version that lacks auto-merge gets it asked for). A branch an earlier run
  pushed before it stopped is reused when it holds these bytes. An older open `bump/buildrules-v*` pull request is closed in favour of the new one; nothing is ever force-pushed.
- **When the tap has no required checks** GitHub can refuse to enable auto-merge ("Pull request is in clean status"). That is not a failure: the job stays green, prints a notice, and the pull request stays open for the
  tap's owner to squash-merge.
- **A failed tap un-releases nothing.** Nothing waits for `tap`; re-run the job of that run, it finds what exists and finishes the rest.

Installing from the tap (**after setup**: the guard change above, and the pull request of the release merged): `brew install <owner>/tap/buildrules`.

## The apt repository

After `publish`, the two `.deb`s of the release (the ones `verify` checked, in `release-dist`) go into the apt repository that the products of the organisation share (`tools/deploy/apt_publish.zig` is the
command line the jobs run; `tools/channels apt-index` merges and renders the index). The repository is one tree: the `.deb`s of a product below its own pool directory (for buildrules `apt/pool/buildrules/`, the
`Filename` of a package is `pool/buildrules/buildrules_<version>_<arch>.deb`), and one signed index (`dists/stable/`) that lists the packages of every product. buildrules writes its own packages and keeps the rest
of the index as it finds it.

**Three jobs per attempt, and why.** Writing the index needs three things that must not meet in one job: the cloud role (to read and write the repository), the archive signing key (to sign the merged index), and
the merged index itself. So:

| job | environment | holds | does |
|---|---|---|---|
| `apt-deploy-read` | `apt-publish` | the role (OIDC, `id-token: write`), no key | reads the current index and the ETag of every object of it from S3 (never through the CDN, which caches the index and would hand back a stale ETag) and passes it on as an artifact |
| `apt-index` | `apt-signing` | the signing key, no role, no `id-token`, no cloud credential | merges the `.deb`s into the index that was read (`channels apt-index`) and signs `Release` with the signing subkey: `InRelease` and `Release.gpg` |
| `apt-deploy-write` | `apt-publish` | the role (OIDC), no key | uploads the `.deb`s with `If-None-Match` (a `.deb` is never replaced), writes the index with `If-Match` on the ETag it was read with (`If-None-Match` for an object that did not exist yet), then invalidates `/apt/dists/*` |

The job that can sign cannot write, and the job that can write cannot sign; the index travels between them as an artifact only the workflow can create. `ci/release_check.zig` holds that: the key (`APT_GPG_*`)
is named by the `apt-index` jobs alone, in their signing step, which hold `contents: read` and no `id-token`; the role (`APT_PUBLISH_ROLE_ARN` and the OIDC exchange) by the `apt-deploy-*` jobs alone, which read no
secret; `id-token: write` is held by those, by `attest`, `gamma` and the call of `beta`, and by nothing else; no job names both; each job declares its environment; none runs buck2 or checks the repository out.
The puts themselves are held by `tools/deploy/drivers/apt_publish_test.zig`, which runs the real tool against a fake `aws` that refuses every call the role may not make, a fake `gpg` and a fake `curl`.

**The order of the writes.** The pool first (the index must never list a file that is not there); then the by-hash copy of every `Packages` and `Packages.gz` (`dists/stable/main/binary-<arch>/by-hash/SHA256/<hash>`,
`If-None-Match`; the `Release` says `Acquire-By-Hash: yes`); then the plain `Packages` files; then `Release`, `Release.gpg` and `InRelease` last; then the invalidation. The `If-Match` of `InRelease` is the commit
point. A write that stops anywhere leaves either the old `Release` or `InRelease` with the index files it lists, found by their hashes (the old by-hash files are never replaced or removed), or the new one with
its by-hash files already there; the driver stops the write after every put and checks exactly that.

**The shared `Release`.** The `Origin`, `Label` and `Description` of a `Release` that exists stay as they are; the repository owner's name given with `--origin`, `--label` and `--description` applies to the first
`Release` only.

**A lost write.** Another product may publish between the read and the write. Every put of the index is conditional on the version that was read, so the loser gets a `412`: it writes nothing more, says so, and its
output `conflict=true` starts the next attempt (`apt-deploy-read-2`, then `-3`), which reads, merges and signs again. The write of the third attempt (`--last`) fails the job instead. A `.deb` that is already in
the pool (a `412` on its put) is kept as it is **if it has the same bytes**: the tool reads the object back (`get-object`) and compares its sha256 with the file to publish. A pool object with other bytes is a red failure
(a version published twice with different files, or a build that is not reproducible), and so is one that cannot be read; either way nothing of the index is written. The publish role therefore needs `s3:GetObject` on the
product's pool prefix (`apt/pool/buildrules/*`) as well as on the index.

**The settings, and what happens until they are made.** The repository owner makes them once:

- the environment `apt-publish` (restrict its deployment branches to `main`, also a setup step) with the variables `APT_PUBLISH_ROLE_ARN`, `APT_BUCKET`, `APT_DISTRIBUTION_ID` and `APT_HOSTNAME`, and a role whose trust names this repository and that environment;
- the environment `apt-signing` (restrict its deployment branches to `main`, also a setup step) with the secrets `APT_GPG_PRIVATE_KEY` and `APT_GPG_PASSPHRASE`, and `APT_GPG_FINGERPRINT`, the fingerprint of the signing subkey (or a comma-separated list of them, while a key rotation signs with the old and the new subkey at once, `APT_GPG_PRIVATE_KEY` then holding both), as a secret or as a variable.

GitHub creates an environment the first time a job names it, with no variables and no restriction, so the first release after this change creates both empty. **Fail-safe.** Every apt job has a step `gate`
(`apt-publish gate`) that checks the settings it needs, after only the step that makes the tool executable. When one is missing the gate prints a notice that names it (the names, never a value), and every later
step that reads, signs, writes or assumes the role is skipped by `if: steps.gate.outputs.enabled == 'true'`: the job ends green and writes nothing. `ci/release_check.zig` holds that every such step carries that
condition and that each gate is the exact command. So a release that runs before the settings exist (or with only half of them) releases exactly as before and the apt jobs leave a notice; a half-made setting (the role
without the key, or the key without the role) leaves the repository unchanged. Once both are made, the next release publishes without any other change. The region of the repository is `us-east-1`.

Installing from the apt repository (**after setup**: the settings above made, and the public half of the signing key uploaded where the repository documents it; `<apt host>` is `APT_HOSTNAME`):

```
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://<apt host>/apt/keyring.gpg | sudo tee /etc/apt/keyrings/<owner>.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/<owner>.gpg] https://<apt host>/apt stable main" | sudo tee /etc/apt/sources.list.d/<owner>.list
sudo apt update
sudo apt install buildrules
```

The keyring file name is decided when the owner uploads it. `apt update` verifies `InRelease` against it before it trusts a `Packages` file. Until then, install the `.deb` of a release by hand
(`sudo apt install ./buildrules_<version>_amd64.deb`, after the checks of "Installing the command line").

## What the first release after this change does with no setup

Nothing needs a setting to release. With the repository as it is: the release carries the two `.deb`s (fourteen files instead of ten) and is otherwise as before. `tap` runs (no variable gates it): it renders the formula
and, if the release bot App is installed on the tap repository, opens `bump/buildrules-v<version>` there; the tap's guard refuses it until the asset-name change above is made (a red check on that pull request, a
green `tap` job). If the App is not installed on the tap repository the mint step fails and `tap` is red, which un-releases nothing. The three apt attempts' first jobs find no `apt-publish` variables, print the notice
and end green; `apt-index` finds no key and ends green; `apt-deploy-write` ends green; nothing is read from or written to any bucket, and no cloud role is assumed. The environments `apt-publish` and `apt-signing` are
created empty by GitHub as the jobs name them.

## Downloads that fail

Every pin is a download (sha256 and size checked), and the second beta build starts with no `buck-out`, so it downloads all of them again. Three layers keep an
upstream host that drops a request from blocking a release, and none of them can change the bytes (the hash is checked on every path):

- **Timeouts.** buck2's own defaults are a 5 s connect and a 10 s read timeout (`DEFAULT_CONNECT_TIMEOUT_MS`, `DEFAULT_READ_TIMEOUT_MS` in the daemon), and buck2 itself retries
  a failed download three times (2, 4 and 8 s). The first release failed with `Timed out while making request ... after 5 seconds` on all three. The repository and every
  repository `buildrules init` writes now set `[http] connect_timeout_ms = 30000` and `read_timeout_ms = 120000`.
- **Retry in the stage tool.** A beta `buck2 build` that fails with buck2's `materializing HTTP resource` error AND a transport cause (a timeout, a refused or reset
  connection, `Error sending request`, `tcp connect error`, `No route to host`, `Network is unreachable`, a 5xx or 429; matched without regard to case, as buck2 and the
  HTTP client under it spell them differently) is made again, up to 3 times, waiting 20, 40 and 80 s. A compile error, a failed test, a wrong hash, a determinism difference, or a test
  whose own output says "timed out" is **not** retried: the pair is required. The first retry asks the same host; the second and third pass
  `-c buildrules.url_map=...` (`mirror_map` in `tools/stage/beta.zig`) so the pins come from their mirrors.
- **Mirrors** (`docs/pins.md`, "Mirrors"): where a pin has a host that serves the identical bytes, the map names it. `pinned_file` applies `buildrules.url_map` to every
  download it declares.

## Two pushes at once

The workflow runs one push at a time. Its concurrency is one group for every push (`release-push`; any other event would get a group of its own, its run id)
with `cancel-in-progress: false`: a run that is publishing is never stopped, GitHub keeps at most one pending run, and a newer pending run replaces an older
pending one, which ends **cancelled** (not red) and releases nothing. `site.yml` runs only when a release run ended green (success only), so a cancelled run starts no deploy of the site. So when several pull requests merge within minutes, the runs go one after the other, the
plan of each reads the tags only after the run before it (tag included) has finished, and the race below cannot happen; the newest push is the one that
releases, and it carries the changes of the commits it replaced. What follows is the second line of defence, for a race that serialization does not cover (a
re-run of an old run, say). `ci/release_check.zig` refuses a workflow-level group per commit and a `cancel-in-progress` other than `false`.

The rule is one concurrent run of each workflow of the release pipeline: one fixed group per workflow, `cancel-in-progress: false` (`ci/release_check.zig`, `ci/stages_check.zig` and `ci/site_check.zig` pin each). The groups: `release.yml` `release-push` (a push; a run id for any other event), the job `tag` `release`, `beta.yml` `beta` (called by `release.yml`; a different name from the caller's, so neither waits for the other), `site.yml` `site`, `site-publish.yml` none (called by `site.yml`, whose group serializes it; a group of its own with the caller's name would deadlock, and the check refuses any). `ci.yml` is the pull request check and cancels the superseded run of a pull request; it is not part of the release pipeline's serialization.

The plan runs before the build, so two pushes that land within the time of a build (minutes) both plan the same number: with `v0.0.5` the newest tag, both plan
`v0.0.6`. The binaries, the archive, the sums, the signatures and the attestations of each carry its planned number. The `tag` job is the one place the
numbers are settled: it is alone (concurrency group `release`, nothing cancelled), and it fetches the tags again before it decides, from the tags as they are
then (`tool/release tag`, `settleTag` in `tools/release/cmds.zig`). For the commit `C` of the run and the newest release tag `N`:

| what `tag` finds | what happens |
|---|---|
| a tag already names `C`, and it is the planned one | a re-run: the tag is kept, and `site`, `publish` and `bump` go on with it (even when newer releases exist: `publish` still refuses a release below the newest) |
| a tag names `C` under another number | the job fails (`TagMismatch`): the build carries the planned number |
| `C` is contained in `N`'s commit (an ancestor of it) | the run ends **green as superseded**, with a notice naming `N`: that release carries `C`'s changes, so `site`, `publish` and `bump` are skipped and nothing is created |
| `C` is not contained in `N`'s commit, and the planned number is the next free one | the tag is made, as before |
| `C` is not contained, and the planned number is taken (the earlier push tagged first, at a commit that does not contain `C`) | the job fails (`NumberTaken`) with nothing created, and says so: the next free number differs from the one the build stamped |

The last row is red on purpose. A tag under another number than the one the binaries print (`buildrules --version`), the archive names and the signatures would be a
release whose files disagree with its tag, and re-stamping means building, attesting and verifying again, which the job that holds the token never does. The
fix is cheap and safe: **re-run all jobs** of that run (not only the failed ones): the plan is computed again from the tags that exist, the commit is built and
released under the free number. If nobody re-runs it, the next push to `main` releases it with everything else since the last tag. A tag is never moved. The
number of `publish`, `site` and `bump` is `needs.tag.outputs.tag`, not the plan's; `ci/release_check.zig` refuses a workflow in which they read the plan's tag, or do
not skip a superseded run.

## When something fails

A red `gate`, `build-cli`, `beta`, `gamma`, `archive`, `attest` or `verify` releases nothing and **leaves no tag**, and the next green push releases everything since the last
tag. If `tag` or a job after it fails, re-run the failed jobs of that run: `tag` keeps a tag that already names the commit (and fails, creating nothing,
when the number is taken by another commit: re-run **all** jobs then, see "Two pushes at once"), and `archive`, `verify`, `site` and `publish` are safe to repeat, `publish` adding only what is missing. A `VERSION`
behind the tags fails `plan` until `VERSION` is fixed.

**An old run is never published after a newer one.** Before `publish` creates a release it lists the releases and refuses (the job fails and creates
nothing) when one with a higher number exists, and the release it creates is marked the latest. So re-running the failed jobs of an old run after a newer
release is a red run and not a release below the newest; adding a missing file to a release that exists is still allowed. A tag that has no release does
**not** block the next tag: the plan takes the highest tag plus one whether or not that tag was ever published, so one failed publish cannot stop
every later push. Such a tag stays without a release (its archive was never published); the next release's notes list the commits since it.

## Before the first release: rehearse (a step for the repository owner, proposed)

The first real run makes a real tag and a public release, neither of which can be taken back. Before it, run the whole pipeline once in a throwaway
test repository: a copy of this repository with its own tag namespace, the repository variables above set (or the farm stages deliberately failing, to
see their message), and a push to its `main`. Check that `beta` is green on the runners and that the farm-less `gamma` fails with the variable list; set the
variables and check that it passes; check the tag, the release, the attestations (`gh attestation verify`), the `site` artifact and a re-run of the whole
run, which must change nothing. Then delete the test repository. Nothing in this repository creates it: it is a step for the repository owner, who owns the account it
would live in.
