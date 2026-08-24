# Wiring proctor up to your agent

*[日本語版はこちら](setup-prompt.ja.md)*

agent-proctor is a passive tool: it reads the ledger
(`~/.local/state/proctor/state.json`) and displays it. The thing that writes state
into that ledger is your agent's hooks. **Without wiring it up, the list stays
empty.**

How to wire it up depends on your setup. If you already use hooks or a statusLine
they have to be merged rather than replaced, and a procedure or a script cannot
cover every existing configuration. So this is written as **instructions for an
AI to follow**.

There is one section per agent — [Claude Code](#wiring-proctor-up-to-claude-code),
[Antigravity](#wiring-proctor-up-to-antigravity-agy) and
[Codex](#wiring-proctor-up-to-codex-codex). Read the one you use; they do not
depend on each other.

## Wiring proctor up to Claude Code

Paste the following into Claude Code as-is.

---

```
Please set up my Claude Code configuration so that it works with proctor
(https://github.com/syarihu/agent-proctor).

## Check first

Confirm that `~/bin/proctor`, or `proctor` on PATH, can be executed. If it cannot,
agent-proctor is not installed — stop there and tell me.

## What to do

Add the following hooks and statusLine to `~/.claude/settings.json`.
**Do not remove any existing configuration.** If another hook is already
registered for the same event, keep both by appending to the array.

Write the proctor command as an absolute path such as `$HOME/bin/proctor`.
The hook execution environment does not always have ~/bin on PATH, and relying on
PATH makes this silently fail here only. Also guard the call with
`[ -x "$HOME/bin/proctor" ] &&` so that Claude Code does not error out if proctor
is ever removed.

| Event | Matcher | Command | Meaning |
| --- | --- | --- | --- |
| `UserPromptSubmit` | none | `proctor _touch running` | started working |
| `PostToolUse` | `*` | `proctor _touch running` | back to running |
| `Notification` | none | `proctor _touch notification` | possibly waiting for me |
| `Stop` | none | `proctor _touch done` | the turn finished |
| `StopFailure` | none | `proctor _touch failed` | the turn died (rate limit, overloaded) |
| `SessionEnd` | none | `proctor _touch clear` | the session ended |
| `SubagentStart` | none | `proctor _subagent start` | a subagent started |
| `SubagentStop` | none | `proctor _subagent stop` | a subagent stopped |

Each of these needs the hook JSON passed through on stdin. Claude Code does this
by default, so you do not need to add any piping yourself.

### Why each one is there (do not drop them)

- **Why `PostToolUse` is included**: it is the only path that reports going back
  to running after a permission prompt was approved. Without it, a session that
  you approved keeps looking like it is still waiting for you. It fires very
  often, but proctor discards writes that would not change anything, so it costs
  nothing.
- **Why `Notification` passes `notification` rather than `waiting`**: this event
  also fires for the *no input for 60 seconds* idle notification, not just
  permission prompts. Treating both the same marks a session as blocked simply
  because you walked away after it finished. Passing `notification` lets proctor
  look at the message and tell them apart.
- **Why `StopFailure` is included**: when a turn dies on a rate limit or an
  overloaded error, `Stop` does not fire. Without this hook the session stays in
  the list as running and never settles.
- **Why `SubagentStart` rather than `PreToolUse` on `Task|Agent`**: only
  `SubagentStart` carries `agent_id`, the one thing that tells the subagents
  apart. `PreToolUse` fires on the main thread before the subagent exists, so it
  can only be counted, not listed. If you keep the old `PreToolUse` wiring as
  well nothing breaks — proctor trusts the listed subagents over the count — but
  it buys you nothing either.
- **Why `SessionEnd` must be synchronous**: if you background it, it can be
  killed along with Claude itself before it finishes writing. The other events
  may be backgrounded with a trailing `&`, but leave `SessionEnd` synchronous.

### statusLine

The session name, model and context usage are not available to hooks — they only
reach the statusLine. proctor wants to show them, so pass them along from there.

- **If you do not use a statusLine yet**: configure a command that simply passes
  the stdin JSON to `proctor _stats`.
- **If you already use a statusLine**: do not break the existing display. stdin
  can only be read once, so read the JSON to completion inside your existing
  script and hand the same content to `proctor _stats` as well. Swallow any
  failure so the display never stops. It is called on every render, but proctor
  does not write when nothing changed, so the ledger's modification time stays put.

## Verify

Once configured, open a new Claude Code session and run `proctor ls` to confirm
that the session shows up in the list. If it does not, the configuration is not
taking effect.

`proctor _touch` prints the status it recorded to stdout. To check by hand
(printing `waiting` is correct):

    printf '{"session_id":"test","cwd":"'"$PWD"'","message":"needs your permission"}' | proctor _touch notification

For the idle notification, printing nothing is the correct behaviour:

    printf '{"session_id":"test","cwd":"'"$PWD"'","message":"Claude is waiting for your input"}' | proctor _touch notification

## Report back

Tell me which files you changed and what you changed in them, including anywhere
you had to coexist with existing configuration.
```

---

---

## Wiring proctor up to Antigravity (`agy`)

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

---

---

## Wiring proctor up to Codex (`codex`)

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

## Other agents

`_touch`, `_subagent` and `_stats` all just read JSON from stdin, so any tool with
similar lifecycle hooks can be wired up the same way. Besides `session_id`, the
session identifier is also read from `conversationId` and `conversation_id`
(for Antigravity). Which agent a session belongs to can be stated outright with
`--agent=<name>` on any of the three.

If your hook script already does something else with the same event — colouring
the terminal tab, for instance — remember that stdin can only be read once. Read
the JSON to completion first, then hand the same content to `proctor`.
