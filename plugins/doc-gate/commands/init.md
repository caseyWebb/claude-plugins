---
description: Add or update `update-when` frontmatter on docs scanned by doc-gate
allowed-tools: Read, Edit, Write, Bash
---

Initialize doc-gate by ensuring every doc that could be surfaced by the gate declares an `update-when` condition.

doc-gate's Stop hook always considers `./*.md` and any `*.md` under `docs/`, and conditionally surfaces deeper docs (e.g. `src/auth/README.md`) when adjacent code changes. Bootstrap all of them now so the gate has something to surface later. Skip any file where you can't derive a meaningful condition; report it at the end.

Candidate files: !`{ ls ./*.md 2>/dev/null; find docs -type f -name '*.md' 2>/dev/null; git ls-files '*.md' 2>/dev/null; git ls-files --others --exclude-standard '*.md' 2>/dev/null; } | sed 's|^\./||' | sort -u`

For each candidate:

1. Read the file.
2. Skim the title, headings, and body to figure out what the doc is about.
3. Decide what kinds of changes should make someone re-review this doc, phrased as a single condition (e.g. `the public API surface changes`, `deployment steps change`, `build/run commands change`, `the install flow changes`). If you genuinely cannot derive a meaningful condition, skip the file and report it at the end.
4. Apply the result:
   - **No frontmatter block:** prepend a new block containing only `update-when: <condition>`.
   - **Frontmatter exists, no `update-when` key:** insert `update-when: <condition>` into the existing block.
   - **`update-when` already present:** leave it untouched unless the value is clearly wrong for the current content. If wrong, ask the user before changing.

Format constraint (the hook parses with awk):

- The value must be a single line.
- Do not quote the value.
- The frontmatter delimiters must be exactly `---` on their own lines.

Example:

```
---
update-when: the public API surface or auth flow changes
---
```

When done, print a summary table of each file and the `update-when` value applied (or `skipped` with a one-line reason). Do not commit.
