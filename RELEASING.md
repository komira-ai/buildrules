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
| `beta` | calls `beta.yml`: hello-world repositories per language consume the candidate commit as a user would and are built twice (see "The beta stage") | read, `id-token` for its farm leg |
| `gamma` | builds our own repositories with the candidate on the farm; fails the release when the farm is not configured (see "The gamma stage") | read, `id-token` write |
| `tool` | builds `tools/release` and `tools/stage` with buck2 and hands the binaries to the later jobs, before any job that writes holds a token | read |
| `tag` | decides whether this commit is released, takes the next version and creates the annotated tag. Fails if the tag exists | `contents: write` |
| `archive` | `git archive` of the tag, compressed by the tool's own gzip, `SHA256SUMS`, and a build provenance attestation of both files | `id-token`, `attestations` write |
| `verify` | read-only; checks everything below before a file is published | read |
| `site` | read-only; the page of the release (the pin snippet) as an artifact; nothing deploys it | read |
| `publish` | creates the GitHub release from the verified files | `contents: write` |

The order is `publish` after `verify` after `archive` after `tag` after `gamma` after `beta` after `gate`; a job runs only if the one before it
succeeded (`tag` waits for each of `gate`, `beta` and `gamma`, so none can be dropped by editing another). A write scope
exists only in `tag` and `publish` (`contents`), in `archive` (`id-token`, `attestations`), and `id-token` also in `gamma` and in the call of `beta`
(the farm's network trusts the job's OIDC token; neither has `contents: write`), each of `tag` and `publish` under an exact `if:`
(a push to `main`, not a fork, and for `publish` a commit the tag job released). The jobs that write run no buck2 and use only the checkout
and artifact-download actions; `gamma` runs no buck2 itself, the stage tool does. Every action is pinned by commit, but one: the farm-connect
action is checked out of the repository and commit that two repository variables name, the checkout is verified to be that commit before the action
runs, and it is then used from the checkout. Two runs never tag at once (concurrency group `release`, nothing cancelled).

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
| `mojo` | a Mojo package | **planned** until mopm's first release |
| `ubuntu-24.04-arm`, `macos-14` | the same | **planned**: buildrules v0 targets linux-x86_64 only |
| farm | the ubuntu legs again, built on the farm | only when the repository variables `FARM_ADDRESS` and `FARM_CONNECT_REF` are set |

The runner legs run every action on the runner (`-c buildrules_re.mode=local`; nothing is built anywhere else), and each is built **twice**: after the
first build the tool records the sha256 of every output (a file's bytes, or a directory's names and bytes), runs `buck2 clean`, builds again, and compares.
Any difference is red, with both digests. The check is of one environment against itself: the C and C++ outputs built on a GitHub runner and on the farm are not the same bytes as each other (the other languages are), each is the same across its own two builds, and a farm leg does not compare with a runner leg.
A farm leg does not repeat the build, since the farm's cache would answer it; it requires every build to report `local: 0`.

Planned legs are visible, not missing: the arm and macos jobs are in `beta.yml` with `if:` never true and their reason in the job name, so a run's page
shows them skipped; the Mojo job runs when `tools/stage plan` finds that `rules/mopm/pins.bzl` no longer marks the pinned mopm `release_pending`, and
until then it is skipped. The Mojo steps have not been run end to end yet; that is the first thing to watch when mopm's first release is pinned.
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

No endpoint or property set is written in this repository, and the farm's values are passed to steps as `${{ vars.X != '' }}` or read from the file the
farm-connect action writes, so none is printed in a log by this repository's workflows. `FARM_ADDRESS` and `FARM_CONNECT_REF` together turn on the beta farm leg (it is skipped, with a notice, when either is empty; gamma fails instead).

## The release page

For every release the `site` job writes `site/releases/<tag>/index.html` from the verified `SHA256SUMS`: the tag, the commit to pin in `.buckconfig`
(the `[external_cell_buildrules]` lines), the archive's URL and its sha256, and the commands that check them. It is uploaded as the artifact
`release-site` of the run. Nothing deploys it: the deploy of the site stays a held step.

## The version

A version is `v<MAJOR>.<MINOR>.<PATCH>`.

- `MAJOR.MINOR` is the file `VERSION` (`0.0` today), changed by a normal pull request.
- `PATCH` is the highest existing `v<MAJOR>.<MINOR>.N` plus one, and 1 when there is none. The first automatic release is `v0.0.1`; then `v0.0.2`.
  Other tags (`v1`, `v0.0.1-rc1`, `latest`) are not releases and are ignored.

To bump `MAJOR.MINOR`, edit `VERSION` (`0.1`, `1.0`) in a pull request. `VERSION` is not documentation, so merging it releases: the first
release of the new line is `v0.1.1`, and `PATCH` counts again from 1. A `VERSION` lower than a tag that exists is refused (the tag job fails
and says so) rather than released.

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

- `buildrules-<version>.tar.gz`: the tracked files of the tag under `buildrules-<version>/`, e.g. `buildrules-0.0.1/`.
- `SHA256SUMS`: one line, the archive's sha256 (`sha256sum --check` reads it).
- The notes: how to pin it, and the commit subjects (no merge commits) since the previous tag.
- A build provenance attestation (GitHub's, signed with the workflow's identity) of the archive and of `SHA256SUMS`.

The archive is reproducible, with one stated dependence. `git archive` writes the tar with a fixed prefix, a fixed modification time, the modes of
umask 022, and `core.autocrlf=false` and `core.eol=lf` (so no setting of the runner converts a line ending); the tool compresses it with its own gzip (a
fixed 10-byte header with no name and no time, one DEFLATE block with a fixed Huffman code over a greedy LZ77 parse), so no `gzip` or zlib of the
runner enters the bytes. The tar bytes themselves are git's: the same tag archived by another git version could differ in the tar, so the archive is
made once, by `archive`, and `verify` builds it a second time from the tag, with the same git on the same runner, and requires the same bytes. A
consumer relies on the published file and its sha256, not on making the file again.

`verify` checks, and `publish` refuses to go on without:

1. the archive's sha256 is the one in `SHA256SUMS`;
2. the tag is an annotated tag of the commit that was tested;
3. the attestations of both files verify (`gh attestation verify`), pinned to this workflow, the commit, and `refs/heads/main`;
4. building the archive again from the tag gives the same bytes;
5. the archive's file list equals `git ls-tree -r` of the tag (a missing, extra or repeated file is a failure);
6. the scrub (`tools/scrub`: dates, names, addresses and the like that a public repository must not hold) passes on the archive's contents.

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

## When something fails

A red `gate`, `beta` or `gamma` releases nothing, and the next green push releases everything since the last tag. If a job after `tag` fails, the tag
exists without its release: re-run the failed jobs of that run (`archive`, `verify`, `site` and `publish` are safe to repeat, and `publish` adds only
what is missing). The tag job never creates a tag that exists; a `VERSION` behind the tags fails it until `VERSION` is fixed.

**An old run is never published after a newer one.** Before `publish` creates a release it lists the releases and refuses (the job fails and creates
nothing) when one with a higher number exists, and the release it creates is marked the latest. So re-running the failed jobs of an old run after a newer
release is a red run and not a release below the newest; adding a missing file to a release that exists is still allowed. A tag that has no release does
**not** block the next tag: the tag job takes the highest tag plus one whether or not that tag was ever published, so one failed publish cannot stop
every later push. Such a tag stays without a release (its archive was never published); the next release's notes list the commits since it.

## Before the first release: rehearse (a step for the repository owner, proposed)

The first real run makes a real tag and a public release, neither of which can be taken back. Before it, run the whole pipeline once in a throwaway
test repository: a copy of this repository with its own tag namespace, the repository variables above set (or the farm stages deliberately failing, to
see their message), and a push to its `main`. Check that `beta` is green on the runners and that the farm-less `gamma` fails with the variable list; set the
variables and check that it passes; check the tag, the release, the attestations (`gh attestation verify`), the `site` artifact and a re-run of the whole
run, which must change nothing. Then delete the test repository. Nothing in this repository creates it: it is a step for the repository owner, who owns the account it
would live in.
