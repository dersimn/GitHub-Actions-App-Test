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
publishes a GitHub Release. Configuration lives in [.releaserc.yaml](.releaserc.yaml).

Version bump is driven by commit prefixes:

| Commit prefix              | Release |
| -------------------------- | ------- |
| `fix:`                     | patch → `3.2.1` |
| `chore(deps):` (Dependabot uses this) | patch → `3.2.1`, via a custom `releaseRule` |
| `feat:`                    | minor → `3.3.0` |
| `feat!:` / `BREAKING CHANGE:` | major → `4.0.0` |

> Note: plain `chore:` triggers **no** release under semantic-release's default
> rules. Only the `chore(deps)` scope is mapped to a patch (see
> [.releaserc.yaml](.releaserc.yaml)), so hand-written chores stay release-free
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

## Cross-workflow triggering (the automatic chain has a catch)

The diagram at the top shows each stage kicking off the next. Two of those
handoffs — **auto-merge → release** and **release → docker-publish** — depend on
one workflow's action triggering the next workflow. **Out of the box, they
won't fire.**

GitHub blocks this on purpose:

> events triggered by the `GITHUB_TOKEN`, with the exception of
> `workflow_dispatch` and `repository_dispatch`, will not create a new workflow
> run
> — [GitHub docs](https://docs.github.com/en/actions/security-for-github-actions/security-guides/automatic-token-authentication#using-the-github_token-in-a-workflow)

It's a guard against workflows recursively spawning each other. The fallout in
this repo:

- The Dependabot merge in [pr.yml](.github/workflows/pr.yml) pushes to `master`
  as `github-actions[bot]` → **release.yml does not run.**
- The GitHub Release in [release.yml](.github/workflows/release.yml) is created
  as `github-actions[bot]` → **docker-publish.yml does not run.**

For a demo, you can just perform the later step by hand (merge the PR yourself,
or publish the release / push a `vX.Y.Z` tag manually). To make the chain fully
automatic, the triggering events must originate from an identity that **isn't**
the automatic token. Two options — pick one:

Both workflows already contain the wiring, commented out. Search for
**`APP TOKEN`** in [pr.yml](.github/workflows/pr.yml) and
[release.yml](.github/workflows/release.yml) to enable the GitHub App path.

### Option A — GitHub App token (recommended)

A GitHub App is its own identity (`your-app[bot]`), distinct from
`github-actions[bot]`, so events it creates *do* trigger downstream workflows.
It hands out short-lived (~1 h) tokens, so there's no long-lived credential to
leak or rotate on a schedule.

1. **Create the App** — Settings → Developer settings → **GitHub Apps** → *New
   GitHub App*. Give it a name (this becomes the `[bot]` author), set any
   Homepage URL, and **uncheck Webhook → Active** (not needed).
2. **Permissions** — under *Repository permissions* grant: **Contents:
   Read and write**, **Issues: Read and write**, **Pull requests: Read and
   write**. (These mirror the `permissions:` blocks in the workflows.)
3. **Create**, then note the **App ID** on the App's General page.
4. **Generate a private key** (same page) — a `.pem` file downloads. Treat it
   like a password.
5. **Install the App** → *Install App* → your account/org → **Only select
   repositories** → this repo.
6. **Store the credentials** (Settings → Secrets and variables → Actions):
   - Variable **`RELEASE_APP_ID`** = the App ID number
   - Secret **`RELEASE_APP_PRIVATE_KEY`** = the full contents of the `.pem`
     file (including the `-----BEGIN…`/`-----END…` lines)
7. **Uncomment the `APP TOKEN` lines** in both workflows.

### Option B — Fine-grained Personal Access Token (quicker, less ideal)

Simpler to set up, but it's tied to a user account and is long-lived (needs
rotation).

1. **Create the PAT** — Settings → Developer settings → **Personal access
   tokens → Fine-grained tokens** → *Generate new token*.
2. **Resource owner** = you/your org, **Repository access** = *Only select
   repositories* → this repo.
3. **Repository permissions**: **Contents: Read and write**, **Issues: Read and
   write**, **Pull requests: Read and write**. Set an expiry and put a reminder
   to rotate it.
4. **Store it** as a secret, e.g. **`RELEASE_TOKEN`**.
5. Use it in place of `GITHUB_TOKEN` — same spots the `APP TOKEN` comments mark,
   substituting `${{ secrets.RELEASE_TOKEN }}` for
   `${{ steps.app-token.outputs.token }}`.

## Notes & gotchas

- **Conventional Commits are required** for semantic-release to cut versions.
  The Dependabot config uses the `fix` prefix so image bumps ship as patch
  releases.
- **The chain isn't automatic by default:** the `GITHUB_TOKEN` cannot trigger
  downstream workflows, so auto-merge → release and release → docker-publish
  need a GitHub App token or PAT. See
  [Cross-workflow triggering](#cross-workflow-triggering-the-automatic-chain-has-a-catch)
  above.
- **`GITHUB_TOKEN` and protected branches:** the default token cannot push to a
  branch protected against direct pushes, but semantic-release here only creates
  tags/releases, which the granted `contents: write` permission covers. If your
  release setup needs to push commits (e.g. a changelog) to a protected
  `master`, use a PAT or a GitHub App token instead.
- **First release:** with no prior tags, semantic-release starts at `1.0.0` on
  the first `feat:` (or `1.0.0` per its default). Push an initial `v1.0.0`
  release manually if you want a specific starting point.
