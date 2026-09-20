# Wiring proctor up to Copilot CLI (`copilot`)

agent-proctor is a passive tool: it reads the ledger
(`~/.local/state/proctor/state.json`) and displays it. The thing that writes state
into that ledger is your agent's hooks. **Without wiring it up, the list stays
empty.**

How to wire it up depends on your setup. If you already use hooks or a statusLine
they have to be merged rather than replaced, and a procedure or a script cannot
cover every existing configuration. So this is written as **instructions for an
AI to follow** — hand it to the agent it is about, or let the agent run
`proctor setup <agent>` and read it itself.

Copilot CLI has both lifecycle hooks and a statusLine, so most of what proctor
shows can reach it. Three things are worth knowing before you start, and two of
them are things that cannot.

What follows was read off Copilot CLI 1.0.83.

- **Every event comes in two spellings, and only one of them is usable.** Naming
  an event in camelCase (`sessionStart`) gets you Copilot's own payload;
  naming it in PascalCase (`SessionStart`) gets you the VS Code compatible
  payload, which is the shape Claude Code uses — `session_id`, `cwd`,
  `hook_event_name`, `tool_name`, `agent_id`. That is the one proctor reads, so
  the table below is in PascalCase wherever a PascalCase spelling exists.
- **Nothing reports that a session is waiting on you.** `PermissionRequest`
  fires before the permission rules engine runs, on every tool decision,
  including the ones that are auto-approved and never reach you, so it says
  nothing about whether you are being asked. And not one of the kinds
  `notification` can carry means *you are being asked right now* — as of 1.0.83
  the eight of them are `agent_completed`, `agent_idle`, `shell_completed`,
  `shell_detached_completed`, `new_inbox_message`, `instruction_discovered`,
  `factory_completed` and `unclassified`. So neither is wired below, and a
  Copilot row never shows *waiting*.
- **The rate limits cannot be read.** Copilot bills in AI credits, and neither
  the hooks nor the statusLine carry how much of a window has been spent, so
  proctor leaves that column empty for Copilot rows. There is nothing to
  configure for this.

### Setup prompt for Copilot CLI

Paste the following into Copilot CLI as-is.

---

```
Please set up my Copilot CLI configuration so that it works with proctor
(https://github.com/syarihu/agent-proctor).

## Check first

Confirm that `~/bin/proctor`, or `proctor` on PATH, can be executed. If it cannot,
agent-proctor is not installed — stop there and tell me.

## What to do

Put the hooks in `~/.copilot/hooks/proctor.json` and the statusLine in
`~/.copilot/settings.json`. **Do not remove any existing configuration.** If
another hook is already registered for the same event, keep both by appending to
the array. Do not touch `~/.copilot/config.json`: it says in its own header that
it is managed automatically, and user settings belong in `settings.json`.

| Event | Command | Meaning |
| --- | --- | --- |
| `SessionStart` | `proctor _touch idle` | a session opened here (also on `--resume`) |
| `UserPromptSubmit` | `proctor _touch running` | started working |
| `PostToolUse` | `proctor _touch running` | a tool succeeded, back to running |
| `PostToolUseFailure` | `proctor _touch running` | a tool failed, back to running |
| `Stop` | `proctor _touch done` | the turn finished |
| `SessionEnd` | `proctor _touch clear` | the session ended |
| `subagentStart` | `proctor _subagent start` | a subagent started |
| `SubagentStop` | `proctor _subagent stop` | a subagent stopped |

`subagentStart` is the one spelled in camelCase. That is not a slip: Copilot
has no PascalCase spelling for it, so this is the only way to reach it.

Write each one as the absolute path where proctor actually lives — run
`command -v proctor` to find it, and use that; the examples below assume
`$HOME/bin/proctor`. Pass `--agent=copilot`, and throw the output away on every
event **except `UserPromptSubmit`** — that one is explained below. The hook
execution environment does not always have proctor's directory on PATH, and the
`[ -x ... ]` guard keeps it from running a binary that is no longer there:

    [ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch running --agent=copilot >/dev/null 2>&1

`UserPromptSubmit` gets the same line without the redirect:

    [ -x "$HOME/bin/proctor" ] && "$HOME/bin/proctor" _touch running --agent=copilot

So `~/.copilot/hooks/proctor.json` looks like this (one entry shown — note that
this is `PostToolUse`, one of the events that *does* get the redirect):

    {
      "version": 1,
      "hooks": {
        "PostToolUse": [
          {
            "type": "command",
            "bash": "[ -x \"$HOME/bin/proctor\" ] && \"$HOME/bin/proctor\" _touch running --agent=copilot >/dev/null 2>&1",
            "timeoutSec": 10
          }
        ]
      }
    }

### Why each one is there (do not drop them)

- **Why `--agent=copilot`**: Copilot's PascalCase payload is shaped exactly like
  Claude Code's — same `session_id`, same `cwd`, same `tool_name` — so the JSON
  alone cannot say which one it is. Without this flag every Copilot session shows
  up as Claude Code.
- **Why the event names are PascalCase**: the camelCase spelling of the same
  event sends Copilot's own payload, where the session is `sessionId` and the
  tool is `toolName`. proctor reads the VS Code compatible names, so a camelCase
  hook records nothing useful. Where no PascalCase spelling exists —
  `subagentStart` — proctor reads the camelCase keys instead.
- **Why the output is thrown away**: several of these events read what a hook
  prints as an instruction — `Stop` can refuse to end the turn. proctor prints
  the status it recorded, which is meant for a terminal, not for Copilot.
- **Why `UserPromptSubmit` is the exception**: while a session still has no name
  in the sidebar, proctor answers that one event with a `hookSpecificOutput`
  asking that `proctor title "<name>"` be run, and redirecting the hook's stdout
  throws that request away. Copilot's hook layer knows the `hookSpecificOutput`
  key, so it should arrive the same way it does in Claude Code — that end of it
  has not been watched happen, but keeping the output costs nothing if it turns
  out to be ignored, and losing it is certain if you redirect.
- **Why neither `PermissionRequest` nor `notification` is in the table**:
  neither can tell you that a session is blocked on you. `PermissionRequest`
  fires on every tool decision, including the auto-approved ones you never see.
  No kind `notification` can carry means that you are the one being waited on —
  wiring it would knock a session into *waiting* because a background shell
  returned, and never once because you were actually asked. Leaving both out
  costs nothing that was working.
- **Why `PostToolUse` is included**: it is what keeps a long turn looking alive
  between the prompt and the `Stop`, and it is what puts the tool being run on the
  row. It fires very often, but proctor discards writes that would not change
  anything, so it costs nothing.
- **Why `PostToolUseFailure` is included**: `PostToolUse` fires only after a tool
  *succeeds*. Without this one, a turn whose last tool call failed keeps the row
  showing whatever the previous event left there until the turn ends.
- **Why `SessionEnd`, `subagentStart` and `SubagentStop` must be synchronous**:
  if you background them, they can be killed along with the process before they
  finish writing (and a missed `SubagentStop` leaves the subagent lingering in
  the list). Other events may be backgrounded with a trailing `&`, but keep these
  lifecycle events synchronous.

### statusLine

The session name and the context usage are not available to hooks — they only
reach the statusLine. proctor wants to show them, so pass them along from there.
Copilot hands the statusLine command the same JSON keys Claude Code does
(`session_id`, `session_name`, `model.display_name`, `context_window`), so
`proctor _stats` reads it without any translation.

- **If you do not use a statusLine yet**: add this to `~/.copilot/settings.json`,
  keeping whatever is already in that file.

      {
        "statusLine": {
          "type": "command",
          "command": "[ -x \"$HOME/bin/proctor\" ] && \"$HOME/bin/proctor\" _stats --agent=copilot"
        }
      }

- **If you already use a statusLine**: do not break the existing display. stdin
  can only be read once, so read the JSON to completion inside your existing
  script and hand the same content to `proctor _stats --agent=copilot` as well —
  **the flag matters here as much as in the example above**, because the
  statusLine payload hands over the session-state directory rather than the
  transcript file, and a `_stats` that cannot tell which agent it is looking at
  writes its guess back over the row on every render. Swallow any failure so the
  display never stops. It is called on every render, but proctor
  does not write when nothing changed, so the ledger's modification time stays put.
  Check while you are in there that `footer.showCustom` in
  `~/.copilot/settings.json` is not set to `false`: the command still runs when
  it is, but nothing is drawn, so you would not see that your existing display
  had stopped.

`proctor _stats` prints nothing of its own, so a statusLine that only calls it
draws an empty line. That is expected — it is there to feed proctor, not the
footer.

## Verify

Start a new Copilot CLI session and run `proctor ls` to confirm that the session
shows up in the list. If it does not, the configuration is not taking effect.

`proctor _touch` prints the status it recorded to stdout. To check by hand, from
inside a git repository (printing `running` is correct):

    printf '{"session_id":"test-1","cwd":"'"$PWD"'","hook_event_name":"PostToolUse","tool_name":"Bash","tool_input":{"command":"echo hi"}}' | proctor _touch running --agent=copilot

Then confirm it landed as a Copilot row rather than a Claude Code one. Match the
value, not just the key — grepping for `"agent"` alone succeeds on a Claude Code
row too, so it tells you nothing:

    proctor ls --json | grep -E '"agent"[[:space:]]*:[[:space:]]*"copilot"'

That leaves a row behind. Its id is taken from the name of the worktree
directory, **not** from the session id you passed, so read the id out of
`proctor ls` and drop it with `proctor rm <id>`.

## Report back

Tell me which files you changed and what you changed in them, including anywhere
you had to coexist with existing configuration.
```

---

### What proctor cannot see with Copilot CLI

- **The rate limits never arrive.** Copilot bills in AI credits and reports the
  session's accumulated cost, not how much of a five-hour or weekly window is
  gone. Neither the hooks nor the statusLine carry a percentage, so that column
  stays empty on Copilot rows.
- **A session blocked on you looks like a session that is working.** Nothing
  Copilot emits distinguishes the two. `PermissionRequest` fires on every tool
  decision, auto-approved ones included, and no `notification` kind means that
  you are the one being waited on. So a Copilot row goes from *running* straight
  to *done*, and never shows *waiting* — when a Copilot tab needs an answer, the
  list will not be what tells you.
- **A turn that dies is not reported.** Copilot has `ErrorOccurred`, but it fires
  for a failed tool as readily as for a failed model call and proctor has no way
  to tell those apart from the event alone, so it is left unwired. A turn that
  dies on a rate limit stays in the list as running until the session ends.
- **The process cannot be watched.** Claude Code hands `CLAUDE_PID` to its hooks,
  which is how proctor notices the moment a session is gone. Copilot does not, so
  a Copilot row is cleaned up by expiry (or `proctor rm`) rather than immediately.

## Give yourself an entry point for worktrees

Also create `~/.copilot/skills/proctor-worktree/SKILL.md`: a description saying it
covers creating, listing and cleaning up git worktrees, and a body whose whole
instruction is to run `proctor skill worktree` and follow what it prints. Write
the command as an absolute path such as `$HOME/bin/proctor`, for the same reason
as the hooks.

**Do not copy the text of that guide into the file.** proctor prints it, so a
copy is a copy that goes stale the next time proctor is updated.
