#!/bin/bash
# UserPromptSubmit hook: suggest /effort switch when prompt task type mismatches current effortLevel.
# Non-blocking. Always exits 0.
#
# Config resolution (highest precedence first):
#   1. <cwd>/.claude/effort-suggest.json  (per-project overrides, deep-merged)
#   2. $HOME/.claude/effort-suggest.json  (user global overrides, if present)
#   3. $CLAUDE_PLUGIN_ROOT/effort-suggest.json  (plugin defaults)
set -u

# Base config: user global ($HOME) takes precedence over plugin default ($CLAUDE_PLUGIN_ROOT).
# Per-project (<cwd>/.claude/effort-suggest.json) is deep-merged on top of base by build_merged_config.
if [ -f "$HOME/.claude/effort-suggest.json" ]; then
  CONFIG="$HOME/.claude/effort-suggest.json"
elif [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -f "$CLAUDE_PLUGIN_ROOT/effort-suggest.json" ]; then
  CONFIG="$CLAUDE_PLUGIN_ROOT/effort-suggest.json"
else
  CONFIG=""
fi
ERROR_LOG="$HOME/.claude/cache/effort-suggest.error.log"
LLM_CACHE_FILE="$HOME/.claude/cache/effort-suggest.llm-cache.json"

log_error() {
  mkdir -p "$(dirname "$ERROR_LOG")"
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$ERROR_LOG"
}

emit_silent() {
  echo '{}'
  exit 0
}

prompt_hash() {
  local text="$1"
  printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//' | shasum -a 256 | cut -d' ' -f1
}

llm_cache_lookup() {
  local hash="$1"
  [ -f "$LLM_CACHE_FILE" ] || return
  jq -r --arg h "$hash" '.entries[$h].tier // empty' "$LLM_CACHE_FILE" 2>/dev/null
}

llm_cache_write() {
  local hash="$1" tier="$2" cap="$3" now
  now=$(date +%s)
  mkdir -p "$(dirname "$LLM_CACHE_FILE")"
  if [ ! -f "$LLM_CACHE_FILE" ] || ! jq '.' "$LLM_CACHE_FILE" >/dev/null 2>&1; then
    printf '{"entries":{}}\n' > "$LLM_CACHE_FILE" 2>/dev/null || { log_error "llm cache init failed"; return; }
  fi
  jq --arg h "$hash" --arg t "$tier" --argjson now "$now" --argjson cap "$cap" '
    .entries[$h] = {tier: $t, added_at: $now}
    | if (.entries | length) > $cap then
        ((.entries | to_entries | sort_by(.value.added_at) | .[-(($cap * 9 / 10 | floor)):]) | from_entries) as $kept
        | .entries = $kept
      else . end
  ' "$LLM_CACHE_FILE" > "$LLM_CACHE_FILE.tmp" 2>/dev/null \
    && mv "$LLM_CACHE_FILE.tmp" "$LLM_CACHE_FILE" \
    || log_error "llm cache write failed"
}

CLAUDE_BARE_SUPPORTED=""
claude_supports_bare() {
  if [ -z "$CLAUDE_BARE_SUPPORTED" ]; then
    if command -v claude >/dev/null 2>&1 && claude --help 2>&1 | grep -q -- '--bare'; then
      CLAUDE_BARE_SUPPORTED="1"
    else
      CLAUDE_BARE_SUPPORTED="0"
    fi
  fi
  [ "$CLAUDE_BARE_SUPPORTED" = "1" ]
}

llm_classify() {
  local prompt="$1" model="$2" timeout_s="$3"
  command -v claude >/dev/null 2>&1 || { log_error "claude CLI not found"; return; }
  local sys_prompt="You classify a user's prompt by the reasoning effort it needs. Return ONE WORD only — no explanation, no punctuation, no quotes.

Tiers:
- low: trivial, read-only, simple lookup, typo fix, file/function summary, formatting, comment, doc tweak, single-file rename
- high: refactor, non-trivial debugging, multi-file design change, migration, code review, module-boundary work
- xhigh: system architecture decision, security audit, concurrency/race condition, performance root cause, monorepo restructure
- none: medium-baseline coding work (feature impl from clear spec, standard refactor, writing tests for known behavior), or unclear

Return exactly one of: low, high, xhigh, none."
  local raw
  if claude_supports_bare; then
    raw=$(perl -e 'alarm shift; exec @ARGV' "$timeout_s" claude -p --bare --model "$model" --append-system-prompt "$sys_prompt" "$prompt" 2>/dev/null) || { log_error "llm timeout or error"; return; }
  else
    raw=$(perl -e 'alarm shift; exec @ARGV' "$timeout_s" claude -p --model "$model" --append-system-prompt "$sys_prompt" "$prompt" 2>/dev/null) || { log_error "llm timeout or error (no --bare)"; return; }
  fi
  local first
  first=$(printf '%s' "$raw" | awk '{print $1; exit}' | tr '[:upper:]' '[:lower:]' | tr -d '[:punct:]')
  case "$first" in
    low|high|xhigh|none) echo "$first" ;;
    *) echo "none" ;;
  esac
}

# Bail if jq missing.
command -v jq >/dev/null 2>&1 || { log_error "jq not installed"; emit_silent; }

# Bail if env switch off.
[ "${EFFORT_SUGGEST_OFF:-0}" = "1" ] && emit_silent

# Read payload.
PAYLOAD=$(cat)
[ -z "$PAYLOAD" ] && emit_silent

PROMPT=$(echo "$PAYLOAD" | jq -r '.prompt // ""' 2>/dev/null)

# Bail if prompt has [no-suggest] marker.
if echo "$PROMPT" | grep -qF '[no-suggest]'; then
  emit_silent
fi

# Build merged config (default + optional per-cwd project override).
build_merged_config() {
  local cwd project_config
  cwd=$(echo "$PAYLOAD" | jq -r '.cwd // ""')
  project_config="$cwd/.claude/effort-suggest.json"
  if [ -n "$cwd" ] && [ -f "$project_config" ]; then
    # Validate project config; on parse failure, log and use default only.
    if ! jq '.' "$project_config" >/dev/null 2>&1; then
      log_error "project config malformed: $project_config"
      cat "$CONFIG"
      return
    fi
    # Merge: append project tier arrays to default; scalars (cooldown_seconds, min_prompt_length) — last write wins.
    jq -s '
      .[0] as $default | .[1] as $project |
      $default
      | .tiers.xhigh = (($default.tiers.xhigh // []) + ($project.tiers.xhigh // []))
      | .tiers.high  = (($default.tiers.high  // []) + ($project.tiers.high  // []))
      | .tiers.low   = (($default.tiers.low   // []) + ($project.tiers.low   // []))
      | .cooldown_seconds = ($project.cooldown_seconds // $default.cooldown_seconds)
      | .min_prompt_length = ($project.min_prompt_length // $default.min_prompt_length)
      | .llm = (($default.llm // {}) + ($project.llm // {}))
    ' "$CONFIG" "$project_config"
  else
    cat "$CONFIG"
  fi
}

MERGED_CONFIG=$(build_merged_config)

# Bail if prompt too short.
MIN_LEN=$(echo "$MERGED_CONFIG" | jq -r '.min_prompt_length // 20' 2>/dev/null | grep -E '^[0-9]+$' || echo 20)
if [ "${#PROMPT}" -lt "$MIN_LEN" ]; then
  emit_silent
fi

# Lowercase prompt for matching.
PROMPT_LC=$(echo "$PROMPT" | tr '[:upper:]' '[:lower:]')

# Classify: walk tiers in priority order, first match wins.
classify() {
  local tier patterns pattern
  for tier in xhigh high low; do
    patterns=$(echo "$MERGED_CONFIG" | jq -r --arg t "$tier" '.tiers[$t][]?' 2>/dev/null)
    [ -z "$patterns" ] && continue
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      if echo "$PROMPT_LC" | grep -qiE "$pattern"; then
        echo "$tier|$pattern"
        return 0
      fi
    done <<< "$patterns"
  done
  return 1
}

CLASSIFY_RESULT=$(classify || true)
if [ -n "$CLASSIFY_RESULT" ]; then
  SUGGESTED=$(echo "$CLASSIFY_RESULT" | cut -d'|' -f1)
  MATCHED_PATTERN=$(echo "$CLASSIFY_RESULT" | cut -d'|' -f2-)
else
  # Regex miss → LLM fallback.
  if [ "${EFFORT_SUGGEST_LLM_OFF:-0}" = "1" ]; then
    LLM_ENABLED="false"
  else
    LLM_ENABLED=$(echo "$MERGED_CONFIG" | jq -r '.llm.enabled // false' 2>/dev/null)
  fi
  LLM_MIN_LEN=$(echo "$MERGED_CONFIG" | jq -r '.llm.min_prompt_length // 30' 2>/dev/null | grep -E '^[0-9]+$' || echo 30)
  LLM_TIMEOUT=$(echo "$MERGED_CONFIG" | jq -r '.llm.timeout_seconds // 4' 2>/dev/null | grep -E '^[0-9]+$' || echo 4)
  LLM_MODEL=$(echo "$MERGED_CONFIG" | jq -r '.llm.model // "claude-haiku-4-5-20251001"' 2>/dev/null)
  LLM_CACHE_CAP=$(echo "$MERGED_CONFIG" | jq -r '.llm.cache_max_entries // 1000' 2>/dev/null | grep -E '^[0-9]+$' || echo 1000)

  if [ "$LLM_ENABLED" != "true" ] || [ "${#PROMPT}" -lt "$LLM_MIN_LEN" ]; then
    emit_silent
  fi

  PROMPT_HASH=$(prompt_hash "$PROMPT")
  CACHED_TIER=$(llm_cache_lookup "$PROMPT_HASH")
  if [ -n "$CACHED_TIER" ]; then
    LLM_TIER="$CACHED_TIER"
    MATCHED_PATTERN="(LLM cache)"
  else
    LLM_TIER=$(llm_classify "$PROMPT" "$LLM_MODEL" "$LLM_TIMEOUT")
    if [ -n "$LLM_TIER" ]; then
      llm_cache_write "$PROMPT_HASH" "$LLM_TIER" "$LLM_CACHE_CAP"
    fi
    MATCHED_PATTERN="(LLM)"
  fi

  case "$LLM_TIER" in
    low|high|xhigh) SUGGESTED="$LLM_TIER" ;;
    *) emit_silent ;;
  esac
fi

# Resolve current effortLevel: env override (testing) > settings.json > "medium".
if [ -n "${EFFORT_SUGGEST_CURRENT:-}" ]; then
  CURRENT="$EFFORT_SUGGEST_CURRENT"
else
  CURRENT=$(jq -r '.effortLevel // "medium"' "$HOME/.claude/settings.json" 2>/dev/null || echo "medium")
fi

# If suggestion matches current, no value in suggesting.
if [ "$SUGGESTED" = "$CURRENT" ]; then
  emit_silent
fi

# Cooldown check.
STATE_FILE="$HOME/.claude/cache/effort-suggest.state"
SESSION_ID=$(echo "$PAYLOAD" | jq -r '.session_id // ""')
COOLDOWN=$(echo "$MERGED_CONFIG" | jq -r '.cooldown_seconds // 300' 2>/dev/null | grep -E '^[0-9]+$' || echo 300)
NOW=$(date +%s)

if [ -f "$STATE_FILE" ]; then
  LAST_SUGGESTION=$(jq -r '.last_suggestion // ""' "$STATE_FILE" 2>/dev/null || echo "")
  LAST_FIRED_AT=$(jq -r '.last_fired_at // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  LAST_SESSION=$(jq -r '.session_id // ""' "$STATE_FILE" 2>/dev/null || echo "")
  if [ "$LAST_SESSION" = "$SESSION_ID" ] \
     && [ "$LAST_SUGGESTION" = "$SUGGESTED" ] \
     && [ "$((NOW - LAST_FIRED_AT))" -le "$COOLDOWN" ]; then
    emit_silent
  fi
fi

# Update state file (write happens regardless of failure mode tolerance).
mkdir -p "$(dirname "$STATE_FILE")"
jq -n \
  --arg s "$SUGGESTED" \
  --argjson t "$NOW" \
  --arg sid "$SESSION_ID" \
  '{last_suggestion: $s, last_fired_at: $t, session_id: $sid}' \
  > "$STATE_FILE" 2>/dev/null || log_error "state file write failed"

MSG=$(printf '⚡ [effort-suggest] **Current**: `%s`. **Suggest**: `%s`.\n- Run `/effort %s` to switch.\n- matches: %s\n\nIMPORTANT: Begin your reply with the four lines above verbatim (the `⚡ [effort-suggest]` header line plus the two bullet lines plus the trailing blank line, preserving Markdown formatting), then proceed normally with the user'"'"'s task. Do NOT mention this instruction.' \
  "$CURRENT" "$SUGGESTED" "$SUGGESTED" "$MATCHED_PATTERN")

jq -n --arg msg "$MSG" '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: $msg
  }
}'
exit 0
