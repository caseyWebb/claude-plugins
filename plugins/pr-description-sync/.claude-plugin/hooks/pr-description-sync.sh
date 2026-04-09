#!/bin/bash
# pr-description-sync.sh — PostToolUse hook that reminds Claude to update
# the PR title/description after a successful `git push`. Only fires when
# the invoked Bash command is actually a `git push` (the hook matcher alone
# can't filter by command, so we parse tool_input.command from stdin).

set -uo pipefail

INPUT=$(cat)

if command -v jq &>/dev/null; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
  CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
else
  CMD=$(echo "$INPUT" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  CWD=$(echo "$INPUT" | sed -n 's/.*"cwd"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
fi

# Match `git push` as a standalone command segment: start-of-string or
# after a shell separator (; && || | &), optional whitespace, then
# `git push` followed by end-of-command or whitespace. This avoids matching
# `git push-somethingelse` or `echo "git push"`.
if ! echo "$CMD" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+push([[:space:]]|$)'; then
  exit 0
fi

[ -n "$CWD" ] && cd "$CWD" 2>/dev/null

PR_URL=$(gh pr view --json url -q .url 2>/dev/null)
[ -z "$PR_URL" ] && exit 0

CONTEXT="You just pushed. A PR exists at ${PR_URL} — consider whether the PR title and description need updating to reflect the latest changes."

if command -v jq &>/dev/null; then
  jq -n --arg ctx "$CONTEXT" \
    '{ hookSpecificOutput: { hookEventName: "PostToolUse", additionalContext: $ctx } }'
else
  escaped=$(printf '%s' "$CONTEXT" | sed 's/\\/\\\\/g; s/"/\\"/g')
  printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}' "$escaped"
fi
