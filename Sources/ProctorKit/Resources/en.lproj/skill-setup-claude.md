# Wiring proctor up to Claude Code

agent-proctor is a passive tool: it reads the ledger
(`~/.local/state/proctor/state.json`) and displays it. The thing that writes state
into that ledger is your agent's hooks. **Without wiring it up, the list stays
empty.**

How to wire it up depends on your setup. If you already use hooks or a statusLine
they have to be merged rather than replaced, and a procedure or a script cannot
cover every existing configuration. So this is written as **instructions for an
AI to follow** — hand it to the agent it is about, or let the agent run
`proctor skill <name>` and read it itself.

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
| `SessionStart` | none | `proctor _touch idle` | a session opened here (also on `--resume`) |
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

`SessionStart` is what puts a resumed session on the list before it has done
anything. Without it, nothing is recorded until the first prompt, and until then
the worktree it is sitting in looks like nobody is there. It fires on compaction
and `/clear` as well, so proctor uses `idle` **only to register a session it has
never seen** — an `idle` for a session already on the list changes nothing, and a
running session cannot be knocked back by it.

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
- **Why `SessionEnd`, `SubagentStart`, and `SubagentStop` must be synchronous**:
  if you background them, they can be killed along with the process before they
  finish writing (and a missed `SubagentStop` leaves the subagent lingering in
  the list). Other events may be backgrounded with a trailing `&`, but keep
  these lifecycle events synchronous.

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

## Give yourself an entry point for worktrees

Also create `~/.claude/skills/proctor-worktree/SKILL.md`: a description saying it
covers creating, listing and cleaning up git worktrees, and a body whose whole
instruction is to run `proctor skill worktree` and follow what it prints.

**Do not copy the text of that guide into the file.** proctor prints it, so a
copy is a copy that goes stale the next time proctor is updated.

You do not have to set this up at all: typing `! proctor skill worktree` in a
conversation runs it right there and drops the guide into the context.
