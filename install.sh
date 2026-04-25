#!/bin/bash
# Install effort-suggest hook into ~/.claude/.
# Idempotent: safe to re-run. Preserves existing hook entries in settings.json.
set -eu

SOURCE_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_HOOK_DIR="$HOME/.claude/hooks"
TARGET_CONFIG="$HOME/.claude/effort-suggest.json"
TARGET_SETTINGS="$HOME/.claude/settings.json"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required. Install via 'brew install jq' or apt." >&2; exit 1; }

mkdir -p "$TARGET_HOOK_DIR" "$HOME/.claude/cache"

# Copy hook script.
cp "$SOURCE_DIR/hooks/effort-suggest.sh" "$TARGET_HOOK_DIR/effort-suggest.sh"
chmod +x "$TARGET_HOOK_DIR/effort-suggest.sh"
echo "Installed: $TARGET_HOOK_DIR/effort-suggest.sh"

# Install default config only if absent (don't clobber user tuning).
if [ ! -f "$TARGET_CONFIG" ]; then
  cp "$SOURCE_DIR/effort-suggest.default.json" "$TARGET_CONFIG"
  echo "Installed: $TARGET_CONFIG (default config)"
else
  echo "Skipped:   $TARGET_CONFIG (already exists; not overwritten)"
fi

# Register hook in settings.json (preserves existing hook keys).
if [ ! -f "$TARGET_SETTINGS" ]; then
  printf '{"hooks":{}}\n' > "$TARGET_SETTINGS"
fi
TMP=$(mktemp)
jq '.hooks.UserPromptSubmit = [{"matcher":"*","hooks":[{"type":"command","command":"$HOME/.claude/hooks/effort-suggest.sh"}]}]' "$TARGET_SETTINGS" > "$TMP" && mv "$TMP" "$TARGET_SETTINGS"
echo "Registered: UserPromptSubmit hook in $TARGET_SETTINGS"

echo ""
echo "Done. Restart any open Claude Code sessions to pick up the new hook."
echo ""
echo "Quick test:"
echo "  echo '{\"session_id\":\"t1\",\"cwd\":\"/tmp\",\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"summarize @foo.md\"}' \\"
echo "    | EFFORT_SUGGEST_CURRENT=high $TARGET_HOOK_DIR/effort-suggest.sh | jq -r '.hookSpecificOutput.additionalContext'"
