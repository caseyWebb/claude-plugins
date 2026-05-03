#!/bin/bash
# doc-gate.sh — Stop hook that reminds Claude to review docs for updates.
#
# Candidate discovery is two-tier:
#   1. Always: ./*.md  +  any *.md under docs/
#   2. Conditional: any other *.md whose directory contains a changed
#      (non-md, non-openspec) file at any depth.
#
# Only docs declaring `update-when` frontmatter end up in the table.
# Blocks once per stop cycle (skips when stop_hook_active=true).

source "$(dirname "$0")/lib.sh"

parse_input

[ "$STOP_ACTIVE" = "true" ] && exit 0

cd "$CWD" || exit 0

[ -f ".claude/hooks/.disable-doc-gate" ] && exit 0

CHANGED=$(changed_code_files)
[ -z "$CHANGED" ] && exit 0

UNIVERSE=$(
  { ls ./*.md 2>/dev/null
    [ -d docs ] && find docs -type f -name '*.md' 2>/dev/null
    git ls-files '*.md' 2>/dev/null
    git ls-files --others --exclude-standard '*.md' 2>/dev/null
  } | sed 's|^\./||' | sort -u
)

[ -z "$UNIVERSE" ] && exit 0

# update-when parser: requires the opening `---` to be on line 1, so a
# body-level horizontal rule in a no-frontmatter file can't false-match.
# Strips UTF-8 BOM and CRLF endings before matching.
read_update_when() {
  awk '
    NR==1 {
      # Strip UTF-8 BOM if present. Use substr/string literal so the bytes
      # match on awks (incl. macOS one-true-awk) that do not honor hex/octal
      # escapes in regex literals.
      if (substr($0, 1, 3) == "\357\273\277") $0 = substr($0, 4)
    }
    { sub(/\r$/, "") }
    NR==1 && /^---[[:space:]]*$/ { n=1; next }
    NR>1  && n==0 { exit }
    n==1 && /^---[[:space:]]*$/ { exit }
    n==1 && /^update-when:[[:space:]]*/ {
      sub(/^update-when:[[:space:]]*/, ""); print; exit
    }
  ' "$1" 2>/dev/null
}

TABLE=""
while IFS= read -r doc; do
  [ -z "$doc" ] && continue
  [ -f "$doc" ] || continue

  # Always-set: top-level *.md or anything under docs/.
  if [[ "$doc" != */* ]] || [[ "$doc" == docs/* ]]; then
    keep=1
  else
    # Conditional: a changed file must live in this doc's directory tree.
    keep=0
    doc_dir="$(dirname "$doc")/"
    while IFS= read -r c; do
      [ -z "$c" ] && continue
      if [[ "$c" == "$doc_dir"* ]]; then
        keep=1
        break
      fi
    done <<< "$CHANGED"
  fi

  [ "$keep" = "1" ] || continue

  WHEN=$(read_update_when "$doc")
  if [ -n "$WHEN" ]; then
    TABLE="${TABLE}  ${doc} — ${WHEN}
"
  fi
done <<< "$UNIVERSE"

[ -z "$TABLE" ] && exit 0

REASON="Review these docs for any that need updating based on your work:

${TABLE}
To silence doc-gate in this project, run: touch .claude/hooks/.disable-doc-gate"

block_with_reason "$REASON"
