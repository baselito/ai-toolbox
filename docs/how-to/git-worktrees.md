# Git Worktrees

How to use git worktrees for parallel task execution — working on multiple tickets simultaneously without switching branches.

---

## When to Read This

- You want to work on multiple tasks at the same time
- You are running `/flow` on a Scrum board and want parallel ticket execution
- You want to understand the `using-git-worktrees` skill

---

## What Are Git Worktrees?

A git worktree is a separate working directory linked to the same repository. Each worktree has its own branch, its own file state, and its own checkout — but they all share the same `.git` history.

This means you can have `feature/login` open in one directory and `feature/dashboard` in another, both building and running independently.

---

## When to Use Worktrees

| Scenario | Use worktree? |
|---|---|
| Sprint with multiple independent tickets | Yes |
| Two `/flow` tasks that do not touch the same files | Yes |
| Single ticket, single branch | No |
| Dependent tasks (Task B needs Task A merged first) | No — work sequentially |

---

## The using-git-worktrees Skill

The `using-git-worktrees` skill (from `obra/superpowers`) handles worktree lifecycle automatically:

1. **Creates** a worktree with the correct branch name
2. **Isolates** each task in its own directory
3. **Manages** cleanup when work is complete — merges or discards

The agent activates this skill during `/flow` when parallel execution is beneficial.

---

## Practical Example — Sprint with 3 Tickets

```
/flow
```

The `project-manager-senior` agent plans the sprint (on Scrum boards). If it identifies 3 independent tickets, the agent may use worktrees:

```
~/your-project/                          → main branch (untouched)
~/your-project/.worktrees/PROJ-101/      → feature/PROJ-101-login
~/your-project/.worktrees/PROJ-102/      → feature/PROJ-102-api-cache
~/your-project/.worktrees/PROJ-103/      → feature/PROJ-103-email-service
```

Each ticket gets a full `/flow` cycle in its own worktree. The agent works on them sequentially but each branch stays isolated — no stashing, no conflicts during development.

---

## Cleanup

When a task completes, the `finishing-a-development-branch` skill offers options:

- **Merge** — merge the branch and remove the worktree
- **PR** — push the branch, create a PR, remove the worktree
- **Keep** — leave the worktree for further work
- **Discard** — delete the branch and worktree

---

## Limitations

- Worktrees share the same `.git` directory — running `git gc` or heavy operations in one affects all
- Two worktrees cannot have the same branch checked out simultaneously
- Large repos with many submodules may be slow to create worktrees

---

## Related Docs

- [Skill List](../reference/skill-list.md) — full list including `using-git-worktrees`
- [Commands Reference](commands.md) — `/flow` workflow
- [Agent List](../reference/agent-list.md) — `project-manager-senior` for sprint planning
