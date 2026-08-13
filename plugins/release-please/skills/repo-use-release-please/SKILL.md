---
name: repo-use-release-please
description: Set the current repository up to release with googleapis/release-please-action. Writes the release-please workflow, release-please-config.json and .release-please-manifest.json, defaulting to release-type `simple` with no CHANGELOG.md and no version.txt, then opens the pull request from a worktree.
argument-hint: "[release-type]"
disable-model-invocation: true
allowed-tools:
  - Bash(cat ${CLAUDE_SKILL_DIR}/reference.md)
  - Bash(git rev-parse:*)
  - Bash(git remote get-url:*)
  - Bash(git symbolic-ref --short:*)
  - Bash(git tag --list:*)
  - Bash(git log --oneline:*)
  - Bash(git status:*)
  - Bash(jq empty:*)
---

Set the current repository up to release with
[googleapis/release-please-action](https://github.com/googleapis/release-please-action).

Release type: `$ARGUMENTS` when an argument was given, otherwise `simple`. Never
infer the release type from what the repository contains — a `package.json` does
not make it `node`.

`${CLAUDE_SKILL_DIR}/reference.md` lists the release types and the config
options. Read it when the release type is not `simple`, or when a step below
points at it. It sits outside the repository, so read it with
`cat ${CLAUDE_SKILL_DIR}/reference.md`, which needs no permission prompt.

## 1. Look at the repository

Run these in the repository the user is in:

* `git rev-parse --show-toplevel` — stop with an explanation if this is not a git
  repository.
* `git remote get-url origin` — the workflow only makes sense for a GitHub
  remote. Report it and ask before continuing if the remote is missing or is not
  GitHub.
* `git symbolic-ref --short refs/remotes/origin/HEAD`, falling back to
  `gh repo view --json defaultBranchRef -q .defaultBranchRef.name` — the branch
  the workflow triggers on.
* `git tag --list 'v*' --sort=-v:refname | head -n 1` — the version the manifest
  is seeded with.
* Whether `release-please-config.json`, `.release-please-manifest.json`,
  `.github/workflows/`, `CHANGELOG.md` or `version.txt` already exist.

If the repository already has a release-please config, manifest or workflow,
report what is there and ask before overwriting anything.

Also glance at `git log --oneline -20`. If the history does not look like
[Conventional Commits](https://www.conventionalcommits.org/), say so — without
them release-please never proposes a release — but carry on.

## 2. Work in a worktree

Use the `EnterWorktree` tool with `name: release-please`. If the session is
already in a worktree, stay where it is and create a branch there instead. If the
tool is unavailable or fails, create the branch in the working copy the user is
in and say that is what happened.

## 3. Write the files

Three files, and only these three. Do not create `version.txt`, and do not
create `CHANGELOG.md`; leave an existing `CHANGELOG.md` alone.

**`.github/workflows/release-please.yml`** — verbatim, with `main` under
`branches:` replaced by the default branch found in step 1:

```yaml
name: release-please

on:
  push:
    branches:
      - main

# contents: create the tag, the GitHub release and the release branch.
# pull-requests: open and update the release pull request.
# issues: manage the `autorelease: *` labels, which go through the issues API.
permissions:
  contents: write
  pull-requests: write
  issues: write

jobs:
  release-please:
    runs-on: ubuntu-latest
    steps:
      - uses: googleapis/release-please-action@v4
        with:
          config-file: release-please-config.json
          manifest-file: .release-please-manifest.json
```

**`release-please-config.json`** — for the default release type:

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "packages": {
    ".": {
      "release-type": "simple",
      "skip-changelog": true
    }
  }
}
```

`skip-changelog` is what keeps `CHANGELOG.md` out of the release pull request;
the release notes go into the GitHub release instead. The `simple` strategy also
updates `version.txt`, but its updater does not create the file, so leaving it
out of the repository is all it takes to not have one.

For a release type other than `simple`, put that release type in and ask whether
to keep `skip-changelog: true` — a language strategy usually also rewrites a
version in a package manifest, which `skip-changelog` does not affect. See
`reference.md`.

**`.release-please-manifest.json`** — seeded with the version from step 1:

```json
{
  ".": "1.2.3"
}
```

Use `0.0.0` when the repository has no version tag. This file has to be
committed: its updater does not create it either, and without it a release pull
request would carry no changes at all.

Then check whether the seeded version has a GitHub release:
`gh release view <tag>`. If it does not, add a top-level `"bootstrap-sha"` to
`release-please-config.json` with the full SHA of that tag
(`git rev-parse '<tag>^{commit}'`), so release-please does not treat the whole
history as unreleased. See `reference.md` for `bootstrap-sha` versus
`last-release-sha`.

## 4. Check

* `jq empty` on both JSON files.
* `actionlint .github/workflows/release-please.yml` when `actionlint` is
  installed.
* `gh api repos/{owner}/{repo}/actions/permissions/workflow` — the workflow needs
  `can_approve_pull_request_reviews: true`, or the action fails with
  `GitHub Actions is not permitted to create or approve pull requests`. Leave
  `default_workflow_permissions` alone: the workflow file asks for the write
  permissions it needs in its own `permissions:` block, so a repository default of
  `read` works and keeps every other workflow on a read-only token.

Report what the setting is and, when it is false, show the command that fixes it —
with `default_workflow_permissions` set to the value the repository already has,
because this `PUT` writes both fields:

```
gh api -X PUT repos/{owner}/{repo}/actions/permissions/workflow \
  -f default_workflow_permissions=read \
  -F can_approve_pull_request_reviews=true
```

Do not run it yourself unless the user says to. An organization policy can pin
this setting, in which case the fix belongs in the organization settings.

## 5. Commit and open the pull request

Commit with a Conventional Commits message, `ci: release with
release-please-action` unless the user wants another one, push the branch, and
open the pull request with `gh pr create`. Title and body in English.

## 6. Report

* the files written and the release type used;
* the pull request URL;
* the GitHub setting from step 4, if it still needs changing;
* that a `ci:` commit is not user-facing, so the first release pull request
  appears only once a `feat:` or `fix:` commit lands on the default branch — and
  that `release-as` or `initial-version` forces a release before that
  (`reference.md`);
* that tags and releases created with the default `GITHUB_TOKEN` do not trigger
  other workflows, which matters if a publish workflow is meant to run on the
  release (`reference.md`).
