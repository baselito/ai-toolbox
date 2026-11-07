# Git Worktrees

What worktrees are, when the agent uses them, and how parallel task execution works.

---

## When to Read This

- You want to understand how the agent works on multiple tasks simultaneously
- You see worktree-related output during a workflow
- You want to understand the using-git-worktrees skill

---

## What Is a Git Worktree?

A git worktree is a separate working directory linked to the same repository. It lets you have multiple branches checked out simultaneously without switching back and forth. Each worktree has its own working directory but shares the same git history.

---

## When the Agent Uses Worktrees

The `using-git-worktrees` skill (from Superpowers) activates during `/flow` when the implementation plan has multiple independent tasks.

**Example:** The planner identifies 3 tasks:
- Task A: Add loading spinner component (independent)
- Task B: Update API endpoint (independent)
- Task C: Write integration tests (depends on A and B)

The agent creates worktrees for Task A and Task B so they can run in parallel. Task C waits for both to complete.

---

## How It Works

1. The `planner` (Opus) creates the implementation plan with dependency mapping
2. The agent identifies which tasks are independent (no dependencies between them)
3. For independent tasks, the agent creates separate git worktrees
4. Each worktree gets its own subagent running in parallel
5. Dependent tasks wait for their prerequisites to complete
6. When all worktrees are done, changes are merged back

---

## When Worktrees Are NOT Used

- Single-task implementations (most bug fixes, hotfixes)
- All tasks are sequential (each depends on the previous one)
- The task is too small to benefit from parallelisation
- The user opts out during plan approval

---

## What You See

During a workflow with worktrees, you may see output like:

```
Creating worktrees for parallel execution:
  worktree/task-a — Add loading spinner
  worktree/task-b — Update API endpoint

Parallel execution:
  [task-a] Implementing... done
  [task-b] Implementing... done

Merging worktree results...
Continuing with sequential tasks:
  [task-c] Write integration tests
```

---

## Notes

- Worktrees are temporary — they are cleaned up after the task completes
- The agent handles all worktree creation, execution, and cleanup automatically
- You do not need to understand git worktrees to use this toolbox — the skill manages everything
- If a worktree task fails, the agent reports the failure and continues with remaining tasks
