# release-please reference

Background for the `repo-use-release-please` skill. Read the section you need
rather than the whole file.

Authoritative sources:

* action inputs: <https://github.com/googleapis/release-please-action#configuration>
* config schema: <https://github.com/googleapis/release-please/blob/main/schemas/config.json>
* strategies and per-strategy behaviour:
  <https://github.com/googleapis/release-please/blob/main/docs/customizing.md>
* manifest mode: <https://github.com/googleapis/release-please/blob/main/docs/manifest-releaser.md>

## Release types

`release-type` picks the strategy, and the strategy decides which files a release
pull request rewrites besides `.release-please-manifest.json`. The frequently
used ones:

| Release type | Rewrites |
| --- | --- |
| `simple` | `version.txt`, and only when it already exists. The default of this skill. |
| `node` | the `version` of `package.json`, plus the lock file when there is one |
| `python` | the version in `pyproject.toml` / `setup.py` / `setup.cfg` / `<package>/__init__.py`, whichever is present |
| `rust` | the `version` of `Cargo.toml`, plus `Cargo.lock` |
| `ruby` | the version constant of the file named by `version-file` |
| `go` | nothing — the tag is the release |
| `terraform-module` | the module versions written in `*.tf` and `README.md` |

Every strategy also writes `CHANGELOG.md` unless `skip-changelog` says
otherwise. The `customizing.md` link above has the complete list; check it before
using a release type that is not in the table.

## Config options worth knowing

All of these go either at the top level of `release-please-config.json`, where
they apply to every package, or inside a `packages` entry, where they apply to
that package only. A `packages` entry wins over the top level.

| Option | What it does |
| --- | --- |
| `skip-changelog` | Leaves `CHANGELOG.md` out entirely. The release notes still go into the GitHub release. |
| `changelog-path` | Somewhere other than `CHANGELOG.md`. |
| `changelog-sections` | Which commit types show up in the notes, and under which heading. |
| `include-v-in-tag` | `true` by default, so tags are `v1.2.3`. Set it to `false` for `1.2.3`. |
| `initial-version` | The version of the first release. Without it the first release of a repository with no version is `1.0.0`. |
| `release-as` | Forces the next release to a version you choose. Remove it once that release is out, or every later release repeats it. |
| `bump-minor-pre-major` | While the version is below `1.0.0`, a breaking change bumps the minor instead of the major. |
| `extra-files` | Extra files with a version to rewrite, either annotated with release-please comments or addressed with `jsonpath` / `xpath`. |
| `versioning` | `default` derives the bump from the commits; `always-bump-patch` and friends override that. |
| `separate-pull-requests` | One release pull request per package instead of one shared one. Monorepo only. |
| `draft` / `prerelease` | Creates the GitHub release as a draft or a prerelease. |

## `bootstrap-sha` and `last-release-sha`

Both are top level only, both take a full SHA, and both bound how far back
release-please looks for commits.

* `bootstrap-sha` is for a repository being set up: pick a commit *older* than
  the first entry you want in the release notes. It is ignored from the moment
  the first release pull request is merged, so it can be left in the file.
* `last-release-sha` is for repairing a mistake — a bad release pull request that
  was merged, for instance. It is never ignored, so remove it once the next
  correct release is out.

The skill adds `bootstrap-sha` when the version seeded into
`.release-please-manifest.json` has no GitHub release, because release-please
finds the previous release through the GitHub releases API, not through tags. A
repository whose tags were pushed by hand has tags but no releases, and without
`bootstrap-sha` the first release notes would list the entire history.

## Getting the first release out

A release pull request appears only when there is at least one user-facing commit
since the last release — a `feat:`, a `fix:`, or anything in
`changelog-sections`. `ci:`, `chore:`, `docs:`, `style:`, `test:` and friends do
not count, so the setup commit alone leaves nothing to release.

To release without waiting for such a commit, set `release-as` to the version you
want, let the release pull request open, and delete `release-as` afterwards.

## The token, and workflows that should run on a release

Anything the default `GITHUB_TOKEN` pushes — the release branch, the tag, the
release — does not trigger another workflow run. That is a GitHub rule against
recursive workflows, not a release-please limitation.

It matters in two places:

* a `on: release` or `on: push: tags:` publish workflow never fires;
* a required CI check never runs on the release pull request, so the pull request
  cannot be merged if that check is required.

Both are fixed by giving the action a token that is not `GITHUB_TOKEN`: a
fine-grained PAT with `contents: write` and `pull-requests: write` on the
repository, or a GitHub App installation token, passed as the `token` input.

## Repository settings the action needs

`gh api repos/{owner}/{repo}/actions/permissions/workflow` shows both:

* `default_workflow_permissions` — `read` blocks the tag and the release. The
  workflow file asks for `contents: write` explicitly, which is enough as long as
  the repository does not force read-only; otherwise switch this to `write`.
* `can_approve_pull_request_reviews` — when this is false the action fails with
  `GitHub Actions is not permitted to create or approve pull requests`. This is
  the setting labelled *Allow GitHub Actions to create and approve pull requests*
  under Settings → Actions → General.

An organization can pin both, in which case they have to be changed in the
organization settings.

## Labels

release-please tracks state with the labels `autorelease: pending`,
`autorelease: tagged` and `autorelease: published`, which it manages through the
issues API — hence `issues: write` in the workflow. Dropping that permission
means passing `skip-labeling: true` to the action, and losing the state tracking
that goes with the labels.

## Monorepos

Give `packages` one entry per releasable directory:

```json
{
  "packages": {
    "packages/a": { "release-type": "node" },
    "packages/b": { "release-type": "node" }
  }
}
```

Add `"include-component-in-tag": true` so the tags become
`<component>-v1.2.3` instead of colliding on `v1.2.3`, and seed
`.release-please-manifest.json` with one entry per path. `separate-pull-requests`
decides whether each package gets its own release pull request.
