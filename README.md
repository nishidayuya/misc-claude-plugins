# misc-claude-plugins

[![Latest tag](https://img.shields.io/github/v/tag/nishidayuya/misc-claude-plugins)](https://github.com/nishidayuya/misc-claude-plugins/tags)

Miscellaneous [Claude Code](https://claude.com/claude-code) plugins.

## Installation

Register this repository as a marketplace, then install the plugins you want:

```
/plugin marketplace add nishidayuya/misc-claude-plugins
/plugin install save-last-response@misc
```

Or install every plugin at once with the `all` bundle:

```
/plugin marketplace add nishidayuya/misc-claude-plugins
/plugin install all@misc
```

## Plugins

### all

A bundle plugin with no components of its own. It only declares every other
plugin of this marketplace as a [dependency][plugin-dependencies], so installing
it installs all of them.

It carries no `version`, which means it tracks the resolved commit of this
repository: a plugin added here reaches everyone who has `all` installed on the
next update, with no release to publish. Auto-update is off by default for
non-Anthropic marketplaces, so pick the new plugins up either by enabling
auto-update for the marketplace in `/plugin`, or with:

```
/plugin update all@misc
/reload-plugins
```

Note that a bundled plugin cannot be disabled on its own while `all` is enabled;
Claude Code refuses and prints a command that disables `all` first. Install the
plugins individually instead of through `all` if you want to toggle them
separately.

[plugin-dependencies]: https://code.claude.com/docs/en/plugin-dependencies

### release-please

Two skills for [googleapis/release-please-action][release-please-action]: one
sets a repository up to release with it, the other takes a merge all the way
through the release it produces.

#### /repo-use-release-please

Sets the repository you are in up to release with the action:

```
/repo-use-release-please [release-type]
```

It looks at the repository, creates a worktree, writes
`.github/workflows/release-please.yml`, `release-please-config.json` and
`.release-please-manifest.json`, checks them, commits, and opens the pull request.
The release type is `simple` unless you name another one; it is never guessed from
what the repository contains, so a `package.json` does not turn it into `node`.

The plugin also carries a `reference.md` the skill reads when it needs it: the
release types and what each rewrites, the config options, `bootstrap-sha` versus
`last-release-sha`, and the token and repository settings the action needs.

[release-please-action]: https://github.com/googleapis/release-please-action

##### No CHANGELOG.md, no version.txt

The generated config is

```json
{
  "packages": {
    ".": {
      "release-type": "simple",
      "skip-changelog": true
    }
  }
}
```

`skip-changelog` drops the `CHANGELOG.md` updater, and the release notes go into
the GitHub release instead. `version.txt` needs no option at all: the `simple`
strategy updates it with `createIfMissing: false`, so a repository without the
file never gets one.

`.release-please-manifest.json` is the one file that has to be committed — its
updater does not create it either, and without it a release pull request would
carry no changes at all. The skill seeds it from the newest `v*` tag, or with
`0.0.0` when there is none, and adds `bootstrap-sha` when that tag has no GitHub
release, because release-please finds the previous release through the releases
API rather than through tags.

##### Notes

The skill is `disable-model-invocation: true`, so Claude never starts it on its
own: it creates a worktree, commits and opens a pull request, which is not
something to trigger from a guess about what you meant.

It reports the one GitHub setting the action needs — *Allow GitHub Actions to
create and approve pull requests* — and prints the `gh` command that fixes it, but
changes nothing without being told to. The repository-wide workflow permissions
are left as they are: the generated workflow asks for its write permissions in its
own `permissions:` block, so a read-only default is fine.

Needs `git`, `gh` and `jq`. Uses `actionlint` on the generated workflow when it is
installed.

#### /merge-and-release-please

Merges a pull request and then follows the merge through to the release:

```
/merge-and-release-please [pull request URL or number]
```

Given a pull request URL or number it uses that one — from another repository
too. Given nothing it works out which pull request the session has been about and
asks you to confirm it before merging anything.

After the merge it watches every workflow the default branch push started. A run
sitting at `action_required` is waiting for approval rather than failing, so it
approves it and keeps watching; a run that fails is re-run at most three times.
Once the branch is green and the repository uses release-please, the release pull
request the workflow just opened goes through the same treatment — its checks are
usually the ones that need approving, because the bot opens it with the default
`GITHUB_TOKEN` — and the branch is watched once more afterwards, down to
`gh release list`.

A failure that survives three re-runs ends the command. It then reports which
job and step failed, whether every attempt failed the same way or the failures
moved around, and what the merged change has to do with it. It does not edit the
code, the tests or the workflows to get past a red run, and it never merges with
`--admin`.

This skill is `disable-model-invocation: true` as well: merging is not something
to start from a guess.

Needs `git` and `gh`.

### save-last-response

A `Stop` hook that writes the whole turn to
`~/.claude/last_responses/<session id>_<nnn>.md` every time Claude stops. Every
turn keeps a file of its own: `<nnn>` is a zero padded 3 digit counter that
starts at `001` for each session, so nothing is overwritten and concurrent
sessions stay out of each other's way.

Two relative symlinks point at the newest one:

| Path | Points at |
| --- | --- |
| `~/.claude/last_responses/<session id>.md` | the newest turn of that session |
| `~/.claude/last_responses/last.md` | the `<session id>.md` of the session that stopped most recently |

The separator is `_` rather than `-` so that `<session id>.md` sorts ahead of
the turns it points into (`.` comes before `_`). A session that stops more than
999 times grows a digit (`_1000.md`); the symlinks follow it either way.

The file starts with the prompt that began the turn, as a level 3 heading:

```markdown
### Which Web UI should we build on?

…(the final response text)…

✻ Cooked for 4m 17s
```

The turn duration line shown in the UI is appended at the end. Markdown headings
in the response are pushed down two levels (`##` becomes `####`), clamped at
level 6; the prompt heading is always level 3 and is never shifted. Fenced code
blocks are tracked, so shell comments inside them are never mistaken for
headings.

A prompt of several lines keeps only its first line in the heading, so a `---`
is written after it to separate it from the response:

```markdown
### first line
second line
third line

---

…(the final response text)…
```

A slash command reaches the transcript as an XML envelope rather than as what was
typed, so it is put back together as `### /code-review high`.

#### AskUserQuestion

Every `AskUserQuestion` of the turn goes between the prompt and the response, with
the answer that came back and a `---` after it:

```markdown
### Add a script that renames the files

**Which language should we implement it in?**

- Python: already on every machine here, and `pathlib` covers the whole job
- Ruby: the repository already carries a Gemfile and a Rakefile
- TypeScript: shares the tooling the front end already uses

→ Ruby

---

…(the final response text)…
```

A call that asked several questions lists them all, then their answers in the
same order. A note typed next to an answer follows it after an em dash, and a
question that was never answered reads `→ (unanswered)`.

#### Configuration

Both are read from the environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `LAST_RESPONSE_VERB` | `Cooked` | The word in the duration line. Set to an empty string to drop the line entirely. |
| `LAST_RESPONSE_HEADING_SHIFT` | `2` | How many levels the headings of the response are pushed down. `0` keeps the response as-is. |

#### Notes

The spinner verb the UI picks (`Churned`, `Cooked`, …) is chosen at render time
and never recorded in the transcript, so it cannot be reproduced. `Cooked` is
used unless `LAST_RESPONSE_VERB` says otherwise.

The hook starts before Claude Code has flushed the final response to the
transcript, so it polls until the last assistant entry carries a text block
(up to ~5s). Reading immediately would capture the *previous* response. Because
of that wait the hook runs with `"async": true`, which keeps it from delaying the
end of a turn.

### worktree-prefix

`claude -w`, the `EnterWorktree` tool and worktree-isolated agents all put their
new worktree on a branch called `worktree-<name>`, with no way to configure that
prefix. This plugin makes it configurable:

```
git config --global miscClaudePlugins.worktreePrefix wt/
```

The worktree directory itself stays at `<repo>/.claude/worktrees/<name>`; only
the branch name changes. A `/` in a worktree name becomes `+` in both the
directory and the branch, exactly as Claude Code does it, so a prefix is the only
way to get worktree branches into a namespace of their own.

#### Configuration

Both are read with `git config`, so they can be set per repository or globally:

| Config | Default | Meaning |
| --- | --- | --- |
| `miscClaudePlugins.worktreePrefix` | `worktree-` | Prepended to the worktree name verbatim, so the separator is up to you. Set to an empty string to name the branch after the worktree alone. |
| `miscClaudePlugins.worktreeBaseRef` | `auto` | `auto` branches off `origin/<default branch>`, fetched first, like Claude Code's own `worktree.baseRef: fresh` default. `head` branches off the local `HEAD`. Anything else is used as a ref as-is. |

An invalid prefix (one that would make `<prefix><name>` an invalid branch name)
aborts worktree creation with an error rather than silently falling back.

#### How it is wired

Claude Code creates the worktree of a `claude -w` launch *before* it registers
plugin hooks — measured on 2.1.228, about 20ms before `Loading hooks from plugin`
appears in the debug log, for marketplace and `--plugin-dir` plugins alike. A
`WorktreeCreate` hook shipped in this plugin's `hooks.json` would therefore never
fire for the case this plugin exists for. Hooks configured in a settings file are
read early enough, so the plugin ships a `SessionStart` hook that writes the two
entries into `~/.claude/settings.json` (or `$CLAUDE_CONFIG_DIR/settings.json`):

```json
{
  "hooks": {
    "WorktreeCreate": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"/home/you/.claude/plugins/marketplaces/misc/plugins/worktree-prefix/hooks/worktree-create.sh\"",
            "statusMessage": "Creating the worktree"
          }
        ]
      }
    ],
    "WorktreeRemove": [ "…the same for hooks/worktree-remove.sh…" ]
  }
}
```

It writes only entries of its own, leaves other hooks in the file alone, and
repoints the commands whenever they no longer match the current plugin root, so a
plugin update heals itself on the next session. Nothing is written unless
`enabledPlugins` names `worktree-prefix` (or the `all` bundle) somewhere, which
keeps `--plugin-dir` development sessions out of the user's settings.

The *user* settings file is used rather than a project one on purpose:
`WorktreeCreate` is honoured from a project's `.claude/settings.json`, but
`WorktreeRemove` is not, which would remove worktrees and leave their branches
behind. As a consequence the hooks apply to every repository of that user, not
only to the one the plugin was enabled from — for a repository with no
`miscClaudePlugins.worktreePrefix` set, that reproduces the built-in
`worktree-<name>` naming.

To uninstall, remove the plugin *and* delete those two entries from the settings
file.

#### Notes

Configuring a `WorktreeCreate` hook makes Claude Code hand the whole creation
over to it, so what the built-in path does on top of `git worktree add` is gone:

* the `worktree.sparsePaths` and `worktree.symlinkDirectories` settings;
* worktrees based on a pull request;
* the `git worktree lock` that marks a worktree as belonging to a live session,
  and with it the automatic cleanup of worktrees left behind by dead sessions;
* the branch name in messages like `Created worktree at: … on branch: …`, because
  Claude Code does not record a branch for a hook-created worktree.

Reproduced here instead: the `.claude/worktrees/<name>` location, the
`origin/<default branch>` base with a fetch, `--no-track -B`, resuming a worktree
that is already registered, and deleting the branch together with the worktree.

Needs `jq` and git 2.31 or newer.

## Development

A plugin manifest cannot say "depend on everything", so the dependency list of
the `all` plugin is generated from the marketplace manifest:

```
script/sync-all-plugin-dependencies.sh
```

`script/check-marketplace.sh` verifies that everything lines up: that the
manifests parse, that `plugins/` and the marketplace plugin list hold the same
names, that each marketplace entry points at a directory whose `plugin.json`
declares the same name, and that the `all` dependency list is up to date. CI runs
it on every push and pull request.

To add a plugin, create `plugins/<name>/` and add its marketplace entry, then run
the sync script. Both scripts need `jq`.
