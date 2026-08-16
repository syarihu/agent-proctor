# Wiring proctor up to Claude Code

*[日本語版はこちら](setup-prompt.ja.md)*

agent-proctor is a passive tool: it reads the ledger
(`~/.local/state/proctor/state.json`) and displays it. The thing that writes state
into that ledger is your Claude Code hooks. **Without wiring it up, the list stays
empty.**

How to wire it up depends on your setup. If you already use hooks or a statusLine
they have to be merged rather than replaced, and a procedure or a script cannot
cover every existing configuration. So this is written as **instructions for an
AI to follow**.

## How to use it

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
| `SessionEnd` | none | `proctor _touch clear` | the session ended |
| `PreToolUse` | `Task\|Agent` | `proctor _subagent start` | a subagent started |
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

## Other agents

`_touch`, `_subagent` and `_stats` all just read JSON from stdin, so any tool with
similar lifecycle hooks can be wired up the same way. Besides `session_id`, the
session identifier is also read from `conversationId` and `conversation_id`
(for Antigravity).

If your hook script already does something else with the same event — colouring
the terminal tab, for instance — remember that stdin can only be read once. Read
the JSON to completion first, then hand the same content to `proctor`.
