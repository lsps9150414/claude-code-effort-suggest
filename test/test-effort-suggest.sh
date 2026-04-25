#!/bin/bash
# Manual smoke tests for effort-suggest hook.
# Each run_test_N runs one scenario and prints PASS/FAIL.
#
# Runs against the repo-local hook by default (../hooks/effort-suggest.sh).
# Override with: TEST_SCRIPT=/path/to/effort-suggest.sh ./test-effort-suggest.sh
set -u
export EFFORT_SUGGEST_LLM_OFF=1

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${TEST_SCRIPT:-$TEST_DIR/../hooks/effort-suggest.sh}"
FIXTURES_DIR="${TEST_FIXTURES:-$TEST_DIR/fixtures}"
export CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$TEST_DIR/..}"
PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label"
    echo "  expected: $expected"
    echo "  actual:   $actual"
    FAIL=$((FAIL + 1))
  fi
}

run_test_1_smoke() {
  local payload='{"session_id":"s1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"hello"}'
  local out
  out=$(echo "$payload" | "$SCRIPT" 2>/dev/null)
  assert_eq "test_1_smoke: script exits 0 with empty {} or no output" "true" "$([ -z "$out" ] || [ "$out" = "{}" ] && echo true || echo false)"
}

run_test_3a_short_prompt() {
  local payload='{"session_id":"s1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"yes"}'
  local out
  out=$(echo "$payload" | "$SCRIPT" 2>/dev/null)
  assert_eq "test_3a_short_prompt: short prompt suppresses output" "" "$(echo "$out" | jq -er '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
}

run_test_3b_off_env() {
  local payload='{"session_id":"s1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please refactor the entire architecture of the auth module"}'
  local out
  out=$(echo "$payload" | EFFORT_SUGGEST_OFF=1 "$SCRIPT" 2>/dev/null)
  assert_eq "test_3b_off_env: EFFORT_SUGGEST_OFF=1 suppresses output" "" "$(echo "$out" | jq -er '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
}

run_test_3c_no_suggest_marker() {
  local payload='{"session_id":"s1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please refactor the entire architecture [no-suggest]"}'
  local out
  out=$(echo "$payload" | "$SCRIPT" 2>/dev/null)
  assert_eq "test_3c_no_suggest_marker: [no-suggest] marker suppresses output" "" "$(echo "$out" | jq -er '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
}

run_test_4a_low_tier() {
  local payload='{"session_id":"s1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please fix the typo in foo.ts"}'
  local out ctx
  out=$(echo "$payload" | EFFORT_SUGGEST_CURRENT=high "$SCRIPT" 2>/dev/null)
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in
    *'Suggest**: `low`'*) echo "PASS: test_4a_low_tier"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: test_4a_low_tier"; echo "  ctx: $ctx"; FAIL=$((FAIL + 1)) ;;
  esac
}

run_test_4b_high_tier() {
  local payload='{"session_id":"s1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"refactor the auth middleware to use the new error pattern"}'
  local out ctx
  # Force current=low so suggested=high differs and fires.
  out=$(echo "$payload" | EFFORT_SUGGEST_CURRENT=low "$SCRIPT" 2>/dev/null)
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in
    *'Suggest**: `high`'*) echo "PASS: test_4b_high_tier"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: test_4b_high_tier"; echo "  ctx: $ctx"; FAIL=$((FAIL + 1)) ;;
  esac
}

run_test_4c_xhigh_tier() {
  local payload='{"session_id":"s1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"redesign the architecture of the rendering pipeline for the new platform"}'
  local out ctx
  out=$(echo "$payload" | EFFORT_SUGGEST_CURRENT=low "$SCRIPT" 2>/dev/null)
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in
    *'Suggest**: `xhigh`'*) echo "PASS: test_4c_xhigh_tier"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: test_4c_xhigh_tier"; echo "  ctx: $ctx"; FAIL=$((FAIL + 1)) ;;
  esac
}

run_test_4d_no_match() {
  local payload='{"session_id":"s1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"hmmmm okay then proceed with the task at hand thanks"}'
  local out
  out=$(echo "$payload" | "$SCRIPT" 2>/dev/null)
  assert_eq "test_4d_no_match: neutral prose suppresses output" "" "$(echo "$out" | jq -er '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
}

run_test_5_current_eq_suggested() {
  local payload='{"session_id":"s1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please fix the typo in foo.ts"}'
  local out
  # Force current=low so suggestion (low) matches → silent.
  out=$(EFFORT_SUGGEST_CURRENT=low echo "$payload" | EFFORT_SUGGEST_CURRENT=low "$SCRIPT" 2>/dev/null)
  assert_eq "test_5_current_eq_suggested: same current/suggested suppresses" "" "$(echo "$out" | jq -er '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
}

run_test_6_cooldown() {
  local payload='{"session_id":"sess-cooldown","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please fix the typo in foo.ts"}'
  # Clear state.
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  # First fire — expect suggestion.
  local out1 ctx1
  out1=$(EFFORT_SUGGEST_CURRENT=high echo "$payload" | EFFORT_SUGGEST_CURRENT=high "$SCRIPT" 2>/dev/null)
  ctx1=$(echo "$out1" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx1" in
    *'Suggest**: `low`'*) ;;
    *) echo "FAIL: test_6_cooldown (first fire missing)"; FAIL=$((FAIL + 1)); return ;;
  esac
  # Second fire same session same suggestion within cooldown — expect silent.
  local out2
  out2=$(EFFORT_SUGGEST_CURRENT=high echo "$payload" | EFFORT_SUGGEST_CURRENT=high "$SCRIPT" 2>/dev/null)
  assert_eq "test_6_cooldown: second fire within cooldown suppresses" "" "$(echo "$out2" | jq -er '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
}

run_test_7_session_reset() {
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  local payload_a='{"session_id":"sess-A","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please fix the typo in foo.ts"}'
  EFFORT_SUGGEST_CURRENT=high echo "$payload_a" | EFFORT_SUGGEST_CURRENT=high "$SCRIPT" >/dev/null 2>&1
  local payload_b='{"session_id":"sess-B","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please fix the typo in foo.ts"}'
  local out ctx
  out=$(EFFORT_SUGGEST_CURRENT=high echo "$payload_b" | EFFORT_SUGGEST_CURRENT=high "$SCRIPT" 2>/dev/null)
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in
    *'Suggest**: `low`'*) echo "PASS: test_7_session_reset"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: test_7_session_reset"; echo "  ctx: $ctx"; FAIL=$((FAIL + 1)) ;;
  esac
}

run_test_8_project_override() {
  # Set up fixture project with a custom pattern.
  local fixture_dir="/tmp/effort-suggest-fixture-$$"
  mkdir -p "$fixture_dir/.claude"
  cat > "$fixture_dir/.claude/effort-suggest.json" <<EOF
{
  "tiers": {
    "high": ["\\\\bvibeoutfit-special-keyword\\\\b"]
  }
}
EOF
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  local payload
  payload=$(jq -n --arg cwd "$fixture_dir" '{
    session_id: "sess-proj",
    cwd: $cwd,
    hook_event_name: "UserPromptSubmit",
    prompt: "please vibeoutfit-special-keyword the implementation"
  }')
  local out ctx
  out=$(EFFORT_SUGGEST_CURRENT=low echo "$payload" | EFFORT_SUGGEST_CURRENT=low "$SCRIPT" 2>/dev/null)
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in
    *'Suggest**: `high`'*) echo "PASS: test_8_project_override"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: test_8_project_override"; echo "  ctx: $ctx"; FAIL=$((FAIL + 1)) ;;
  esac
  rm -rf "$fixture_dir"
}

run_test_9a_malformed_project_config() {
  local fixture_dir="/tmp/effort-suggest-malformed-$$"
  mkdir -p "$fixture_dir/.claude"
  echo '{ this is not json' > "$fixture_dir/.claude/effort-suggest.json"
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  local payload
  payload=$(jq -n --arg cwd "$fixture_dir" '{
    session_id: "sess-mal",
    cwd: $cwd,
    hook_event_name: "UserPromptSubmit",
    prompt: "please refactor the auth middleware completely"
  }')
  local out ctx exit_code
  out=$(echo "$payload" | EFFORT_SUGGEST_CURRENT=low "$SCRIPT" 2>/dev/null)
  exit_code=$?
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  if [ "$exit_code" = "0" ]; then
    case "$ctx" in
      *'Suggest**: `high`'*) echo "PASS: test_9a_malformed_project_config"; PASS=$((PASS + 1)) ;;
      *) echo "FAIL: test_9a_malformed_project_config (no suggestion)"; FAIL=$((FAIL + 1)) ;;
    esac
  else
    echo "FAIL: test_9a_malformed_project_config (non-zero exit: $exit_code)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$fixture_dir"
}

run_test_9b_error_log_written() {
  local fixture_dir="/tmp/effort-suggest-malformed-$$"
  mkdir -p "$fixture_dir/.claude"
  echo '{ broken' > "$fixture_dir/.claude/effort-suggest.json"
  : > "$HOME/.claude/cache/effort-suggest.error.log"
  local payload
  payload=$(jq -n --arg cwd "$fixture_dir" '{
    session_id: "sess-err",
    cwd: $cwd,
    hook_event_name: "UserPromptSubmit",
    prompt: "please refactor the auth middleware"
  }')
  echo "$payload" | "$SCRIPT" >/dev/null 2>&1
  if grep -q 'project config malformed' "$HOME/.claude/cache/effort-suggest.error.log"; then
    echo "PASS: test_9b_error_log_written"
    PASS=$((PASS + 1))
  else
    echo "FAIL: test_9b_error_log_written (error log empty)"
    FAIL=$((FAIL + 1))
  fi
  rm -rf "$fixture_dir"
}

run_test_10a_summarize_low() {
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  local payload='{"session_id":"sess-sum","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"summarize @vibe-outfit/.agents/README.md please"}'
  local out ctx
  out=$(echo "$payload" | EFFORT_SUGGEST_CURRENT=high "$SCRIPT" 2>/dev/null)
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in
    *'Suggest**: `low`'*) echo "PASS: test_10a_summarize_low"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: test_10a_summarize_low"; echo "  ctx: $ctx"; FAIL=$((FAIL + 1)) ;;
  esac
}

run_test_10b_redesign_high() {
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  local payload='{"session_id":"sess-redes","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"redesign the auth module to support OAuth2"}'
  local out ctx
  out=$(echo "$payload" | EFFORT_SUGGEST_CURRENT=low "$SCRIPT" 2>/dev/null)
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in
    *'Suggest**: `high`'*) echo "PASS: test_10b_redesign_high"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: test_10b_redesign_high"; echo "  ctx: $ctx"; FAIL=$((FAIL + 1)) ;;
  esac
}

run_test_10c_system_design_xhigh() {
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  local payload='{"session_id":"sess-sysd","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"design the system for a multi-tenant payment platform"}'
  local out ctx
  out=$(echo "$payload" | EFFORT_SUGGEST_CURRENT=low "$SCRIPT" 2>/dev/null)
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in
    *'Suggest**: `xhigh`'*) echo "PASS: test_10c_system_design_xhigh"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: test_10c_system_design_xhigh"; echo "  ctx: $ctx"; FAIL=$((FAIL + 1)) ;;
  esac
}

run_test_10d_explain_file_low() {
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  local payload='{"session_id":"sess-expl","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"explain the function at line 42 of utils.ts"}'
  local out ctx
  out=$(echo "$payload" | EFFORT_SUGGEST_CURRENT=high "$SCRIPT" 2>/dev/null)
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in
    *'Suggest**: `low`'*) echo "PASS: test_10d_explain_file_low"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: test_10d_explain_file_low"; echo "  ctx: $ctx"; FAIL=$((FAIL + 1)) ;;
  esac
}

_run_with_fake_claude() {
  local fake_dir="$1" payload="$2"
  rm -f "$HOME/.claude/cache/effort-suggest.llm-cache.json"
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  echo "$payload" | env -u EFFORT_SUGGEST_LLM_OFF EFFORT_SUGGEST_CURRENT=high PATH="$fake_dir:$PATH" "$SCRIPT" 2>/dev/null
}

run_test_11a_llm_returns_low() {
  local payload='{"session_id":"sess-llm-low","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please tidy up the variable names in this snippet"}'
  local out ctx
  out=$(_run_with_fake_claude "$FIXTURES_DIR/fake-claude-low" "$payload")
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in
    *'Suggest**: `low`'*"(LLM)"*) echo "PASS: test_11a_llm_returns_low"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: test_11a_llm_returns_low"; echo "  ctx: $ctx"; FAIL=$((FAIL + 1)) ;;
  esac
}

run_test_11b_llm_cache_hit() {
  local payload='{"session_id":"sess-llm-cache","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please tidy up the variable names in this snippet"}'
  rm -f "$HOME/.claude/cache/effort-suggest.llm-cache.json"
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  local hash
  hash=$(printf 'please tidy up the variable names in this snippet' | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//' | shasum -a 256 | cut -d' ' -f1)
  mkdir -p "$HOME/.claude/cache"
  jq -n --arg h "$hash" '{entries: {($h): {tier: "high", added_at: 1000000000}}}' > "$HOME/.claude/cache/effort-suggest.llm-cache.json"
  local out ctx
  out=$(echo "$payload" | env -u EFFORT_SUGGEST_LLM_OFF EFFORT_SUGGEST_CURRENT=low PATH="$FIXTURES_DIR/fake-claude-low:$PATH" "$SCRIPT" 2>/dev/null)
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext // ""')
  case "$ctx" in
    *'Suggest**: `high`'*"(LLM cache)"*) echo "PASS: test_11b_llm_cache_hit"; PASS=$((PASS + 1)) ;;
    *) echo "FAIL: test_11b_llm_cache_hit"; echo "  ctx: $ctx"; FAIL=$((FAIL + 1)) ;;
  esac
}

run_test_11c_llm_returns_none() {
  local payload='{"session_id":"sess-llm-none","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please do whatever you think is appropriate here"}'
  local out
  out=$(_run_with_fake_claude "$FIXTURES_DIR/fake-claude-none" "$payload")
  assert_eq "test_11c_llm_returns_none: none response suppresses" "" "$(echo "$out" | jq -er '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  local hash cached
  hash=$(printf 'please do whatever you think is appropriate here' | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//' | shasum -a 256 | cut -d' ' -f1)
  cached=$(jq -r --arg h "$hash" '.entries[$h].tier // ""' "$HOME/.claude/cache/effort-suggest.llm-cache.json" 2>/dev/null)
  if [ "$cached" = "none" ]; then
    echo "PASS: test_11c_llm_cached_none"
    PASS=$((PASS + 1))
  else
    echo "FAIL: test_11c_llm_cached_none (cache=$cached)"
    FAIL=$((FAIL + 1))
  fi
}

run_test_11d_llm_returns_garbage() {
  local payload='{"session_id":"sess-llm-garb","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please do whatever you think is right and reasonable"}'
  local out
  out=$(_run_with_fake_claude "$FIXTURES_DIR/fake-claude-garbage" "$payload")
  assert_eq "test_11d_llm_returns_garbage: garbage suppresses" "" "$(echo "$out" | jq -er '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
}

run_test_11e_llm_timeout() {
  rm -f "$HOME/.claude/cache/effort-suggest.llm-cache.json"
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  local fixture_dir="/tmp/effort-suggest-fast-timeout-$$"
  mkdir -p "$fixture_dir/.claude"
  echo '{"llm": {"timeout_seconds": 1}}' > "$fixture_dir/.claude/effort-suggest.json"
  local payload_with_cwd
  payload_with_cwd=$(jq -n --arg cwd "$fixture_dir" '{
    session_id: "sess-llm-slow",
    cwd: $cwd,
    hook_event_name: "UserPromptSubmit",
    prompt: "please do whatever you think is reasonable next here"
  }')
  local out
  out=$(echo "$payload_with_cwd" | env -u EFFORT_SUGGEST_LLM_OFF EFFORT_SUGGEST_CURRENT=high PATH="$FIXTURES_DIR/fake-claude-slow:$PATH" "$SCRIPT" 2>/dev/null)
  rm -rf "$fixture_dir"
  assert_eq "test_11e_llm_timeout: slow LLM suppresses" "" "$(echo "$out" | jq -er '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
  local hash cached
  hash=$(printf 'please do whatever you think is reasonable next here' | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //;s/ $//' | shasum -a 256 | cut -d' ' -f1)
  cached=$(jq -r --arg h "$hash" '.entries[$h].tier // ""' "$HOME/.claude/cache/effort-suggest.llm-cache.json" 2>/dev/null)
  if [ -z "$cached" ]; then
    echo "PASS: test_11e_llm_timeout_no_cache"
    PASS=$((PASS + 1))
  else
    echo "FAIL: test_11e_llm_timeout_no_cache (cache=$cached)"
    FAIL=$((FAIL + 1))
  fi
}

run_test_11f_llm_short_prompt_skipped() {
  local payload='{"session_id":"sess-llm-short","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"do this thing for me ok"}'
  local out
  out=$(_run_with_fake_claude "$FIXTURES_DIR/fake-claude-low" "$payload")
  assert_eq "test_11f_llm_short_prompt_skipped: short prompt skips LLM" "" "$(echo "$out" | jq -er '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)"
}

run_test_12_cache_eviction() {
  rm -f "$HOME/.claude/cache/effort-suggest.llm-cache.json"
  rm -f "$HOME/.claude/cache/effort-suggest.state"
  local fixture_dir="/tmp/effort-suggest-evict-$$"
  mkdir -p "$fixture_dir/.claude"
  echo '{"llm": {"cache_max_entries": 10}}' > "$fixture_dir/.claude/effort-suggest.json"
  local i prompt payload
  for i in $(seq 1 15); do
    prompt="please tidy up snippet number $i in this file with care"
    payload=$(jq -n --arg cwd "$fixture_dir" --arg p "$prompt" '{
      session_id: "sess-evict",
      cwd: $cwd,
      hook_event_name: "UserPromptSubmit",
      prompt: $p
    }')
    echo "$payload" | env -u EFFORT_SUGGEST_LLM_OFF EFFORT_SUGGEST_CURRENT=high PATH="$FIXTURES_DIR/fake-claude-low:$PATH" "$SCRIPT" >/dev/null 2>&1
  done
  rm -rf "$fixture_dir"
  local count
  count=$(jq '.entries | length' "$HOME/.claude/cache/effort-suggest.llm-cache.json" 2>/dev/null)
  if [ "$count" -le 10 ] && [ "$count" -ge 9 ]; then
    echo "PASS: test_12_cache_eviction (count=$count, expected 9-10)"
    PASS=$((PASS + 1))
  else
    echo "FAIL: test_12_cache_eviction (count=$count)"
    FAIL=$((FAIL + 1))
  fi
}

run_test_1_smoke
run_test_3a_short_prompt
run_test_3b_off_env
run_test_3c_no_suggest_marker
run_test_4a_low_tier
run_test_4b_high_tier
run_test_4c_xhigh_tier
run_test_4d_no_match
run_test_5_current_eq_suggested
run_test_6_cooldown
run_test_7_session_reset
run_test_8_project_override
run_test_9a_malformed_project_config
run_test_9b_error_log_written
run_test_10a_summarize_low
run_test_10b_redesign_high
run_test_10c_system_design_xhigh
run_test_10d_explain_file_low
run_test_11a_llm_returns_low
run_test_11b_llm_cache_hit
run_test_11c_llm_returns_none
run_test_11d_llm_returns_garbage
run_test_11e_llm_timeout
run_test_11f_llm_short_prompt_skipped
run_test_12_cache_eviction

echo "---"
echo "PASS: $PASS   FAIL: $FAIL"
[ "$FAIL" -eq 0 ]
