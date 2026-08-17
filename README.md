# agent-proctor

*[日本語版はこちら](README.ja.md)*

A Mac app and CLI that acts as your **proctor**, watching over every coding agent
at work across your git worktrees and telling you the moment one raises its hand.

A proctor does not sit the exam. They watch the room, and they go to whoever
raises a hand. That is exactly the job here: instead of checking tabs one by one,
you see which session is blocked waiting for you and which one is still working
in the background.

```
⏳ Fix the empty state of the sidebar  (context: 13%)
   develop · elapsed: 59s
▶ Split the kit into layers  (context: 32%)
   main · elapsed: 1m  🤖2              +74 -3 ?2
```

The session name, context usage and subagent count are things a tab cannot tell
you. `elapsed` is the time since the status last changed — if something has been
running for a long time, that is a hint that it is either thinking hard or stuck.

## Structure

`ProctorKit` is split into three layers so that the logic can be used from both
the CLI and the app. The boundary rule is that **presentation concerns never
enter the Kit**: terminal ANSI colors live in the CLI (`Terminal.swift`) and
SwiftUI colors live in the app (`Palette`). All the Kit knows is which statuses
exist and what symbol and name to call them by.

```
ProctorKit/
  Model/       Data and vocabulary. No I/O
               TaskRecord, DiffCounts, CollectedTask, TaskStatus, TaskID
  Repository/  The only door to the outside: the ledger, git and the environment
               LedgerStore, GitClient, ProcessRunner, EnvironmentSource, Paths
  UseCase/     One per thing you want to do. Every decision lives here
               CollectTasks, RecordHookEvent, RecordSessionStats,
               ReapClosedSessions, HookPayload

proctor/       CLI (view). Reads arguments, calls a use case, formats for a terminal
ProctorApp/    App (view). SwiftUI and AppKit. TaskStore wraps the repository
```

| File | Role |
| --- | --- |
| `~/.local/state/proctor/state.json` | The ledger. One across all repositories. Created on first use |

### Invariants

- **Aggregation only happens in `CollectTasks.run()`.** Both the CLI table and
  the sidebar just format its return value, so no logic leaks into the views.
  When you need another number, add it there
- **Views never touch the repository directly.** In the app, `TaskStore` wraps
  the ledger and both the menu and the open action go through it, so a change in
  how the ledger is read only has to be made in one place
- **The ledger is guarded by an exclusive lock (`LedgerStore.withLock`) and is
  not written when nothing changed.** The ledger's modification time is the
  signal the sidebar watches, so touching it without a change makes it recount
  by spawning git every time. Hooks fire constantly and most of them change
  nothing, which is exactly why this matters
- **`ls --json` emits keys in sorted order.** Swift dictionaries are ordered per
  process, so without this the same content comes out in a different order on
  every run. This output is diffed by AI and other tools, so it must be stable

### Checking behaviour

`scripts/baseline.sh` runs the main commands and writes their output to a file.
Compare before and after a change to confirm nothing broke.

```bash
scripts/baseline.sh before
scripts/baseline.sh after
diff -u /tmp/proctor-baseline/{before,after}.txt
```

It works against a throwaway git repository and ledger, so your real ledger is
never touched.

## Install

```bash
scripts/create-signing-cert.sh   # once. Creates a local code signing certificate
scripts/install.sh               # installs to /Applications and links ~/bin/proctor
```

The certificate comes first because Automation (Apple Events) permission is tied
to the pair of bundle identifier and code signature. With an ad-hoc signature the
signature changes on every build, so macOS asks you to approve controlling iTerm2
again each time.

On first launch macOS asks for permission to control iTerm2 — allow it.
Turn on *Launch at login* in the menu bar and it will start on its own from then on.

## Usage

```bash
proctor ls              # list (--all for every repository, --json for machines)
proctor attach <id>     # open the agent (claude / agy) for that session, resuming the conversation
proctor sidebar         # launch the sidebar app
```

That is the whole surface. **agent-proctor never creates or removes a worktree**
— setting one up and cleaning it up afterwards belongs to whatever drives your
agents (a slash command or skill, in the author's case). It reads nothing but
the ledger and `git diff`, and writes nothing but the ledger.

Sessions appear on their own as soon as your hooks report them; there is nothing
to register by hand. Clicking a row in the sidebar focuses that tab if it is
still alive, and otherwise opens a new tab resuming the conversation.

## Wiring up your agent

**Installing it is not enough — the list stays empty.** agent-proctor is a passive tool
that reads the ledger and displays it; the thing that writes state into the ledger
is your agent hooks (Claude Code or Antigravity).

How to wire it up depends on your setup (if you already use hooks or a statusLine,
they have to be merged rather than replaced), so instead of a procedure this is
written as **instructions to hand to an AI**.

→ paste [docs/setup-prompt.md](docs/setup-prompt.md) into Claude Code or Antigravity

Hooks call these three. They are not meant to be typed by a person, so they are
not listed in the help. All of them read the hook JSON from stdin.

| Command | Caller | Purpose |
| --- | --- | --- |
| `proctor _touch <status>` | hooks | running / waiting / done / failed / clear / notification |
| `proctor _subagent start\|stop` | hooks | subagent count |
| `proctor _stats` | statusline | session name, model, context usage |

`_touch` **prints the status it recorded to stdout** so the caller can use what
actually happened (to set a tab color, for example).

`notification` is the special one: proctor looks at the payload's `message` and
decides whether it is a permission prompt or the *no input for 60 seconds* idle
notification. For an idle notification it records nothing and prints nothing.
Treating both as waiting would mark a session as blocked just because you walked
away after it finished. Copying that decision into the caller means the two can
drift apart when only one is fixed.

Every session in the list got there through `_touch` — whether you opened it in a
worktree or straight in the repository. agent-proctor has no other way of learning
that an agent exists, which is why wiring the hooks up is not optional.

## iTerm2 integration

Focusing a tab and opening a new one are done through AppleScript.
`id of session` is the same value as the part of `ITERM_SESSION_ID` after the `:`
(both are the PTYSession guid), so keeping it in the ledger is enough to match them.

Under the hardened runtime the `com.apple.security.automation.apple-events`
entitlement is required. Without it Apple Events are blocked by the runtime before
they reach TCC, which means proctor never even appears in the Automation list in
System Settings.

The sidebar positions itself by reading iTerm2's window frame from CGWindowList.
That needs no Automation permission, so snapping works even before you grant it.

## Dependencies

`git`, and nothing else. There are no external Swift package dependencies.

## Contributing

See [CLAUDE.md](CLAUDE.md) for the conventions used in this repository
(English commit messages, Japanese code comments).
