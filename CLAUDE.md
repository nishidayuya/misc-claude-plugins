# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Plugin versions

Every plugin under `plugins/` except `all` carries a `version` in its
`.claude-plugin/plugin.json`. Whenever you change any file under
`plugins/<name>/`, bump that plugin's `version` in the same pull request.

Versions follow [Semantic Versioning](https://semver.org/):

| Part | Bump it for |
| --- | --- |
| MAJOR | A breaking change: a removed or renamed hook, skill or command, a configuration key that no longer works, or behaviour a user has to react to. |
| MINOR | A backwards-compatible feature: a new hook, skill, command or configuration option. |
| PATCH | A backwards-compatible fix: a bug fix, or a wording change in a skill or a message. |

Notes:

* Bump the version once per pull request, not once per commit. Put it in its own
  commit named `chore(<plugin>): bump version to <version>`.
* Only the plugin that changed is bumped. Plugins are versioned independently of
  each other and of the repository.
* A change that touches no file under `plugins/<name>/` — the README, the scripts,
  CI — bumps nothing.

### The `all` plugin

`plugins/all` deliberately carries no `version`, so that it tracks the resolved
commit of this repository and a newly added plugin reaches its users without a
release. Never add a `version` to it, and never bump anything when its
`dependencies` list changes.

Its `dependencies` list is generated; after adding or removing a plugin, run:

```
script/sync-all-plugin-dependencies.sh
```

## Repository version

The repository itself is released by release-please, which owns the git tags and
`.release-please-manifest.json`. Do not edit that file or bump the repository
version by hand; it follows from the Conventional Commits prefixes of the merged
commits.

## Checks

Run before opening a pull request:

```
script/check-marketplace.sh
```
