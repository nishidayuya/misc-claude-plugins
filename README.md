# misc-claude-plugins

[![Latest tag](https://img.shields.io/github/v/tag/nishidayuya/misc-claude-plugins)](https://github.com/nishidayuya/misc-claude-plugins/tags)

Miscellaneous [Claude Code](https://claude.com/claude-code) plugins.

## Installation

Register this repository as a marketplace, then install the plugins you want:

```
/plugin marketplace add nishidayuya/misc-claude-plugins
/plugin install save-last-response@misc
```

## Plugins

### save-last-response

A `Stop` hook that writes Claude's final response to `~/.claude/last_response.txt`
every time Claude stops. The file is always overwritten.

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
