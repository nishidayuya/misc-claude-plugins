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

### save-last-response

A `Stop` hook that writes Claude's final response to
`~/.claude/last_responses/<session id>.txt` every time Claude stops. Each session
gets its own file, always overwritten, so concurrent sessions no longer clobber
each other. `~/.claude/last_responses/last.txt` is a relative symlink to the file
just written, i.e. to the session that stopped most recently.

The turn duration line shown in the UI is appended:

```
…(the final response text)…

✻ Cooked for 4m 17s
```

Markdown headings in the response are pushed down two levels (`##` becomes
`####`), clamped at level 6. Fenced code blocks are tracked, so shell comments
inside them are never mistaken for headings.

#### Configuration

Both are read from the environment:

| Variable | Default | Meaning |
| --- | --- | --- |
| `LAST_RESPONSE_VERB` | `Cooked` | The word in the duration line. Set to an empty string to drop the line entirely. |
| `LAST_RESPONSE_HEADING_SHIFT` | `2` | How many levels headings are pushed down. `0` keeps the response as-is. |

#### Notes

The spinner verb the UI picks (`Churned`, `Cooked`, …) is chosen at render time
and never recorded in the transcript, so it cannot be reproduced. `Cooked` is
used unless `LAST_RESPONSE_VERB` says otherwise.

The hook starts before Claude Code has flushed the final response to the
transcript, so it polls until the last assistant entry carries a text block
(up to ~5s). Reading immediately would capture the *previous* response. Because
of that wait the hook runs with `"async": true`, which keeps it from delaying the
end of a turn.

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
