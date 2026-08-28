# Wiring proctor up to any other agent

agent-proctor is a passive tool: it reads the ledger
(`~/.local/state/proctor/state.json`) and displays it. The thing that writes state
into that ledger is your agent's hooks. **Without wiring it up, the list stays
empty.**

How to wire it up depends on your setup. If you already use hooks or a statusLine
they have to be merged rather than replaced, and a procedure or a script cannot
cover every existing configuration. So this is written as **instructions for an
AI to follow** — hand it to the agent it is about, or let the agent run
`proctor setup <agent>` and read it itself.

`_touch`, `_subagent` and `_stats` all just read JSON from stdin, so any tool with
similar lifecycle hooks can be wired up the same way. Besides `session_id`, the
session identifier is also read from `conversationId` and `conversation_id`
(for Antigravity). Which agent a session belongs to can be stated outright with
`--agent=<name>` on any of the three.

If the agent has a hook for permission prompts, pass `_touch waiting` the
payload with `tool_name` and `tool_input` still in it: proctor puts together the
same label it uses for tool activity ("Bash: rm -rf build") and shows it as what
the session is waiting on. Without those fields it falls back to `message`, which
usually names the tool at best.

If your hook script already does something else with the same event — colouring
the terminal tab, for instance — remember that stdin can only be read once. Read
the JSON to completion first, then hand the same content to `proctor`.

If wiring it up means writing a script file — something to pass the statusline
JSON along, or an existing hook script that has to be extended — look at where
the scripts already registered in that agent's configuration live, and put it in
the same place. The layout that is already on the machine beats any layout this
document could name. With nothing to follow, fall back to
`<the agent's config directory>/hooks/<bundle id or identifier of whatever the script belongs to>/<script>`.
Naming the directory after the owner says who put the script there, and it makes
removing that tool later one directory plus the entries that point at it.
