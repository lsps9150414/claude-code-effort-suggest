# claude-code-effort-suggest

A `UserPromptSubmit` hook for [Claude Code](https://claude.com/claude-code) that nudges you to switch the session's `effortLevel` when the upcoming prompt's task type doesn't match the current setting.

Catches the common tax of running trivial lookups on `xhigh` (slow, expensive) or architecture decisions on `low` (under-thinking).

## How it works

```
You type a prompt
     ↓
Hook fires (UserPromptSubmit)
     ↓
Regex classifies into low / high / xhigh / (none)
     ↓ regex miss
LLM fallback (Haiku via `claude -p --bare`) — cached, 4s timeout
     ↓
Compare to current effortLevel
     ↓ different
Inject hint: "⚡ [effort-suggest] Current: high. Suggest: low. Run /effort low to switch."
```

The model receives the hint as `additionalContext` and is instructed to echo it as the first line of its reply, so you see it inline.

Always exits 0. Non-blocking. Degrades silent on every error path. Cache + cooldown prevent suggestion spam.

## Install

```bash
git clone https://github.com/lsps9150414/claude-code-effort-suggest.git
cd claude-code-effort-suggest
./install.sh
```

Restart any open Claude Code sessions. The hook fires automatically on every prompt.

**Requirements:**
- macOS or Linux with `bash` 3.2+, `jq`, `perl`, `shasum`
- For LLM fallback: [Claude Code CLI](https://claude.com/claude-code) installed (`claude` command on `$PATH`)

## Tiers

| Tier | Typical work | Example prompts |
|---|---|---|
| `low` | Trivial, read-only, summaries, lint fixes | `summarize @foo.md`, `fix the typo`, `rename this var` |
| `(none)` | Standard coding (medium baseline — silent) | `add this feature`, `write tests for X` |
| `high` | Refactors, debugging, code review, migrations | `refactor the auth middleware`, `debug this race condition` |
| `xhigh` | Architecture, security audits, perf root cause | `design the system for ...`, `architecture review` |

Default config has ~43 patterns across these tiers. Tunable per-project; LLM fallback handles the long tail.

## Suppression

| Mechanism | Effect |
|---|---|
| `EFFORT_SUGGEST_OFF=1` env | Disable hook entirely |
| `EFFORT_SUGGEST_LLM_OFF=1` env | Regex-only mode, skip LLM fallback |
| `[no-suggest]` token in prompt | Skip per-prompt |
| Prompt < 20 chars | Auto-skip (catches "yes", "continue") |
| Cooldown (5 min default) | Don't nudge twice for same suggestion in window |

## Configuration

Default at `~/.claude/effort-suggest.json`:

```json
{
  "tiers": {
    "xhigh": ["\\b(architecture|architectural)\\b", "..."],
    "high":  ["\\brefactor\\b", "..."],
    "low":   ["\\btypo\\b", "\\bsummariz(e|ing|ed)\\b", "..."]
  },
  "cooldown_seconds": 300,
  "min_prompt_length": 20,
  "llm": {
    "enabled": true,
    "min_prompt_length": 30,
    "timeout_seconds": 4,
    "model": "claude-haiku-4-5-20251001",
    "cache_max_entries": 1000
  }
}
```

### Per-project overrides

Drop a `<project>/.claude/effort-suggest.json` to add patterns. Tier arrays are **appended** to defaults; `cooldown_seconds`, `min_prompt_length`, and `llm.*` scalars override.

```json
{
  "tiers": {
    "high": ["\\bmy-repo-specific-pattern\\b"]
  },
  "llm": {
    "enabled": false
  }
}
```

## Files installed

```
~/.claude/
├── hooks/
│   └── effort-suggest.sh                   # main hook
├── effort-suggest.json                      # default config
├── settings.json                            # UserPromptSubmit registration added
└── cache/                                   # runtime (auto-created)
    ├── effort-suggest.state                 # cooldown state
    ├── effort-suggest.llm-cache.json        # LLM tier cache (LRU bounded)
    └── effort-suggest.error.log             # silent-degrade log
```

## Tests

```bash
./test/test-effort-suggest.sh
# Expect: PASS: 27   FAIL: 0
```

27 fixture tests cover suppression, tier hits, comparison, cooldown, session reset, project merge, malformed config, LLM mock paths (cache hit/miss/timeout/garbage/short-skip), and cache eviction. Mock `claude` CLI scripts under `test/fixtures/*/claude` make tests deterministic and offline.

## Manual smoke

```bash
# Regex hit (low tier, no LLM)
echo '{"session_id":"m1","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"summarize @foo.md please"}' \
  | EFFORT_SUGGEST_CURRENT=high ~/.claude/hooks/effort-suggest.sh | jq -r '.hookSpecificOutput.additionalContext'

# LLM fallback (real Haiku call, ~1-3s, then cached)
rm -f ~/.claude/cache/effort-suggest.llm-cache.json
echo '{"session_id":"m2","cwd":"/tmp","hook_event_name":"UserPromptSubmit","prompt":"please tidy up the variable names in this snippet of code"}' \
  | env -u EFFORT_SUGGEST_LLM_OFF EFFORT_SUGGEST_CURRENT=high ~/.claude/hooks/effort-suggest.sh | jq -r '.hookSpecificOutput.additionalContext'
```

## Architecture notes

- **Hot path** (regex hit): ~50ms.
- **Cold path** (regex miss + LLM): 1-3s on first call, ~50ms on cache hit.
- **`claude -p --bare`** invocation skips hooks/LSP/plugin sync — prevents recursion and keeps cold-start fast.
- **Hash-cache** keyed by SHA-256 of normalized prompt (lowercase, collapsed whitespace).
- **LRU eviction** at 90% of `cache_max_entries` (default keeps last 900 of 1000).
- **Timeout** via `perl -e 'alarm shift; exec @ARGV'` — portable across macOS (no `timeout` by default) and Linux.

## Uninstall

```bash
rm ~/.claude/hooks/effort-suggest.sh
rm ~/.claude/effort-suggest.json
rm ~/.claude/cache/effort-suggest.{state,llm-cache.json,error.log}
jq 'del(.hooks.UserPromptSubmit)' ~/.claude/settings.json > /tmp/s && mv /tmp/s ~/.claude/settings.json
```

## License

MIT — see [LICENSE](LICENSE).
