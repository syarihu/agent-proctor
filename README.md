English | [日本語](README.ja.md)

<p align="center">
  <img src="docs/images/agent-proctor-logo.png" alt="agent-proctor" width="720">
</p>

# agent-proctor

A macOS companion app and CLI designed to monitor, track, and manage concurrent AI coding agents (Claude Code, Antigravity, Codex) working across git worktrees and iTerm2 tabs.

## Overview

When running multiple AI coding agents across several repositories and git worktrees, tracking their progress becomes tedious. It is easy to lose track of which agent is waiting for permission to run a command, which agent is stuck thinking, and which one has completed its task.

**agent-proctor** acts as an overseer for all your agent sessions. It observes active sessions in real time, organizes them alongside your iTerm2 terminal, surfaces sessions that need your attention, and brings you directly to the relevant terminal tab with a single click.

<p align="center">
  <img src="docs/images/sidebar-and-terminal.png" alt="agent-proctor sidebar alongside iTerm2, showing session status, attention notices, and notifications" width="880">
</p>

## Key Features

- **iTerm2 Companion Sidebar**: A collapsible sidebar that docks directly against the active iTerm2 window. Every row represents an agent session in an iTerm2 tab, and clicking a row immediately focuses that tab.
- **"Needs You" Attention Strip**: Pinned prominently at the top of the sidebar. Sessions awaiting approval for dangerous bash commands, unreviewed completed tasks, or crashed sessions are collected here so you never miss an interaction prompt.
- **Rich Session Details**: Displays real-time status (waiting, running, finished, error), elapsed time since last state transition, context token consumption percentage, currently invoked tools (e.g. `Read`, `Edit`, `Grep`), and hierarchical subagent trees.
- **Pull Request Awareness**: Automatically detects whether a worktree branch has an associated GitHub Pull Request, showing the PR number with status coloring (open, merged, closed, or draft) and providing direct browser links.
- **Multi-Level Organization**: Sessions are automatically grouped by GitHub repository and organization/owner (with avatar icons). Groups can be folded independently with compact tally summaries (`⏳1 ▶2 ⌁2`).
- **System Notifications**: Native macOS notifications alert you the instant an agent stops for approval, completes work, or encounters an error. Clicking a notification immediately takes you to the corresponding terminal tab.
- **Git Worktree Oversight**: Inspect uncommitted file changes (`+N -M ?K`), branch merge states, and idle time across worktrees. Easily identify abandoned or completed worktrees that are ready for cleanup.
- **Zero External Dependencies**: Built entirely with Swift and system frameworks with no third-party package dependencies. It relies only on local `git` (with optional `gh` CLI for organization avatar grouping and PR lookups).

<p align="center">
  <img src="docs/images/status-transitions.gif" alt="Dynamic status transitions, subagent hierarchy, and notification triggers" width="760">
</p>

## Installation

### Homebrew (Recommended)

```bash
brew install syarihu/tap/agent-proctor
proctor sidebar
```

### Building from Source

```bash
# Generate a local code signing certificate for automation permissions (one-time setup)
scripts/create-signing-cert.sh

# Build, install to /Applications, and symlink ~/bin/proctor
scripts/install.sh
```

> [!NOTE]
> On first launch, macOS will request permissions to control iTerm2 (Apple Events) for automatic tab focusing, and notification permissions for desktop alerts. If permissions were declined, you can enable them at any time via **Settings… → Permission**.

<p align="center">
  <img src="docs/images/settings.png" alt="agent-proctor settings window" width="540">
</p>

## Connecting Your Agents

agent-proctor is a lightweight viewer that reads state from a centralized ledger (`~/.local/state/proctor/state.json`). To populate this ledger, configure your agent's event hooks to notify proctor on state transitions.

proctor provides built-in setup guides formatted specifically for AI agents to follow:

```bash
# List available agent setup guides
proctor setup ls

# Output setup instructions for a specific agent (e.g. claude, agy, codex)
proctor setup claude

# Output all setup instructions
proctor setup all
```

For Claude Code, running `! proctor setup claude` directly within your conversation instructs the agent to configure its own hooks automatically.

## CLI Usage

The `proctor` CLI allows you to inspect and manage sessions and worktrees from any terminal without opening the graphical sidebar:

| Command | Description |
| --- | --- |
| `proctor ls` | List all active agent sessions (`--all` for all repositories, `--json` for structured output). |
| `proctor worktree ls` | List git worktrees with status, uncommitted diffs, and cleanup suitability (`--all`, `--json`). |
| `proctor attach <id>` | Resume the agent session associated with the specified ID in the current terminal. |
| `proctor title <text>` | Assign a descriptive title to the current session (run `proctor title ""` to clear). |
| `proctor rm <id>` | Remove a stale session from the ledger (leaves the underlying worktree untouched). |
| `proctor setup [agent]` | Print hook configuration instructions for coding agents. |
| `proctor skill [name]` | Print standardized workflow guides for agents (e.g. `proctor skill worktree`). |
| `proctor sidebar` | Launch the macOS companion sidebar application. |
| `proctor --version` | Print the version number. |

### Worktree Management

When multiple agents complete their assignments, forgotten worktrees can accumulate on disk. `proctor worktree ls` surfaces idle worktrees and flags branches that have already been merged:

```
agent-proctor
WORKTREE  BRANCH       STATE        DIFF   IDLE
work      feature      in use (2)   +1 ?1  3m
spike     spike        nobody here  +1     2d
merged    merged-work  can go              6d
```

To teach your agents how to create, inspect, and safely sweep up worktrees, share the built-in skill:

```bash
proctor skill worktree
```

<p align="center">
  <img src="docs/images/menu-bar.png" alt="agent-proctor menu bar extra showing session tally and quick access menu" width="382">
</p>

## Menu Bar Extra

agent-proctor runs quietly in your macOS menu bar. The menu bar icon displays a live tally of waiting and running sessions, and clicking it opens a menu listing every active session with instant navigation to its iTerm2 tab.

## Architecture & Design

agent-proctor is designed as a modular, multi-target Swift Package Manager application adhering to strict layer separation:

- **Core (`Model`, `Utility`, `Resources`)**: Basic data models, process execution, and localization tables. Free of business logic.
- **Repository (`RepositoryLedger`, `RepositoryGit`, `RepositoryGitHub`)**: External I/O gateways managing disk state synchronization, git processes, and GitHub CLI interactions.
- **UseCase (`UseCaseTask`, `UseCaseSession`, `UseCaseWorktree`, `UseCaseNotice`)**: Encapsulates single-responsibility domain workflows and decisions.
- **Design & Bridges (`DesignSystem`, `ItermBridge`)**: Shared UI tokens, status glyphs, and AppleScript terminal automation.
- **Application State (`AppState`)**: Thread-safe observable stores (`TaskStore`) bridging background polling with SwiftUI views.
- **Features (`FeatureSidebar`, `FeatureMenuBar`, `FeatureSettings`)**: Modular UI views and controllers.
- **Entry Points (`proctor`, `ProctorApp`)**: CLI executable and macOS menu bar application.

For detailed architecture diagrams and layer boundary rules, see [docs/architecture.md](docs/architecture.md).

## Contributing

See [CLAUDE.md](CLAUDE.md) for development guidelines, testing procedures, and coding conventions.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
