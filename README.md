# claude-plugins

Personal Claude Code plugin marketplace.

## Installing

```
/plugin marketplace add caseyWebb/claude-plugins
/plugin install pr-description-sync@caseyWebb
/plugin install doc-gate@caseyWebb
```

Or auto-enable in a project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": ["caseyWebb/claude-plugins"],
  "enabledPlugins": ["pr-description-sync@caseyWebb", "doc-gate@caseyWebb"]
}
```

## Plugins

| Plugin | Description |
| ------ | ----------- |
| **pr-description-sync** | Reminds Claude to update PR title and description after git push |
| **doc-gate** | Blocks Claude at stop to review docs with `update-when` frontmatter for staleness |
