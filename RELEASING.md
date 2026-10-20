# Releasing buildrules

A release is automatic. Every push to `main` is tested in stages, and a green one that changes more than documentation or CI is released with
no human action: a tag, and a GitHub release carrying a source archive, its `SHA256SUMS` and the notes. A consumer pins the tag and the archive's
sha256 (or the tag's commit). There are no binaries: buildrules is rules, and the command line is built from this source on your farm.

`.github/workflows/release.yml` is the pipeline. `tools/release` (Zig, tested as a build action) does each step; the workflow's `run:` lines are
one invocation each. `ci/release_check.zig` (part of `//ci:workflow`) holds the workflow to what is written here.

## The stages

| job | what it does | token |
|---|---|---|
| `gate` | the PR gate: calls `ci.yml`, the whole tree (`//ci:all`) and the completeness check, in local mode on the runner. Beta (hello-world repos that consume the candidate) and gamma (our own repos on the farm) are to go between `gate` and `tag`; neither exists yet | read |
| `tool` | builds `tools/release` with buck2 and hands the binary to the later jobs, before any job holds a token | read |
| `tag` | decides whether this commit is released, takes the next version and creates the annotated tag. Fails if the tag exists | `contents: write` |
| `archive` | `git archive` of the tag, compressed by the tool's own gzip, `SHA256SUMS`, and a build provenance attestation of both files | `id-token`, `attestations` write |
| `verify` | read-only; checks everything below before a file is published | read |
| `publish` | creates the GitHub release from the verified files | `contents: write` |

The order is `publish` after `verify` after `archive` after `tag` after `gate`; a job runs only if the one before it succeeded. A write scope
exists only in `tag` and `publish` (`contents`) and in `archive` (`id-token`, `attestations`), each of `tag` and `publish` under an exact `if:`
(a push to `main`, not a fork, and for `publish` a commit the tag job released). The jobs that write run no buck2 and use only the checkout
and artifact-download actions. Every action is pinned by commit. Two runs never tag at once (concurrency group `release`, nothing cancelled).

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

The archive is deterministic: the same tag gives the same bytes. `git archive` writes the tar with a fixed prefix, a fixed modification time
and the modes of umask 022, and the tool compresses it with its own gzip (a fixed 10-byte header with no name and no time, one DEFLATE block
with a fixed Huffman code over a greedy LZ77 parse), so no `gzip`, zlib or git version of the runner enters the bytes. The `verify` job builds
the archive a second time from the tag and requires the same bytes.

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

A red `gate` releases nothing, and the next green push releases everything since the last tag. If a job after `tag` fails, the tag exists
without its release: re-run the failed jobs of that run (`archive`, `verify` and `publish` are safe to repeat, and `publish` adds only what is
missing). The tag job never creates a tag that exists; a `VERSION` behind the tags fails it until `VERSION` is fixed.
