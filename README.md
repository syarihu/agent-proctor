# taskhub

*[日本語版はこちら](README.ja.md)*

A Mac app and CLI for running a coding agent per git worktree and watching all of
them in one place.

Instead of checking tabs one by one, you can see which session is blocked waiting
for you and which one is still working in the background.

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

`TaskhubKit` is split into three layers so that the logic can be used from both
the CLI and the app. The boundary rule is that **presentation concerns never
enter the Kit**: terminal ANSI colors live in the CLI (`Terminal.swift`) and
SwiftUI colors live in the app (`Palette`). All the Kit knows is which statuses
exist and what symbol and name to call them by.

```
TaskhubKit/
  Model/       Data and vocabulary. No I/O
               TaskRecord, DiffCounts, CollectedTask, TaskStatus, RepoConfig, TaskID
  Repository/  The only door to the outside: the ledger, git and the environment
               LedgerStore, GitClient, ProcessRunner, ConfigStore,
               EnvironmentSource, Paths
  UseCase/     One per thing you want to do. Every decision lives here
               CollectTasks, CreateWorktree, RemoveWorktree,
               CleanMergedWorktrees, RecordHookEvent, RecordSessionStats,
               ReapClosedSessions, HookPayload

taskhub/       CLI (view). Reads arguments, calls a use case, formats for a terminal
TaskhubApp/    App (view). SwiftUI and AppKit. TaskStore wraps the repository
```

| File | Role |
| --- | --- |
| `~/.local/state/taskhub/state.json` | The ledger. One across all repositories. Created on first use |

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
diff -u /tmp/taskhub-baseline/{before,after}.txt
```

It works against a throwaway git repository and ledger, so your real ledger is
never touched.

## Install

```bash
scripts/create-signing-cert.sh   # once. Creates a local code signing certificate
scripts/install.sh               # installs to /Applications and links ~/bin/taskhub
```

The certificate comes first because Automation (Apple Events) permission is tied
to the pair of bundle identifier and code signature. With an ad-hoc signature the
signature changes on every build, so macOS asks you to approve controlling iTerm2
again each time.

On first launch macOS asks for permission to control iTerm2 — allow it.
Turn on *Launch at login* in the menu bar and it will start on its own from then on.

## Usage

```bash
taskhub ls              # list (--all for every repository, --json for machines)
taskhub new <name>      # create a worktree
taskhub open <id>       # print the worktree path (cd "$(taskhub open x)")
taskhub attach <id>     # open claude for that task, resuming the conversation
taskhub diff <id>       # diff against the base branch
taskhub clean           # clean up merged worktrees (--yes to actually do it)
taskhub sidebar         # launch the sidebar app
```

Destructive operations do nothing by default. `clean` only prints a list; it needs
`--yes` to remove anything, and worktrees with uncommitted changes are left out.

Clicking a row in the sidebar focuses that tab if it is still alive, and otherwise
opens a new tab resuming the conversation.

## Per-repository settings

Put a `.taskhub.json` at the root of a repository to change how `new` behaves.
It works fine without one.

```json
{
  "baseBranch": "develop",
  "branchPrefix": "syarihu/",
  "worktreeDir": ".claude/worktrees",
  "copyFiles": ["local.properties"],
  "maxConcurrent": 3
}
```

`copyFiles` carries over files that are gitignored and therefore do not reach the
new worktree. `worktreeDir` is added to `.git/info/exclude` on first use, so the
parent repository's `git status` stays clean.

## Wiring up your agent

**Installing it is not enough — the list stays empty.** taskhub is a passive tool
that reads the ledger and displays it; the thing that writes state into the ledger
is your Claude Code hooks.

How to wire it up depends on your setup (if you already use hooks or a statusLine,
they have to be merged rather than replaced), so instead of a procedure this is
written as **instructions to hand to an AI**.

→ paste [docs/setup-prompt.md](docs/setup-prompt.md) into Claude Code

Hooks call these three. They are not meant to be typed by a person, so they are
not listed in the help. All of them read the hook JSON from stdin.

| Command | Caller | Purpose |
| --- | --- | --- |
| `taskhub _touch <status>` | hooks | running / waiting / done / clear / notification |
| `taskhub _subagent start\|stop` | hooks | subagent count |
| `taskhub _stats` | statusline | session name, model, context usage |

`_touch` **prints the status it recorded to stdout** so the caller can use what
actually happened (to set a tab color, for example).

`notification` is the special one: taskhub looks at the payload's `message` and
decides whether it is a permission prompt or the *no input for 60 seconds* idle
notification. For an idle notification it records nothing and prints nothing.
Treating both as waiting would mark a session as blocked just because you walked
away after it finished. Copying that decision into the caller means the two can
drift apart when only one is fixed.

Interactive sessions you opened normally are picked up from `_touch` too, not just
worktrees created through taskhub.

## iTerm2 integration

Focusing a tab and opening a new one are done through AppleScript.
`id of session` is the same value as the part of `ITERM_SESSION_ID` after the `:`
(both are the PTYSession guid), so keeping it in the ledger is enough to match them.

Under the hardened runtime the `com.apple.security.automation.apple-events`
entitlement is required. Without it Apple Events are blocked by the runtime before
they reach TCC, which means taskhub never even appears in the Automation list in
System Settings.

The sidebar positions itself by reading iTerm2's window frame from CGWindowList.
That needs no Automation permission, so snapping works even before you grant it.

## Dependencies

`git`, plus `gh` for `clean` (to find merged pull requests).
There are no external Swift package dependencies.

## Contributing

See [CLAUDE.md](CLAUDE.md) for the conventions used in this repository
(English commit messages, Japanese code comments).
