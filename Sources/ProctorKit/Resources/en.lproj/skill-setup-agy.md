# Wiring proctor up to Antigravity (`agy`)

agent-proctor is a passive tool: it reads the ledger
(`~/.local/state/proctor/state.json`) and displays it. The thing that writes state
into that ledger is your agent's hooks. **Without wiring it up, the list stays
empty.**

How to wire it up depends on your setup. If you already use hooks or a statusLine
they have to be merged rather than replaced, and a procedure or a script cannot
cover every existing configuration. So this is written as **instructions for an
AI to follow** — hand it to the agent it is about, or let the agent run
`proctor skill <name>` and read it itself.

Antigravity uses `hooks.json` (placed in `~/.gemini/config/hooks.json` or `.agents/hooks.json`) and statusline configured in `~/.gemini/antigravity-cli/settings.json`.

Session titles for Antigravity are resolved automatically in the following priority order:
1. AI-generated conversation summary title from `~/.gemini/antigravity-cli/conversation_summaries.db`
2. H1 heading of artifact files (e.g. Plan / Task markdown in `brain/<conversationId>/`)
3. The first non-empty line of the user's initial prompt from `transcript.jsonl`

### Setup prompt for Antigravity

Paste the following into Antigravity (or `agy`) as-is.

```
Please set up my Antigravity / agy configuration so that it works with proctor
(https://github.com/syarihu/agent-proctor).

## Check first

Confirm that `~/bin/proctor`, or `proctor` on PATH, can be executed. If it cannot,
agent-proctor is not installed — stop there and tell me.

## What to do

1. Add lifecycle hooks to `~/.gemini/config/hooks.json` (or `.agents/hooks.json`).
   Antigravity hooks expect JSON on stdout, so pass the `--json` flag to `proctor _touch`.

| Event | Matcher | Command | Meaning |
| --- | --- | --- | --- |
| `PostToolUse` | `*` | `[ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch running --json` | back to running |
| `PreToolUse` | `ask_question` | `[ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch waiting --json` | waiting for user response |
| `PreToolUse` | `invoke_subagent` | `[ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _subagent start` | a subagent started |
| `Stop` | none | `[ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch done --json` | the turn finished |

2. If using statusline in `~/.gemini/antigravity-cli/settings.json`, pass the stdin JSON to `proctor _stats`:
   ```python
   # Inside statusline script:
   try:
       proctor = os.path.expanduser('~/bin/proctor')
       if os.access(proctor, os.X_OK):
           subprocess.run([proctor, '_stats'], input=raw, text=True,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                          timeout=2)
   except Exception:
       pass
   ```
```

## Give yourself an entry point for worktrees

Also put one line in the instructions file you already read at startup: when
worktrees come up, run `proctor skill worktree` and follow what it prints.

**Do not copy the text of that guide into that file.** proctor prints it, so a
copy is a copy that goes stale the next time proctor is updated.
