#!/bin/bash
# pr-template-inject.sh — PreToolUse hook that denies `gh pr create` /
# `gh pr edit --body*` when the outgoing body doesn't structurally match
# the repo's PULL_REQUEST_TEMPLATE. Idempotent: passes silently once
# Claude's retry includes every template heading.

set -uo pipefail

INPUT=$(cat)

if command -v jq &>/dev/null; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
  CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
else
  CMD=$(echo "$INPUT" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  CWD=$(echo "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

[ -z "$CMD" ] && exit 0

is_create=0
is_edit=0
echo "$CMD" | grep -qE '(^|[;&|[:space:]])gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)' && is_create=1
echo "$CMD" | grep -qE '(^|[;&|[:space:]])gh[[:space:]]+pr[[:space:]]+edit([[:space:]]|$)' && is_edit=1

if [ $is_create -eq 0 ] && [ $is_edit -eq 0 ]; then
  exit 0
fi

# For `gh pr edit`, only intervene when the body is being touched.
if [ $is_edit -eq 1 ] && [ $is_create -eq 0 ]; then
  if ! echo "$CMD" | grep -qE '(^|[[:space:]])(--body|--body-file|-b|-F)([[:space:]=]|$)'; then
    exit 0
  fi
fi

# ─── Target dir resolution (polyrepo-aware) ────────────────────────────────
# Walk leading `cd`/`pushd <path>` segments off the front of the command,
# resolving each against the prior working dir. This handles
#   cd child && gh pr create …
#   (cd child && gh pr create …)
#   cd a && cd b && gh pr create …
TARGET_DIR="$CWD"
rest="$CMD"
cd_found=0

# Strip leading whitespace and a single opening paren (subshell).
rest="${rest#"${rest%%[![:space:]]*}"}"
rest="${rest#\(}"
rest="${rest#"${rest%%[![:space:]]*}"}"

while [[ "$rest" =~ ^(cd|pushd)[[:space:]]+([^[:space:];\&\|\)]+)[[:space:]]*(\&\&|;|\|\|)[[:space:]]*(.*)$ ]]; do
  path="${BASH_REMATCH[2]}"
  rest="${BASH_REMATCH[4]}"
  # Strip matched surrounding quotes.
  case "$path" in
    \"*\") path="${path#\"}"; path="${path%\"}" ;;
    \'*\') path="${path#\'}"; path="${path%\'}" ;;
  esac
  # Expand leading ~ in the parsed path (manual expansion; the value came
  # from JSON, not the shell).
  # shellcheck disable=SC2088
  case "$path" in
    "~")     path="$HOME" ;;
    "~/"*)   path="$HOME/${path#\~/}" ;;
  esac
  if [[ "$path" = /* ]]; then
    TARGET_DIR="$path"
  else
    TARGET_DIR="$TARGET_DIR/$path"
  fi
  cd_found=1
done

# If a --repo/-R flag is present but we never saw a local `cd`, we can't
# reliably locate the template on disk. Exit quietly rather than false-deny.
if [ $cd_found -eq 0 ] && echo "$CMD" | grep -qE '(^|[[:space:]])(-R|--repo)[[:space:]]+'; then
  exit 0
fi

# Normalize (resolve ..). If the directory doesn't exist, give up silently.
if [ -d "$TARGET_DIR" ]; then
  TARGET_DIR=$(cd "$TARGET_DIR" 2>/dev/null && pwd) || exit 0
else
  exit 0
fi

# Project-level silencing.
[ -f "$TARGET_DIR/.claude/hooks/.disable-pr-template-inject" ] && exit 0

# ─── Template discovery ────────────────────────────────────────────────────
find_template_in() {
  local dir="$1"
  local c
  for c in \
    "$dir/.github/PULL_REQUEST_TEMPLATE.md" \
    "$dir/.github/pull_request_template.md" \
    "$dir/PULL_REQUEST_TEMPLATE.md" \
    "$dir/docs/PULL_REQUEST_TEMPLATE.md"; do
    if [ -f "$c" ]; then
      printf 'FILE\t%s\n' "$c"
      return 0
    fi
  done
  if [ -d "$dir/.github/PULL_REQUEST_TEMPLATE" ]; then
    printf 'DIR\t%s\n' "$dir/.github/PULL_REQUEST_TEMPLATE"
    return 0
  fi
  return 1
}

TEMPLATE_INFO=$(find_template_in "$TARGET_DIR")
if [ -z "$TEMPLATE_INFO" ]; then
  TOPLEVEL=$(git -C "$TARGET_DIR" rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$TOPLEVEL" ] && [ "$TOPLEVEL" != "$TARGET_DIR" ]; then
    TEMPLATE_INFO=$(find_template_in "$TOPLEVEL")
    [ -f "$TOPLEVEL/.claude/hooks/.disable-pr-template-inject" ] && exit 0
  fi
fi
[ -z "$TEMPLATE_INFO" ] && exit 0

TEMPLATE_KIND="${TEMPLATE_INFO%%$'\t'*}"
TEMPLATE_PATH="${TEMPLATE_INFO#*$'\t'}"

# ─── Output helpers ────────────────────────────────────────────────────────
emit_deny() {
  local reason="$1"
  if command -v jq &>/dev/null; then
    jq -n --arg reason "$reason" \
      '{ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason } }'
  else
    local escaped
    escaped=$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g' | awk 'BEGIN{ORS=""} {if(NR>1)printf "\\n"; print}')
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}' "$escaped"
  fi
}

# Multi-template case: block and list options. No structural check possible
# until Claude picks one.
if [ "$TEMPLATE_KIND" = "DIR" ]; then
  LIST=""
  for f in "$TEMPLATE_PATH"/*.md; do
    [ -f "$f" ] || continue
    LIST="${LIST}  - ${f}
"
  done
  [ -z "$LIST" ] && exit 0
  REASON="This repo has multiple PR templates under ${TEMPLATE_PATH}. Pick one and structure your PR body to match its headings:

${LIST}
To silence this hook in this project: touch .claude/hooks/.disable-pr-template-inject"
  emit_deny "$REASON"
  exit 0
fi

# ─── Heading extraction ────────────────────────────────────────────────────
# Emits LEVEL<TAB>TEXT per heading, skipping fenced code blocks.
HEADINGS=$(awk '
  /^```/ { infence = !infence; next }
  infence { next }
  /^#{1,6}[[:space:]]+/ {
    line = $0
    sub(/[[:space:]]+#*[[:space:]]*$/, "", line)
    match(line, /^#+/)
    lvl = RLENGTH
    text = substr(line, lvl + 1)
    sub(/^[[:space:]]+/, "", text)
    if (length(text) > 0) printf "%d\t%s\n", lvl, text
  }
' "$TEMPLATE_PATH")

# No headings to enforce → silent pass.
[ -z "$HEADINGS" ] && exit 0

# ─── Haystack construction ─────────────────────────────────────────────────
HAYSTACK="$CMD"

# If --body-file/-F points at a readable file, append its contents so the
# match check sees headings that live outside the command string.
if [[ "$CMD" =~ (^|[[:space:]])(--body-file|-F)[[:space:]]+([^[:space:];\&\|\)]+) ]]; then
  body_file="${BASH_REMATCH[3]}"
  case "$body_file" in
    \"*\") body_file="${body_file#\"}"; body_file="${body_file%\"}" ;;
    \'*\') body_file="${body_file#\'}"; body_file="${body_file%\'}" ;;
  esac
  # shellcheck disable=SC2088
  case "$body_file" in
    "~")   body_file="$HOME" ;;
    "~/"*) body_file="$HOME/${body_file#\~/}" ;;
  esac
  if [[ "$body_file" != /* ]]; then
    body_file="$TARGET_DIR/$body_file"
  fi
  if [ -f "$body_file" ]; then
    HAYSTACK="${HAYSTACK}
$(cat "$body_file")"
  fi
fi

# ─── Structural match check ────────────────────────────────────────────────
MISSING=""
while IFS=$'\t' read -r lvl text; do
  [ -z "$lvl" ] && continue
  hashes=$(printf '#%.0s' $(seq 1 "$lvl"))
  # Escape ERE metacharacters in the heading text.
  esc_text=$(printf '%s' "$text" | sed 's/[][\.*^$/()+?{}|]/\\&/g')
  pattern="^${hashes} ${esc_text}[[:space:]]*\$"
  if ! printf '%s' "$HAYSTACK" | grep -qE "$pattern"; then
    MISSING="${MISSING}  - ${hashes} ${text}
"
  fi
done <<< "$HEADINGS"

# Everything present → silent pass (this is the idempotent retry path).
[ -z "$MISSING" ] && exit 0

# ─── Deny ──────────────────────────────────────────────────────────────────
TEMPLATE_BODY=$(cat "$TEMPLATE_PATH")
REASON="This repo has a PR template at ${TEMPLATE_PATH}. Your PR body is missing these required headings (match level exactly):

${MISSING}
Keep every template heading. For optional sections that don't apply (e.g. Screenshots), keep the heading and write 'N/A' under it rather than deleting the section. Then re-run the command.

Template:

${TEMPLATE_BODY}

To silence this hook in this project: touch .claude/hooks/.disable-pr-template-inject"

emit_deny "$REASON"
