---
name: release
description: Cut a Kuulla production release — pick the CalVer tag, sanity-check what's merged and labeled, run scripts/new-release.sh, watch release.yml and deploy.yml, and verify the live footer SHA. Use when asked to "cut a release", "ship a release", "tag a release", or "do a release".
allowed-tools: [Bash, Read, WebFetch]
last_verified: 2026-09-05
---

# Cut a Kuulla release

Authoritative reference: [docs/release-runbook.md](../../../docs/release-runbook.md). Deployment
shape: [docs/deployment-runbook.md](../../../docs/deployment-runbook.md). Milestone
[#37](https://github.com/two4suited/kuulla/milestone/37).

Read the release runbook before starting — this skill is the checklist, the runbook is the
explanation. If they disagree, the runbook wins; fix this file.

## The model (why the steps are what they are)

`main` is a staging line. Merging to `main` does **not** deploy. A release is an explicit act:
push a CalVer tag `vYYYY.M.N` at a chosen `main` commit. That tag push triggers `release.yml`
(GitHub Release + generated notes) and `deploy.yml` (`aspire deploy` to production) in parallel.

Tag scheme: `v<UTC year>.<UTC month, no leading zero>.<zero-based counter within that month>`.
`scripts/new-release.sh` computes the next `N` itself — don't hand-pick it.

## Steps

1. **Confirm scope.** Ask the user which `main` commit to release (default: current `origin/main`
   tip). List merged PRs since the last tag so they can confirm that's the intended set:

   ```sh
   git fetch origin main --tags
   PREV=$(git tag -l 'v*' --sort=-v:refname | head -1)
   git log --oneline --no-decorate "$PREV..origin/main"
   ```

2. **Check labels.** Release notes group PRs by label (see the runbook's table). Path labels
   (`ios`, `web`, `api`, `infra`, `documentation`, …) are auto-applied by
   [labeler.yml](../../../.github/workflows/labeler.yml). **`feature` vs `bug` is not
   path-derivable** — for each PR in the range where it matters for the notes, check it has one
   applied. Labels must already be on the PR (they're read at merge time); a missing label can't
   be fixed retroactively for notes, so just flag it to the user.

   ```sh
   gh pr list --state merged --base main --limit 30 \
     --json number,title,labels,mergedAt \
     --jq '.[] | "\(.number)\t\(.title)\t\([.labels[].name] | join(","))"'
   ```

3. **Dry run the tag script** from a clean `main` checkout:

   ```sh
   git checkout main && git pull
   scripts/new-release.sh --dry-run
   ```

   It fetches tags, computes the next tag, and prints the commit range. It **refuses** unless
   `HEAD == origin/main` and the tree is clean.

4. **Cut the tag.** `scripts/new-release.sh` is interactive (`y/N` prompt) and pushes the
   annotated tag to `origin`. The user runs this — it's the irreversible step. Don't pipe `yes`
   into it.

   ```sh
   scripts/new-release.sh
   ```

5. **Watch both workflows.** They run in parallel with no ordering dependency. `deploy.yml`
   waits on the `production` environment's required-reviewer gate — tell the user they need to
   approve it in the GitHub UI.

   ```sh
   gh run list --workflow=release.yml --limit 3
   gh run list --workflow=deploy.yml --limit 3
   ```

6. **Verify the deploy actually took traffic.** A green `deploy.yml` does **not** prove the new
   ACA revision is serving (gotcha #404 / "ACA revision not promoted"). Load the production site
   and confirm the footer version matches the tag just pushed (`2026.9.0+<sha>`, not
   `dev+<sha>`).

7. **Confirm the GitHub Release exists** with grouped notes:

   ```sh
   gh release view "$(git tag -l 'v*' --sort=-v:refname | head -1)"
   ```

8. **Summarize the release for the marketing page.** Once `release.yml`'s "Update CHANGELOG.md"
   commit has landed on `main`, generate the plain-language blurb the `/welcome` "What's new"
   list leads with (see the runbook's [Summaries](../../../docs/release-runbook.md#summaries)).
   Not in CI — run it by hand and commit:

   ```sh
   git checkout main && git pull
   scripts/summarize-releases.sh
   git add release-summaries.json && git commit -m "Summarize <tag> for the marketing page" && git push
   ```

   It only calls the model for releases with no blurb yet; a clean "0 updated" means nothing to
   commit. The new blurb shows on the site with the next release's deploy.

## Hotfixes

Default: roll forward. A hotfix is an ordinary PR to `main` + a new release tag with the next
`N`. No release branch, no cherry-picking. Only branch from the released tag if `main` has
already moved on with changes that must not ship yet (see the runbook's Hotfixes section), then
merge back to `main`.

## Rollback / re-deploy

Redeploy an older tag via GitHub → Actions → **Deploy to Azure** → **Run workflow**, tag
selector set to the target tag. This creates no new tag or Release. If the rolled-back state
should be the baseline, cut a fresh tag from the matching `main` commit.

## Don't

- Don't push the tag yourself non-interactively — let the user answer the script's prompt.
- Don't manually `dotnet build` / `dotnet test` first; CI and `aspire deploy` do that.
- Don't trust green CI as proof of a live deploy — check the footer SHA (step 6).
- Don't hand-pick `N` — the script derives it from existing tags.
