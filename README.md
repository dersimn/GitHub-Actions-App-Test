# Automated dependency updates → semantic release → Docker Hub

An end-to-end GitHub Actions setup that automates the whole lifecycle of a
container image.

```
Dependabot          PR check (pr.yml)        semantic-release        docker-publish
  opens a PR   ──►   build image, and    ──►  on push to master:  ──► on release published:
  bumping            auto-merge if green      tag + GitHub Release     push to Docker Hub
  alpine:3.12                                                          (latest, 3, 3.2, 3.2.1)
```

## The parts

### 1. Keep the base image current — [.github/dependabot.yml](.github/dependabot.yml)

Dependabot watches the [Dockerfile](Dockerfile) and opens a pull request when a
newer Alpine tag is available, bumping `FROM alpine:3.12` for you.

### 1b. Validate & auto-merge PRs — [.github/workflows/pr.yml](.github/workflows/pr.yml)

Every pull request builds the Docker image (multi-arch, nothing pushed). For
**Dependabot** PRs, a second job runs only `needs:` the build — so it can merge
only when the build passed — and merges the PR automatically (a regular merge
commit). The merge lands on `master`, which kicks off Part 2.

> **Note on merging:** the merge job merges directly (`gh pr merge --merge`).
> This works out of the box with no branch protection. If `master` is protected
> with *required status checks*, a direct merge can race the checks — switch the
> command to `gh pr merge --auto --merge`, enable **Settings → General → Allow
> auto-merge**, and add the `Build image` check to branch protection. If
> protection also requires a review, the bot must `gh pr review --approve` first.
> To auto-merge only patch/minor bumps, gate the merge step on
> `steps.meta.outputs.update-type` from the `dependabot/fetch-metadata` step.

### 2. Tag & release on merge to master — [.github/workflows/release.yml](.github/workflows/release.yml)

Every push to `master` runs [semantic-release](https://semantic-release.gitbook.io/).
It reads the [Conventional Commit](https://www.conventionalcommits.org/) messages
since the last release, decides the next version, creates the git tag, and
publishes a GitHub Release. Configuration lives in [.releaserc.json](.releaserc.json).

Version bump is driven by commit prefixes:

| Commit prefix              | Release |
| -------------------------- | ------- |
| `fix:`                     | patch → `3.2.1` |
| `chore(deps):` (Dependabot uses this) | patch → `3.2.1`, via a custom `releaseRule` |
| `feat:`                    | minor → `3.3.0` |
| `feat!:` / `BREAKING CHANGE:` | major → `4.0.0` |

> Note: plain `chore:` triggers **no** release under semantic-release's default
> rules. Only the `chore(deps)` scope is mapped to a patch (see
> [.releaserc.json](.releaserc.json)), so hand-written chores stay release-free
> while dependency bumps still ship.

### 3. Build & push Docker images on release — [.github/workflows/docker-publish.yml](.github/workflows/docker-publish.yml)

Publishing a release (or pushing a `vX.Y.Z` tag) builds a multi-arch image and
pushes it to Docker Hub. `docker/metadata-action` expands the semver tag into
the conventional Docker tags:

```
v3.2.1  →  yourrepo:latest, yourrepo:3, yourrepo:3.2, yourrepo:3.2.1
```

Pre-releases like `v3.2.1-rc.1` are pushed under that exact tag only and are not
marked `latest`.

## Required repository configuration

**Secrets** (Settings → Secrets and variables → Actions → *Secrets*):

| Name                 | Value |
| -------------------- | ----- |
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN`    | A Docker Hub [access token](https://hub.docker.com/settings/security) |

`GITHUB_TOKEN` is provided automatically — no setup needed.

**Variables** (Settings → Secrets and variables → Actions → *Variables*):

| Name                   | Value |
| ---------------------- | ----- |
| `DOCKERHUB_REPOSITORY` | Target repo, e.g. `youruser/yourapp` |

## Notes & gotchas

- **Conventional Commits are required** for semantic-release to cut versions.
  The Dependabot config uses the `fix` prefix so image bumps ship as patch
  releases.
- **`GITHUB_TOKEN` and protected branches:** the default token cannot push to a
  branch protected against direct pushes, but semantic-release here only creates
  tags/releases, which the granted `contents: write` permission covers. If your
  release setup needs to push commits (e.g. a changelog) to a protected
  `master`, use a PAT or a GitHub App token instead.
- **First release:** with no prior tags, semantic-release starts at `1.0.0` on
  the first `feat:` (or `1.0.0` per its default). Push an initial `v1.0.0`
  release manually if you want a specific starting point.
