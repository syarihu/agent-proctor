# Wiring proctor up to Codex (`codex`)

agent-proctor is a passive tool: it reads the ledger
(`~/.local/state/proctor/state.json`) and displays it. The thing that writes state
into that ledger is your agent's hooks. **Without wiring it up, the list stays
empty.**

How to wire it up depends on your setup. If you already use hooks or a statusLine
they have to be merged rather than replaced, and a procedure or a script cannot
cover every existing configuration. So this is written as **instructions for an
AI to follow** — hand it to the agent it is about, or let the agent run
`proctor setup <agent>` and read it itself.

Codex reads lifecycle hooks from `~/.codex/hooks.json`, in the same shape Claude
Code uses. Two things are different.

- **There is no statusLine to hand anything to.** Of the things proctor shows,
  only the model reaches a hook; the session name, the context usage and the rate
  limits never do. proctor reads those out of what Codex already keeps for itself:
  the name from the `threads` table in `~/.codex/state_<n>.sqlite`, and the context
  usage and rate limits from the rollout JSONL under `~/.codex/sessions/`.
  There is nothing to configure for this.
- **Codex asks before it trusts a hook.** It records a hash of every hook command
  it has been told to trust (`[hooks.state]` in `~/.codex/config.toml`), so the
  first session after you edit `hooks.json` asks you to approve the new commands.
  Until you do, they do not run. Start one session by hand after wiring it up.

### Setup prompt for Codex

Paste the following into Codex as-is.

---

```
Please set up my Codex configuration so that it works with proctor
(https://github.com/syarihu/agent-proctor).

## Check first

Confirm that `~/bin/proctor`, or `proctor` on PATH, can be executed. If it cannot,
agent-proctor is not installed — stop there and tell me.

## What to do

Add the following hooks to `~/.codex/hooks.json`. **Do not remove any existing
configuration.** If another hook is already registered for the same event, keep
both by appending to the array.

| Event | Command | Meaning |
| --- | --- | --- |
| `SessionStart` | `proctor _touch idle` | a session opened here (also on resume) |
| `UserPromptSubmit` | `proctor _touch running` | started working |
| `PostToolUse` | `proctor _touch running` | back to running |
| `PermissionRequest` | `proctor _touch waiting` | waiting for my answer |
| `Stop` | `proctor _touch done` | the turn finished |
| `SessionEnd` | `proctor _touch clear` | the session ended |
| `SubagentStart` | `proctor _subagent start` | a subagent started |
| `SubagentStop` | `proctor _subagent stop` | a subagent stopped |

Write each one as the absolute path where proctor actually lives — run
`command -v proctor` to find it, and use that; the examples below assume
`$HOME/bin/proctor`. Pass `--agent=codex`, and throw the output away. The hook
execution environment does not always have proctor's directory on PATH, and the
`[ -x ... ]` guard keeps it from running a binary that is no longer there:

    [ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch running --agent=codex >/dev/null 2>&1

So one entry looks like this:

    {
      "hooks": {
        "UserPromptSubmit": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "[ -x \"$HOME/bin/proctor\" ] && \"$HOME/bin/proctor\" _touch running --agent=codex >/dev/null 2>&1",
                "timeout": 10
              }
            ]
          }
        ]
      }
    }

### Why each one is there (do not drop them)

- **Why `--agent=codex`**: Codex sends a payload shaped almost exactly like Claude
  Code's — same `session_id`, same `cwd`, same `tool_name` — so the JSON alone does
  not always say which one it is. proctor falls back to looking at where the
  transcript lives, but saying it outright is what reliably makes the row read
  "Codex" instead of "Claude Code".
- **Why the output is thrown away**: Codex reads what a hook prints as its answer
  (approve or block, on `PermissionRequest`). proctor prints the status it
  recorded, which is meant for a terminal, not for Codex. The exit code is safe
  either way: Codex treats only **exit code 2** as a decision, and proctor exits 1
  on failure — so a proctor that is missing or broken can never deny a permission
  request, it just does not record anything.
- **Why `PermissionRequest` rather than a notification**: Codex has no event for
  idle notifications, and `PermissionRequest` fires exactly when it is waiting for
  your answer. So it maps straight to `waiting`, with nothing to tell apart.
- **Why `PostToolUse` is included**: it is the only path that reports going back
  to running after you have answered a permission prompt. It fires very often, but
  proctor discards writes that would not change anything, so it costs nothing.
- **Why `SessionEnd` must be synchronous**: if you background it, it can be killed
  along with Codex itself before it finishes writing. The other events may be
  backgrounded with a trailing `&`, but leave `SessionEnd` synchronous.

## Verify

Start a new Codex session. It will ask whether to trust the new hook commands —
approve them, or they never run. Then run `proctor ls` and confirm the session
shows up in the list.

## Report back

Tell me which files you changed and what you changed in them, including anywhere
you had to coexist with existing configuration.
```

---

### What proctor cannot see with Codex

- **A turn that dies is not reported.** Claude Code has `StopFailure` for a turn
  that dies on a rate limit or an overloaded error; Codex has no equivalent, so
  such a session stays in the list as running until the session ends.
- **The process cannot be watched.** Claude Code hands `CLAUDE_PID` to its hooks,
  which is how proctor notices the moment a session is gone. Codex does not, so a
  Codex row is cleaned up by expiry (or `proctor rm`) rather than immediately.

## Give yourself an entry point for worktrees

Also put one line in `~/.codex/AGENTS.md`: when worktrees come up, run
`proctor skill worktree` and follow what it prints. Write the command as an
absolute path such as `$HOME/bin/proctor`, for the same reason as the hooks.

**Do not copy the text of that guide into that file.** proctor prints it, so a
copy is a copy that goes stale the next time proctor is updated.
