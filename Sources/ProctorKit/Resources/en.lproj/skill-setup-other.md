# Wiring proctor up to any other agent

agent-proctor is a passive tool: it reads the ledger
(`~/.local/state/proctor/state.json`) and displays it. The thing that writes state
into that ledger is your agent's hooks. **Without wiring it up, the list stays
empty.**

How to wire it up depends on your setup. If you already use hooks or a statusLine
they have to be merged rather than replaced, and a procedure or a script cannot
cover every existing configuration. So this is written as **instructions for an
AI to follow** — hand it to the agent it is about, or let the agent run
`proctor skill <name>` and read it itself.

`_touch`, `_subagent` and `_stats` all just read JSON from stdin, so any tool with
similar lifecycle hooks can be wired up the same way. Besides `session_id`, the
session identifier is also read from `conversationId` and `conversation_id`
(for Antigravity). Which agent a session belongs to can be stated outright with
`--agent=<name>` on any of the three.

If your hook script already does something else with the same event — colouring
the terminal tab, for instance — remember that stdin can only be read once. Read
the JSON to completion first, then hand the same content to `proctor`.
