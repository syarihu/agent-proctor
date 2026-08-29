# Creating and cleaning up git worktrees

You are working in a repository watched by agent-proctor. This is how worktrees are
made and taken away here.

**proctor itself never creates or removes a worktree.** It only reads: `git worktree
list`, `git diff`, and the ledger your hooks write. Every change below is a git
command *you* run.

## Look before you build

```bash
proctor worktree ls            # this repository
proctor worktree ls --all      # every repository proctor has seen
proctor worktree ls --json     # the same facts, for you to read
```

Each worktree comes back with the sessions running in it, its uncommitted changes,
whether its branch is already merged, and how long it has been since its last commit.
`isRemovable` is true when nothing is running there, nothing is uncommitted, the
branch is merged, and it is not locked.

**`diff` only means anything when `diffKnown` is true.** When proctor could not
read the worktree it reports zeros, which is why `isRemovable` refuses those. If
you ever judge a worktree by hand instead of by that flag — step 2 below — check
`diffKnown`, `sessions`, `isLocked`, `isMain`, `isBare` and `isPrunable` yourself.
An unreadable worktree is *unknown*, not *empty*.

**Read this first, every time.** If a worktree for this task already exists, use it
instead of making a second one — that is how a repository ends up with five
directories for the same piece of work.

## Where a worktree goes

Conventions live in `~/.config/proctor/config.json`. **That is where a new one goes;
it does not go inside the repository.** How you slice worktrees is your own business,
not the repository's, so nothing is added to the checkout of somebody who does not use
proctor. A `.proctor.json` at the root of a repository is still read, but it is the
override for a team that shares a convention — see the order below.

```json
{
  "worktreeBase": ".claude/worktrees",
  "branchPattern": "{user}/{name}",
  "repositories": {
    "github.com/syarihu/agent-proctor": {
      "copyFiles": ["local.properties"]
    }
  }
}
```

| Key | Meaning |
| --- | --- |
| `worktreeBase` | Where worktrees are created, relative to the repository root (an absolute path also works) |
| `branchPattern` | How branches are named. `{name}` is the slug of what the work is called; `{user}` is the git user; `{issue}` is an issue number when there is one |
| `copyFiles` | Files that are gitignored and therefore do not come along — copy them in from the main checkout. Without them the build can die on the first command. These differ per repository, so they usually belong under `repositories` |

The top level holds the defaults for every repository; `repositories` overrides them
one repository at a time. Its keys are the remote origin flattened to
`<host>/<owner>/<name>`. `git remote get-url origin` comes back in more than one
shape — scp-style (`git@github.com:owner/repo.git`) as well as a URL (`ssh://…`,
`https://…`) — so read the host, the owner and the name out of it and join them with
`/` rather than trimming the end, dropping the trailing `.git`.
**The checkout path is not the key, because where a repository is cloned
differs from person to person**, and from inside a worktree it is not even the path
of the main checkout.

For each key, take the first of these that defines it:

1. `.proctor.json` at the root of the repository — when it exists it wins over
   everything. It is the way out for a team that wants to share a convention; most
   repositories do not have one.
2. The entry for this repository's origin under `repositories` in
   `~/.config/proctor/config.json`.
3. The top level of that same file.

**If none of them defines it, do not invent a convention silently.** Look at the existing
worktrees (`proctor worktree ls --json`) and at the branch names in `git branch`,
propose what you inferred, and add it to `~/.config/proctor/config.json` only after
the person agrees.

## Creating one

```bash
git worktree add -b <branch> <worktreeBase>/<name> <base-branch>
```

- Branch off whatever the repository actually develops from — usually the default
  branch, freshly fetched. If the task says otherwise, follow the task.
- Copy every `copyFiles` entry from the main checkout afterwards.
- If the branch already exists, leave off `-b` and check it out instead.

Then start the agent inside that directory. It appears in proctor on its own as soon
as the first hook fires; there is nothing to register.

## Cleaning up

Merged work is what fills a repository up. Sweep it like this:

1. `proctor worktree ls --all --json` and take the entries with `isRemovable: true`.
2. **`merged: false` is not proof that work is unfinished.** A squash-merged pull
   request leaves no ancestry behind, so proctor cannot see it. For each leftover
   branch, ask GitHub before giving up:
   ```bash
   git rev-parse <branch>
   gh pr list --head <branch> --state merged --json number,mergedAt,headRefOid
   ```
   **The commit has to match.** A merged pull request only says that this branch
   name was merged once — if work continued on it afterwards, or the name was
   reused, those commits exist nowhere but here. Treat it as merged only when a
   merged pull request's `headRefOid` is the branch's current tip.
   If `gh` is missing, not signed in, or the query fails, the answer is *unknown*
   — and unknown means you leave the worktree alone.
3. **Show the list to the person and get an answer before removing anything.**
   Name each worktree, its branch, and why you believe it is finished.
4. Then, for each approved one:
   ```bash
   git worktree remove <path>
   git branch -d <branch>
   ```
   **A squash-merged branch will refuse `-d`** — there is no ancestry for git to
   check, which is the whole reason step 2 exists. `git branch -D` is the right
   tool there, but only with all of step 2 satisfied: a merged pull request whose
   `headRefOid` is this branch's tip, an empty `diff`, and the person's approval
   for this worktree. Everywhere else, `-D` still needs them to say so.
5. `proctor` needs nothing after that. The row leaves the list on its own.

## When not to touch it

Leave a worktree alone — and say why — when any of these hold:

- Uncommitted changes (`diff` is not empty). That work exists nowhere else.
- Commits that are not pushed anywhere (`git log --branches --not --remotes`).
- A session is still running in it (`sessions` is not empty).
- `isLocked` is true. Somebody locked it on purpose.

Deleting a worktree throws away work that has no copy. Being asked twice costs a
sentence; being wrong costs a day.
