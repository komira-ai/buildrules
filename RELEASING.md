# Releasing buildrules

A release is automatic. Every push to `main` is tested in stages, and a green one that changes more than documentation or CI is released with
no human action: a tag, and a GitHub release carrying a source archive, its `SHA256SUMS` and the notes. A consumer pins the tag and the archive's
sha256 (or the tag's commit). There are no binaries: buildrules is rules, and the command line is built from this source on your farm.

`.github/workflows/release.yml` is the pipeline. `tools/release` and `tools/stage` (Zig, tested as build actions) do each step; the workflow's `run:` lines are
one invocation each. `ci/release_check.zig` and `ci/stages_check.zig` (part of `//ci:workflow`) hold `release.yml` and `beta.yml` to what is written here.

## The stages

| job | what it does | token |
|---|---|---|
| `gate` | the PR gate: calls `ci.yml`, the whole tree (`//ci:all`) and the completeness check, in local mode on the runner | read |
| `beta` | calls `beta.yml`: hello-world repositories per language consume the candidate commit as a user would and are built twice, the second time in another directory (see "The beta stage") | read, `id-token` for its farm leg |
| `gamma` | builds our own repositories with the candidate on the farm; fails the release when the farm is not configured (see "The gamma stage") | read, `id-token` write |
| `tool` | builds `tools/release` and `tools/stage` with buck2 and hands the binaries to the later jobs, before any job that writes holds a token | read |
| `plan` | read-only; decides whether this commit is released and which version; creates nothing | read |
| `cli` | builds `//cli:buildrules` from the tested commit with the planned version stamped in (`-c buildrules.release_version=<version>`), in local mode; hands the program to `verify`. It is not a release asset: there are no binaries | read |
| `archive` | `git archive` of the tested commit (its sha, not a tag) under `buildrules-<planned version>/`, compressed by the tool's own gzip, `SHA256SUMS`, and a build provenance attestation of both files | `id-token`, `attestations` write |
| `verify` | read-only; checks everything below before a file is published, and runs the command line that `cli` built (`buildrules --version` must print the release) | read |
| `tag` | the annotated tag at that sha, made only after the archive is verified, with the release bot's token (see "The tag ruleset"). A tag that exists at the sha is kept; one at another commit fails the job | read; the write is the bot's token, minted in this job and used by the tag step alone |
| `site` | read-only; the page of the release (the pin snippet) as an artifact; the workflow `site` deploys it (see "The site") | read |
| `publish` | needs `tag` and `verify`; checks the tag peels to the verified sha, then creates the GitHub release from the verified files | `contents: write` |
| `bump` | needs `plan`, `tag`, `publish` and `tool`; opens the pull request that moves the internal repository's `buildrules` submodule to the released commit, with auto-merge (see "The submodule bump"). Nothing waits for it | read; the write is the bot's token for the internal repository, minted in this job and used by the bump step alone |

The order is `gate`, `beta`, `gamma`, `plan`, `archive`, `verify`, `tag`, `publish` (`cli` beside `archive`, before `verify`; `site` after `tag` and `verify`); a job runs only if the one before
it succeeded. **Nothing before `tag` waits for it, so a failure in the archive, its attestation or its verification leaves no tag behind**: the tag is the
first thing in the pipeline that cannot be taken back, and it is made last but for the release (`ci/release_check.zig` refuses a `needs: tag` in any job before it).
A `GITHUB_TOKEN` write scope
exists only in `publish` (`contents`), in `archive` (`id-token`, `attestations`), and `id-token` also in `gamma` and in the call of `beta`
(the farm's network trusts the job's OIDC token; neither has `contents: write`); `tag` and `publish` are each under an exact `if:`
(a push to `main`, not a fork, and a commit the plan released). The jobs that write run no buck2 and use only the checkout
and artifact-download actions; `gamma` runs no buck2 itself, the stage tool does. Every action is pinned by commit, but one: the farm-connect
action is checked out of the repository and commit that two repository variables name, the checkout is verified to be that commit before the action
runs, and it is then used from the checkout. Two runs never tag at once (concurrency group `release`, nothing cancelled); two pushes that planned the
same number race for the tag, and the loser fails at `tag` (the tag names the other commit) with nothing created. No job of the workflow carries
`continue-on-error` (or only `false`), and no `run:` line expands a repository variable or event field inline: the values go through `env:`
(`ci/release_check.zig` and `ci/stages_check.zig` refuse both).

## The beta stage

`beta.yml` runs for every pull request from this repository and as the second stage of the release. A hello-world repository per language is made
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
| `mojo` | a Mojo package, built by the pinned mopm 0.0.1 release | ubuntu x86_64 |
| `ubuntu-24.04-arm`, `macos-14` | the same | **planned**: buildrules v0 targets linux-x86_64 only |
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

Planned legs are visible, not missing: the arm and macos jobs are in `beta.yml` with `if:` never true and their reason in the job name, so a run's page
shows them skipped; the Mojo job runs: `beta/mojo/STEPS` no longer carries `planned-until mopm-release`, and `tools/stage plan` reports the leg ready (mopm 0.0.1, the
published release, is pinned in `rules/mopm/pins.bzl`).
The farm leg, when `FARM_ADDRESS` or `FARM_CONNECT_REF` is empty, is skipped and the `tools` job says so with a notice.

`beta/` is not part of this repository's Buck2 graph and is not built by `//ci:all` (`ci/all.bzl`, `OUTSIDE_THE_GRAPH`, says why): a user's `BUCK` file
is kept as `BUCK.beta`, so that the directories are not packages here. `//beta:beta_check` holds it to that. A fork's pull request has no commit the
cell can be fetched at, so no beta job runs for it.

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
| `RELEASE_BOT_APP_ID` | the App id of the release bot whose token the `tag` job makes the tag with (with the secret `RELEASE_BOT_PRIVATE_KEY`, an environment secret of `release`; see "The tag ruleset"); not the farm's, and read by `tag` and `bump` |
| `BUMP_REPOSITORY` | the name, without its owner, of the internal repository whose `buildrules` submodule the `bump` job moves to each release (see "The submodule bump"); read by `bump` alone |

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

- a release build passes the planned version, `-c buildrules.release_version=<MAJOR.MINOR.PATCH>` (the `cli` job does; nothing else sets it), and the program prints that number;
- any other build (a checkout, your own farm) prints `<MAJOR.MINOR>-dev` of the `VERSION` file, so a program that was not released never claims a release number.

`cli/src/version_test.zig` holds the stamp to that shape against the `VERSION` file, as a test welded to the program. The release holds the other end: `verify` runs the program
the `cli` job built and fails the release unless it prints the release's own number. The program is not a release asset yet; the stamp is checked so that it is right when it becomes one.

### The command-line binaries

`cli/BUCK` builds the program for the four release targets, from one source and the same tests (only zig's `-target` differs; all are built on the Linux execution
platform, as a pure-Zig program needs no SDK to cross-compile):

| release target | target | zig `-target` |
|---|---|---|
| `linux-x86_64` | `//cli:buildrules_linux_x86_64` | `x86_64-linux-musl` |
| `linux-aarch64` | `//cli:buildrules_linux_aarch64` | `aarch64-linux-musl` |
| `macos-arm64` | `//cli:buildrules_macos_arm64` | `aarch64-macos` |
| `macos-x86_64` | `//cli:buildrules_macos_x86_64` | `x86_64-macos` |

Two tests hold each target to its name. An analysis test per target (`zig_exe_target_test`, spelled with the triple again, so a change to one side alone is red) checks the triple the
rule was given; `//cli:header_unit` reads the four built files and requires an ELF of the right machine with no dynamic loader (Linux), or a 64-bit Mach-O executable of the
right cpu (macOS), and that no binary passes as another target's (`tools/release/binhdr.zig`).
A third (`same_tests_as` of the same rule) requires each cross executable to wait for exactly the unit tests of `//cli:buildrules`, and not for none, so a cross binary cannot be built with fewer tests than the program that is tested.

`tools/release` packages them (`binaries.zig`; the five commands below take their inputs by flag and upload nothing). The release workflow does not call them yet: until it does, a
release holds the source archive alone, and `verify` still expects `SHA256SUMS` to be one line.

- `release package --version V --target T --binary PATH --license PATH --out DIR --exec native|none` writes `buildrules-cli-V-T.tar.gz` holding `buildrules-cli-V-T/buildrules` (0755)
  and `LICENSE`, every entry with time 0 and the tool's own gzip, so the same inputs make the same bytes. The name keeps the tarball apart from the source archive
  `buildrules-V.tar.gz`. It refuses a binary whose header is another target's, and one that does not say `buildrules V`: with `--exec native` it runs `--version`; with `--exec none`
  (a binary this machine cannot run) it looks in the file for the version as a string of its own (the version, a NUL right after it, and before it no digit or `.`: `0.0.7` is not found in `0.0.70` or `10.0.7`), a weaker check that a run on the target's own platform must back. (The program prints `buildrules ` and its version as two strings, so `buildrules <V>` is not contiguous in the file.)
- `release record --tarball PATH --out DIR` writes the sha256 of a tarball a user-beta leg ran, and `release tested --dist DIR --tested DIR` refuses unless the tarballs to attest are, byte
  for byte, the ones recorded for `linux-x86_64`, `linux-aarch64` and `macos-arm64` (the Intel macOS binary has no runner), of one version, and nothing else is recorded.
- `release sums --dist DIR` writes `SHA256SUMS` over the source archive and the four tarballs in name order (five lines) and reads it back; it refuses a missing, stray or other-version tarball.
- `release sign --dist DIR [--cosign PATH]` runs keyless `cosign sign-blob` on those five files and `SHA256SUMS`, and refuses a bundle that is missing, empty or already there.

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
- `SHA256SUMS`: one line, the archive's sha256 (`sha256sum --check` reads it).
- The notes: how to pin it, and the commit subjects (no merge commits) since the previous tag.
- A build provenance attestation (GitHub's, signed with the workflow's identity) of the archive and of `SHA256SUMS`.

The archive is reproducible, with one stated dependence. `git archive` writes the tar with a fixed prefix, a fixed modification time, the modes of
umask 022, and `core.autocrlf=false` and `core.eol=lf` (so no setting of the runner converts a line ending); the tool compresses it with its own gzip (a
fixed 10-byte header with no name and no time, one DEFLATE block with a fixed Huffman code over a greedy LZ77 parse), so no `gzip` or zlib of the
runner enters the bytes. The tar bytes themselves are git's: the same tag archived by another git version could differ in the tar, so the archive is
made once, by `archive`, and `verify` builds it a second time from the commit, with the same git on the same runner, and requires the same bytes. A
consumer relies on the published file and its sha256, not on making the file again.

`verify` checks, and `publish` refuses to go on without:

1. the archive's sha256 is the one in `SHA256SUMS`;
2. the checkout is the commit that was tested (no tag exists yet; `publish` later requires the annotated tag to peel to that sha);
3. the attestations of both files verify (`gh attestation verify`), pinned to this workflow, the commit, and `refs/heads/main`;
4. building the archive again from the commit gives the same bytes;
5. the archive's file list equals `git ls-tree -r` of the commit (a missing, extra or repeated file is a failure);
6. the scrub (`tools/scrub`: dates, names, addresses and the like that a public repository must not hold) passes on the archive's contents.
7. (`verify` only) the command line built by `cli` for this release prints the release version: `buildrules --version` is `buildrules <MAJOR.MINOR.PATCH>`, the planned number (see "The version of the command line").

A re-run creates no second release and replaces no asset. If the release exists, each of the two files it already holds must have the sha256
of ours or the job fails and changes nothing; a file it lacks is added. A release is never edited by the pipeline.

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

## The tag ruleset

A ruleset on the repository lets only one GitHub App, the release bot (the repository owner's release bot, installed on this repository), create, update or delete a
`v*` tag; GitHub does not accept the Actions integration as a bypass. So the `tag` job holds `contents: read` from `GITHUB_TOKEN` and mints the bot's
installation token with `actions/create-github-app-token` (pinned by commit), restricted to this repository (`owner: ${{ github.repository_owner }}`, `repositories: buildrules`)
and to `permission-contents: write`, from two things the repository owner creates **before the next release run**:

| name | kind | what |
|---|---|---|
| `RELEASE_BOT_APP_ID` | repository variable | the App id of the release bot |
| `RELEASE_BOT_PRIVATE_KEY` | secret of the environment `release` | the App's private key (PEM); not a repository secret |

The key lives in the environment `release`, restricted to the `main` branch (deployment branches: `main` only), so a workflow run from any other branch cannot read it. The repository-level copy is removed (the owner's held script creates the environment, moves the secret into it and deletes the repository copy). `tag` and `bump`, the only jobs that read `RELEASE_BOT_*`, declare `environment: release`; no other job declares an environment. `ci/release_check.zig` holds this: exactly the jobs that read `RELEASE_BOT_*` declare `environment: release`, any other job with an environment is a finding, a job that reads them without it is a finding, and `ci/workflow_check.zig` refuses an `environment:` in `ci.yml`. Until that script has run, a job that declares `environment: release` still reads the repository-level secret (GitHub creates an empty environment on first use), so the order is: merge the change, then run the script.

Only the `tag` step receives that token (`GH_TOKEN: ${{ steps.bot.outputs.token }}`); `publish` keeps `GITHUB_TOKEN` with `contents: write`, which is enough
because `gh release create --verify-tag` aborts when the tag does not exist and creates no tag (the tool passes it, `tools/release/cmds.zig`). If either name is
missing the token step fails, `tag` is red, **no tag is made and nothing is published**; fix the name and re-run the failed jobs. `ci/release_check.zig` holds
the workflow to all of this: `tag` is the only job that mints the token, with exactly these inputs, the secret is read once and in that job, the token output is
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
`publish` and `tool`, and nothing waits for it; the key is read twice (`tag` and `bump`), each token is minted with exactly its inputs and used by one step;
the repository is the owner's own plus the variable; and the arguments of the bump step are the ones the guard depends on.

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

## When something fails

A red `gate`, `beta`, `gamma`, `archive` or `verify` releases nothing and **leaves no tag**, and the next green push releases everything since the last
tag. If `tag` or a job after it fails, re-run the failed jobs of that run: `tag` keeps a tag that already names the commit (and fails, creating nothing,
when the number names another commit), and `archive`, `verify`, `site` and `publish` are safe to repeat, `publish` adding only what is missing. A `VERSION`
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
