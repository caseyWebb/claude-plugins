# claude-plugins

Personal Claude Code plugin marketplace.

## Installing

```
/plugin marketplace add caseyWebb/claude-plugins
/plugin install pr-description-sync@caseyWebb
/plugin install doc-gate@caseyWebb
/plugin install pr-template-inject@caseyWebb
```

Or auto-enable in a project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": ["caseyWebb/claude-plugins"],
  "enabledPlugins": [
    "pr-description-sync@caseyWebb",
    "doc-gate@caseyWebb",
    "pr-template-inject@caseyWebb"
  ]
}
```

## Plugins

| Plugin | Description |
| ------ | ----------- |
| **pr-description-sync** | Reminds Claude to update PR title and description after git push |
| **doc-gate** | Blocks Claude at stop to review docs with `update-when` frontmatter for staleness |
| **pr-template-inject** | Blocks `gh pr create`/`edit` when the PR body is missing headings from the repo's `PULL_REQUEST_TEMPLATE.md` |
