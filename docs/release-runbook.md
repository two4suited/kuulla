# Release runbook

How Kuulla ships to production. The flow spans a helper script and three workflows
([release.yml](../.github/workflows/release.yml), [deploy.yml](../.github/workflows/deploy.yml),
and label wiring in [.github/release.yml](../.github/release.yml)); this page is the authoritative
description of how they fit together. For the operational shape of the Azure Container Apps
deployment itself, see the [deployment runbook](deployment-runbook.md).

Milestone: [#37 "Release versioning & notes"](https://github.com/two4suited/kuulla/milestone/37).

## The model

`main` is a staging line. Merging a PR to `main` **does not deploy** — it only makes the change
eligible for the next release. A release is an explicit, versioned act: you push a CalVer tag at
a chosen `main` commit, and that tag push is what publishes release notes and deploys.

## Version scheme

Releases are tagged `vYYYY.M.N`:

- `YYYY` — UTC year.
- `M` — UTC month, **no leading zero** (`9`, not `09`; `12` stays `12`).
- `N` — zero-based counter of releases within that calendar month. Resets to `0` at the start of
  each month.

Examples: first release in September 2026 is `v2026.9.0`, the next is `v2026.9.1`, the first in
October is `v2026.10.0`. The first release ever is `v2026.9.0`.

The tag is the source of truth for the version. On a tag build, CI strips the leading `v` and
embeds `YYYY.M.N` into the web app's assembly version, so the running app reports the release it
came from (see [BuildInfo.cs](../src/Kuulla.Web/BuildInfo.cs) and
[Kuulla.Web.csproj](../src/Kuulla.Web/Kuulla.Web.csproj)). Non-release builds (local, `main`, PRs)
report `dev+<sha>`.

iOS App Store versioning is tracked separately in milestone #34 and is not affected by these tags.

## Cutting a release

1. Make sure everything you want in the release is merged to `main` and that open PRs are
   labeled (see [Release notes](#release-notes) — labels must be on the PR **before** it merges).
2. From a clean checkout of `main` at the commit you want to release:

   ```sh
   git checkout main && git pull
   scripts/new-release.sh
   ```

   The script:
   - Fetches tags, finds the highest `vYYYY.M.*` for the current UTC month, and computes the next
     tag (`N+1`, or `0` if this is the first release of the month).
   - **Refuses to run** unless `HEAD` is exactly at `origin/main` and the working tree is clean.
     Releases are cut from `main` only.
   - Prints the new tag and the commit range since the previous tag, then asks for confirmation.
   - On `y`, creates an annotated tag and pushes it to `origin`.

   Use `scripts/new-release.sh --dry-run` to see the tag and commit range without tagging.

3. The tag push triggers two workflows **in parallel**, with no ordering dependency between them:
   - **[release.yml](../.github/workflows/release.yml)** — checks out the tag with full history
     and runs `gh release create <tag> --verify-tag --generate-notes`, publishing a GitHub
     Release.
   - **[deploy.yml](../.github/workflows/deploy.yml)** — checks out the tagged commit and runs
     `aspire deploy` against the `production` environment. This waits on the `production`
     environment's required-reviewer gate before it provisions anything.

   A deploy landing a minute or two before its GitHub Release appears is expected and fine. A
   failed release-notes run does not block the deploy, and vice versa.

4. **Verify the deploy took traffic.** A green `deploy.yml` run does *not* prove the new ACA
   revision is serving — see the "ACA revision not promoted" gotcha (#404). Load the site and
   confirm the footer version matches the tag you just pushed (`2026.9.0+<sha>`).

## Release notes

`--generate-notes` diffs the previous release tag to the new one and lists every merged PR in
that range. [.github/release.yml](../.github/release.yml) groups those PRs by label:

| Section | Labels |
| --- | --- |
| Features | `enhancement`, `feature` |
| Fixes | `bug`, `fix` |
| iOS | `ios` |
| Web | `web` |
| Infra / Deploy | `infra`, `ci`, `deployment` |
| Docs | `documentation` |
| Accessibility | `accessibility` |
| Other | everything else |

PRs labeled `dependencies` / `duplicate` / `invalid` / `wontfix` / `question`, and anything
authored by Dependabot, are excluded from the notes.

Path-based labels (`ios`, `web`, `api`, `infra`, `documentation`, …) are applied automatically by
[the labeler workflow](../.github/workflows/labeler.yml) from the PR's changed files. **`feature`
vs `bug` is not path-derivable** — apply one of those by hand on the PR (before it merges) when it
matters for the notes. A PR with no matching label still ships; it just lands under "Other".

## Hotfixes

**Default: roll forward from `main`.** A hotfix is an ordinary PR to `main` followed by a new
release tag with the next `N`. There is no release branch to maintain and no cherry-picking.

Only branch from the released tag if `main` has already moved on with changes that must not ship
yet: branch from `vYYYY.M.(N-1)`, apply the fix, and tag the branch tip as `vYYYY.M.N`. Both
workflows key off `github.ref`, so a tag on a side branch releases and deploys that branch's
commit correctly. Merge the fix back to `main` afterward. Treat this as the exception — it exists
so an urgent fix isn't held hostage by unrelated unreleased work.

## Rollback / re-deploy

To put an older release back into production, re-run the deploy against its tag:

1. GitHub → Actions → **Deploy to Azure** → **Run workflow**.
2. Set the branch/tag selector to the tag you want (e.g. `v2026.9.0`) and run it.

`deploy.yml`'s checkout resolves `github.ref`, so the dispatched run ships that tag's commit. The
`production` environment gate still applies. Afterward, verify the live footer version as in step
4 of [Cutting a release](#cutting-a-release).

Rolling back does not create a new tag or GitHub Release — it just redeploys existing code. If
the rolled-back state should be the new baseline, cut a fresh tag from the corresponding `main`
commit so the version the app reports matches reality.
