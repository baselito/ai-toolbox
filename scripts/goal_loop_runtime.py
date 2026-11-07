#!/usr/bin/env python3
"""Durable, provider-neutral goal-loop runtime.

The module intentionally has no third-party dependencies. Project-specific
commands are supplied by a toolbox-owned verification registry, never by goal
or project text.
"""

from __future__ import annotations

import dataclasses
import hashlib
import inspect
import json
import math
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
from contextlib import contextmanager
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Mapping, Optional, Protocol


SCHEMA_VERSION = 1
DEFAULT_MAX_ITERATIONS = 25
DEFAULT_MAX_WALL_CLOCK_SECONDS = 3600.0
DEFAULT_MAX_COST_USD = 10.0


class RunStatus(str, Enum):
    RUNNING = "RUNNING"
    PAUSED = "PAUSED"
    RESUMABLE = "RESUMABLE"
    HUMAN_ACTION_REQUIRED = "HUMAN_ACTION_REQUIRED"
    BLOCKED = "BLOCKED"
    FAILED = "FAILED"
    COMPLETE_CANDIDATE = "COMPLETE_CANDIDATE"
    COMPLETED = "COMPLETED"
    CANCELLED = "CANCELLED"


class AdvisorClass(str, Enum):
    HEALTHY_PROGRESS = "HEALTHY_PROGRESS"
    IDLE = "IDLE"
    STALE = "STALE"
    BLOCKED = "BLOCKED"
    HUMAN_ACTION_REQUIRED = "HUMAN_ACTION_REQUIRED"
    FAILED = "FAILED"
    COMPLETE_CANDIDATE = "COMPLETE_CANDIDATE"


@dataclasses.dataclass(frozen=True)
class RoleAssignment:
    """Provider-neutral routing decision for a bounded loop responsibility."""

    role: str
    identity: str
    model_tier: str
    task_kind: str


ROLE_POLICY: dict[str, dict[str, Any]] = {
    "planner_advisor_project_manager": {
        "identities": ["gpt-6-astra", "fable"],
        "model_tier": "strategic",
        "task_kinds": ["planning", "advising", "project_management"],
    },
    "implementation_review_worker": {
        "identities": ["opus", "luna"],
        "model_tier": "worker",
        "task_kinds": ["implementation", "review"],
    },
    "routine_operations": {
        "identities": ["lightweight"],
        "model_tier": "lightweight",
        "task_kinds": ["reminder", "status", "heartbeat", "check-in"],
    },
}


class RoleRouter:
    """Machine-readable abstract-role policy used by runtime adapters."""

    _named_roles = {
        "gpt-6-astra": "planner_advisor_project_manager",
        "fable": "planner_advisor_project_manager",
        "chief-of-staff": "planner_advisor_project_manager",
        "orchestrator": "planner_advisor_project_manager",
        "opus": "implementation_review_worker",
        "luna": "implementation_review_worker",
        "implementer": "implementation_review_worker",
        "reviewer": "implementation_review_worker",
        "reality-checker": "implementation_review_worker",
        "lightweight": "routine_operations",
        "jira-workflow-steward": "routine_operations",
    }

    @classmethod
    def policy(cls) -> dict[str, dict[str, Any]]:
        return json.loads(json.dumps(ROLE_POLICY))

    def named_role(self, identity: str) -> str:
        try:
            return self._named_roles[identity.lower()]
        except KeyError as exc:
            raise ValueError(f"unknown named agent identity: {identity}") from exc

    def route(self, task_kind: str, identity: Optional[str] = None) -> RoleAssignment:
        normalized = task_kind.lower().replace("_", "-")
        for role, definition in ROLE_POLICY.items():
            task_kinds = {item.lower().replace("_", "-") for item in definition["task_kinds"]}
            if normalized in task_kinds:
                selected = identity or definition["identities"][0]
                if selected.lower() not in {item.lower() for item in definition["identities"]}:
                    raise ValueError(f"identity {selected} is not assigned to {role}")
                return RoleAssignment(role, selected, definition["model_tier"], task_kind)
        raise ValueError(f"unknown goal-loop task kind: {task_kind}")

    def provider_assignment(self, provider: str, task_kind: str = "implementation") -> RoleAssignment:
        """Return the worker role without claiming provider availability."""

        identity = "opus" if provider.lower() == "claude" else "luna"
        return self.route(task_kind, identity=identity)

    def planner_assignment(self, provider: str, task_kind: str = "advising") -> RoleAssignment:
        """Return the provider-specific planning/advisor assignment."""

        identity = "fable" if provider.lower() == "claude" else "gpt-6-astra"
        return self.route(task_kind, identity=identity)

    @staticmethod
    def heartbeat_assignment() -> RoleAssignment:
        return RoleRouter().route("heartbeat", identity="lightweight")


class MergePolicy:
    """Repository policy for unattended merge requests.

    The policy is deliberately narrower than the normal user-commanded merge
    path: only the toolbox repository may be auto-merged by a GoalRun. The
    live hook remains the final authority at the shell boundary.
    """

    TOOLBOX_REPO = "baselito/ai-engineering"

    @staticmethod
    def _run(argv: list[str], *, cwd: Optional[Path] = None) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            argv, cwd=cwd, capture_output=True, text=True, shell=False, check=False, timeout=60
        )

    @classmethod
    def collect_live_evidence(
        cls, repo: str, pr_number: int, worktree: Path | str | None = None
    ) -> dict[str, Any]:
        """Collect merge inputs from GitHub and the checked-out PR head.

        The evidence file remains useful as an audit input, but it is not a
        trust boundary: booleans and SHAs supplied by a caller are ignored.
        """

        if repo != cls.TOOLBOX_REPO:
            raise GoalLoopError("live auto-merge evidence is restricted to the toolbox repository")
        root = Path(worktree).resolve() if worktree else None
        meta = cls._run([
            "gh", "pr", "view", str(pr_number), "--repo", repo,
            "--json", "state,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,headRefOid",
        ], cwd=root)
        if meta.returncode != 0:
            raise GoalLoopError(f"could not collect live PR evidence: {meta.stderr[-1000:]}")
        try:
            payload = json.loads(meta.stdout)
        except json.JSONDecodeError as exc:
            raise GoalLoopError("GitHub returned invalid PR evidence") from exc

        checked_head = None
        if root is not None:
            head = cls._run(["git", "rev-parse", "HEAD"], cwd=root)
            if head.returncode != 0:
                raise GoalLoopError(f"could not resolve checked-out HEAD: {head.stderr[-1000:]}")
            checked_head = head.stdout.strip()
            cleanliness = cls._run(["git", "status", "--porcelain", "--untracked-files=all"], cwd=root)
            if cleanliness.returncode != 0:
                raise GoalLoopError(f"could not verify checked-out worktree: {cleanliness.stderr[-1000:]}")
            if cleanliness.stdout.strip():
                raise GoalLoopError("checked-out worktree is dirty; merge evidence must describe the exact PR HEAD")
        current_head = str(payload.get("headRefOid", ""))
        if root is None:
            # In remote-only mode the GitHub PR head is the checked evidence
            # head; no local checkout is required to bind the gate.
            checked_head = current_head
        rollup = payload.get("statusCheckRollup") or []
        statuses = cls._latest_check_statuses(rollup)
        ci_green = not rollup or all(status in {"SUCCESS", "SKIPPED", "NEUTRAL"} for status in statuses)
        merge_state = str(payload.get("mergeStateStatus", "")).upper()
        branch_ready = merge_state in {"CLEAN", "UNSTABLE"}
        files = cls._run([
            "gh", "api", f"repos/{repo}/pulls/{int(pr_number)}/files", "--paginate", "--jq", ".[].filename",
        ], cwd=root)
        if files.returncode != 0:
            raise GoalLoopError(f"could not collect changed files: {files.stderr[-1000:]}")
        changed_files = [line.strip() for line in files.stdout.splitlines() if line.strip()]

        query = (
            "query($owner:String!,$name:String!,$number:Int!,$cursor:String){repository(owner:$owner,name:$name){"
            "pullRequest(number:$number){reviewThreads(first:100,after:$cursor){nodes{isResolved isOutdated}"
            "pageInfo{hasNextPage endCursor}}}}}"
        )
        unresolved = []
        cursor = "null"
        while True:
            threads = cls._run([
                "gh", "api", "graphql", "-f", f"query={query}",
                "-f", "owner=baselito", "-f", "name=ai-engineering",
                "-F", f"number={int(pr_number)}", "-F", f"cursor={cursor}",
            ], cwd=root)
            if threads.returncode != 0:
                raise GoalLoopError(f"could not collect review-thread evidence: {threads.stderr[-1000:]}")
            try:
                thread_payload = json.loads(threads.stdout)
                page = thread_payload["data"]["repository"]["pullRequest"]["reviewThreads"]
                nodes = page["nodes"]
                unresolved.extend(
                    node for node in nodes if not node.get("isResolved") and not node.get("isOutdated")
                )
                if not page["pageInfo"]["hasNextPage"]:
                    break
                cursor = page["pageInfo"]["endCursor"]
            except (KeyError, TypeError, json.JSONDecodeError) as exc:
                raise GoalLoopError("GitHub returned invalid review-thread evidence") from exc

        return {
            "open": payload.get("state") == "OPEN",
            "mergeable": payload.get("mergeable") == "MERGEABLE",
            "merge_state_status": merge_state,
            "ci_green": ci_green and merge_state in {"CLEAN", "UNSTABLE"},
            "review_decision": payload.get("reviewDecision") or "PENDING",
            "unresolved_threads": unresolved,
            "current_head_sha": current_head,
            "checked_head_sha": checked_head,
            "branch_protection": branch_ready,
            "marker_valid": True,
            "live_verified": True,
            "evidence_source": "github-live" if root is None else "github-live+clean-worktree",
            "protected_files": [path for path in changed_files if path == "knowledge/toolbox-lessons.yml"],
        }

    @staticmethod
    def _latest_check_statuses(rollup: list[Mapping[str, Any]]) -> list[str]:
        """Use the latest attempt when GitHub retains retried check runs."""
        latest: dict[str, tuple[str, int, str]] = {}
        for index, item in enumerate(rollup):
            if not isinstance(item, Mapping):
                continue
            name = str(item.get("name") or item.get("context") or item.get("workflowName") or f"check-{index}")
            timestamp = str(item.get("completedAt") or item.get("startedAt") or "")
            status = str(item.get("conclusion") or item.get("state") or "").upper()
            candidate = (timestamp, index, status)
            if name not in latest or candidate[:2] >= latest[name][:2]:
                latest[name] = candidate
        return [item[2] for item in latest.values()]

    @staticmethod
    def _unresolved_count(value: Any) -> int:
        if isinstance(value, int):
            return max(0, value)
        if not isinstance(value, list):
            return 1
        return sum(
            1
            for item in value
            if not isinstance(item, Mapping)
            or (not bool(item.get("resolved")) and not bool(item.get("isResolved")))
            and not bool(item.get("outdated"))
            and not bool(item.get("isOutdated"))
        )

    @classmethod
    def evaluate(cls, repo: str, evidence: Mapping[str, Any]) -> dict[str, Any]:
        merge_state = str(evidence.get("merge_state_status", "")).upper()
        gates = {
            "open": evidence.get("open") is True,
            "mergeable": evidence.get("mergeable") is True,
            # Older offline evidence fixtures did not carry this field. Live
            # evidence always does, so a present value is authoritative while
            # legacy fixtures retain their previous contract.
            "merge_state_status": (
                merge_state in {"CLEAN", "UNSTABLE"}
                if "merge_state_status" in evidence
                else True
            ),
            "ci_green": evidence.get("ci_green") is True,
            "review_decision": str(evidence.get("review_decision", "")).upper() != "CHANGES_REQUESTED",
            "threads_resolved": cls._unresolved_count(evidence.get("unresolved_threads")) == 0,
            "head_current": bool(evidence.get("current_head_sha"))
            and evidence.get("current_head_sha") == evidence.get("checked_head_sha"),
            "branch_protection": evidence.get("branch_protection") is True,
            "marker_valid": evidence.get("marker_valid") is True,
            "live_verified": evidence.get("live_verified") is True
            and evidence.get("evidence_source") in {"github-live", "github-live+clean-worktree"},
        }
        protected_files = evidence.get("protected_files", [])
        if isinstance(protected_files, list) and "knowledge/toolbox-lessons.yml" in protected_files:
            gates["protected_files"] = False
        failed = [name for name, passed in gates.items() if not passed]
        quality_ready = not any(
            not gates[name]
            for name in (
                "open", "mergeable", "merge_state_status", "ci_green",
                "review_decision", "threads_resolved", "head_current",
            )
        )
        if repo != cls.TOOLBOX_REPO:
            return {
                "allowed": False,
                "action": "REPORT_MERGE_READY" if quality_ready else "BLOCKED",
                "repo": repo,
                "failed_gates": failed,
                "reason": "auto-merge is disabled outside the toolbox repository",
            }
        if failed:
            return {
                "allowed": False,
                "action": "BLOCKED",
                "repo": repo,
                "failed_gates": failed,
                "reason": "merge evidence did not satisfy the current-head-bound gate",
            }
        return {
            "allowed": True,
            "action": "AUTO_MERGE",
            "repo": repo,
            "failed_gates": [],
            "reason": "toolbox-only auto-merge gate passed; the live hook must still re-verify",
        }

    @classmethod
    def write_marker(
        cls, repo: str, pr_number: int, marker_dir: Path | str, *, head_sha: str
    ) -> Path:
        """Create the hook marker only after the exact policy has passed."""
        if repo != cls.TOOLBOX_REPO:
            raise GoalLoopError("auto-merge markers are restricted to the toolbox repository")
        root = Path(marker_dir).expanduser().resolve()
        root.mkdir(parents=True, exist_ok=True)
        marker = root / f".pr-merge-gate-baselito-ai-engineering-{int(pr_number)}"
        try:
            fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError as exc:
            raise GoalLoopError("a merge capability already exists for this PR; re-gate after it is consumed") from exc
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump({
                "mode": "goal-run",
                "repo": repo,
                "pr": int(pr_number),
                "head_sha": head_sha,
                "issued_at": _now(),
            }, handle)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        return marker


class GoalLoopError(Exception):
    """Base runtime error."""


class StateError(GoalLoopError):
    """State is missing, corrupt, unsafe, or incompatible."""


class LeaseError(GoalLoopError):
    """A run is already owned by another live worker."""


class LeaseFenceError(LeaseError):
    """The lease was validly read but no longer belongs to this worker."""


class VerificationError(GoalLoopError):
    """A verifier key cannot be resolved safely."""


class UnknownAction(GoalLoopError):
    """An external action outcome cannot be reconciled automatically."""


@dataclasses.dataclass
class ProviderResult:
    session_id: Optional[str] = None
    changed: bool = False
    completed: bool = False
    output: str = ""
    error: Optional[str] = None
    human_action_required: Optional[str] = None
    wall_clock_seconds: float = 0.0
    # In-process providers must explicitly account for a zero-cost action;
    # external adapters still map an omitted field to None and are gated.
    cost_usd: Optional[float] = 0.0
    new_head_sha: Optional[str] = None
    # A provider may be unavailable before it performs any work (for example
    # a local CLI is missing or its usage budget is exhausted).  Only these
    # explicit, outcome-known failures may be handed to the other provider.
    # An ordinary error is intentionally not retried because it may represent
    # work that happened before the wrapper failed to report its result.
    failure_kind: Optional[str] = None
    outcome_known: bool = True


@dataclasses.dataclass(frozen=True)
class AdvisoryProposal:
    """Evidence-backed improvement proposal awaiting user approval."""

    kind: str
    title: str
    evidence: list[str]
    impact: str
    scope: str
    acceptance_criteria: list[str]
    risk: str = "medium"
    priority: int = 0
    jira_key: Optional[str] = None
    confidence: str = "medium"
    alternatives: list[str] = dataclasses.field(default_factory=list)
    jira_priority: str = "Medium"
    workflow: str = "/flow"


class AdvisoryDiscovery:
    """Rank read-only findings without creating external work items."""

    _risk_weight = {"critical": 4, "high": 3, "medium": 2, "low": 1}

    @staticmethod
    def _items(value: Any) -> list[str]:
        if value is None:
            return []
        if isinstance(value, str):
            return [value]
        if isinstance(value, (list, tuple, set)):
            return [str(item) for item in value]
        return [str(value)]

    def rank(self, scope: str, findings: list[Mapping[str, Any]]) -> list[AdvisoryProposal]:
        proposals = []
        for finding in findings:
            kind = str(finding.get("kind", "improvement"))
            title = str(finding.get("title", "Unspecified improvement"))
            impact = str(finding.get("impact", "Impact requires confirmation"))
            risk = str(finding.get("risk", "medium")).lower()
            evidence = self._items(finding.get("evidence"))
            if not evidence and finding.get("path"):
                evidence = [str(finding["path"])]
            criteria = self._items(finding.get("acceptance_criteria"))
            confidence = str(finding.get("confidence", "medium")).lower()
            alternatives = self._items(finding.get("alternatives"))
            impact_score = finding.get("impact_score", 0)
            try:
                impact_score = int(impact_score)
            except (TypeError, ValueError):
                impact_score = 0
            try:
                base_priority = int(finding.get("priority", 0))
            except (TypeError, ValueError):
                base_priority = 0
            jira_priority = str(
                finding.get(
                    "jira_priority",
                    {"critical": "Highest", "high": "High", "medium": "Medium", "low": "Low"}.get(
                        risk, "Medium"
                    ),
                )
            )
            workflow = str(
                finding.get(
                    "workflow",
                    {
                        "bug": "/bug",
                        "refactor": "/refactor",
                        "security": "/security",
                        "performance": "/perf",
                        "feature": "/flow",
                        "reliability": "/flow",
                        "documentation": "/flow",
                    }.get(kind.lower(), "/flow"),
                )
            )
            proposals.append(
                AdvisoryProposal(
                    kind=kind,
                    title=title,
                    evidence=evidence,
                    impact=impact,
                    scope=str(finding.get("scope", scope)),
                    acceptance_criteria=criteria,
                    risk=risk,
                    priority=base_priority + self._risk_weight.get(risk, 0) + impact_score,
                    confidence=confidence,
                    alternatives=alternatives,
                    jira_priority=jira_priority,
                    workflow=workflow,
                )
            )
        return sorted(proposals, key=lambda item: (-item.priority, item.title.lower()))


class ProviderAdapter(Protocol):
    """Provider-neutral worker contract implemented by approved wrappers."""

    def start_iteration(self, state: GoalState, assignment: RoleAssignment) -> ProviderResult:
        ...

    def resume_session(
        self, state: GoalState, assignment: RoleAssignment, session_id: str
    ) -> ProviderResult:
        """Resume a provider-owned session after an explicit recovery decision."""
        ...

    def start_advisor(
        self, state: GoalState, incident: Mapping[str, Any], assignment: RoleAssignment
    ) -> ProviderResult:
        ...

    def inspect_session(self, session_id: str) -> Mapping[str, Any]:
        ...

    def capabilities(self) -> Mapping[str, bool]:
        ...

    def role_policy(self) -> Mapping[str, Mapping[str, Any]]:
        ...


class UnavailableProvider:
    """Safe default when no signed-in provider session is available."""

    def __init__(self, provider: str):
        self.provider = provider

    def start_iteration(self, state: GoalState, assignment: Optional[RoleAssignment] = None) -> ProviderResult:
        return ProviderResult(
            error=(
                f"{self.provider} provider session is unavailable; sign in or run "
                "the provider's approved local wrapper"
            ),
            human_action_required=(
                f"{self.provider} provider session is unavailable; sign in or run "
                "the provider's approved local wrapper"
            ),
            failure_kind="provider_unavailable",
            outcome_known=True,
        )

    def resume_session(
        self, state: GoalState, assignment: Optional[RoleAssignment] = None, session_id: str = ""
    ) -> ProviderResult:
        return self.start_iteration(state, assignment)

    def start_advisor(
        self, state: GoalState, incident: Mapping[str, Any], assignment: RoleAssignment
    ) -> ProviderResult:
        return self.start_iteration(state, assignment)

    def inspect_session(self, session_id: str) -> Mapping[str, Any]:
        return {"status": "unknown", "session_id": session_id}

    def capabilities(self) -> Mapping[str, bool]:
        return CapabilityDetector().detect(self.provider)

    def role_policy(self) -> Mapping[str, Mapping[str, Any]]:
        return RoleRouter.policy()


class ProviderAdapterRegistry:
    """Select host-supplied Claude/Codex adapters without inventing access."""

    def __init__(self, adapters: Optional[Mapping[str, ProviderAdapter]] = None):
        self.adapters = {name.lower(): adapter for name, adapter in (adapters or {}).items()}

    @classmethod
    def from_environment(
        cls,
        env: Optional[Mapping[str, str]] = None,
        *,
        executable_lookup: Callable[[str], Optional[str]] = shutil.which,
    ) -> "ProviderAdapterRegistry":
        """Build adapters from JSON argv commands supplied by the host.

        The wrapper contract is provider-neutral: it receives one JSON state
        document on stdin and returns one JSON ProviderResult document. JSON
        argv is required so goal text can never become shell code.
        """
        values = dict(os.environ if env is None else env)
        adapters: dict[str, ProviderAdapter] = {}
        for provider in ("claude", "codex"):
            raw = values.get(f"GOAL_LOOP_{provider.upper()}_COMMAND", "").strip()
            if not raw:
                continue
            try:
                argv = json.loads(raw)
            except json.JSONDecodeError as exc:
                raise ValueError(
                    f"GOAL_LOOP_{provider.upper()}_COMMAND must be a JSON argv list"
                ) from exc
            if not isinstance(argv, list) or not argv or not all(isinstance(item, str) and item for item in argv):
                raise ValueError(
                    f"GOAL_LOOP_{provider.upper()}_COMMAND must be a non-empty JSON argv list"
                )
            adapters[provider] = CommandProviderAdapter(
                provider, argv, executable_lookup=executable_lookup
            )
        return cls(adapters)

    def select(self, provider: str) -> ProviderAdapter:
        normalized = provider.lower()
        if normalized not in {"claude", "codex"}:
            raise ValueError(f"unsupported provider: {provider}")
        return self.adapters.get(normalized, UnavailableProvider(normalized))

    def candidates(self, preferred: str) -> list[tuple[str, ProviderAdapter]]:
        """Return preferred provider first, then the other approved provider."""
        normalized = preferred.lower()
        if normalized not in {"claude", "codex"}:
            raise ValueError(f"unsupported provider: {preferred}")
        alternate = "codex" if normalized == "claude" else "claude"
        return [(normalized, self.select(normalized)), (alternate, self.select(alternate))]


class CommandProviderAdapter:
    """Run a signed-in provider wrapper without invoking a shell."""

    def __init__(
        self,
        provider: str,
        argv: list[str],
        *,
        executable_lookup: Callable[[str], Optional[str]] = shutil.which,
    ):
        if not argv or not all(isinstance(item, str) and item for item in argv):
            raise ValueError("provider adapter argv must be a non-empty string list")
        self.provider = provider
        self.argv = list(argv)
        self.executable_lookup = executable_lookup

    def start_iteration(self, state: GoalState, assignment: RoleAssignment) -> ProviderResult:
        return self._run(state, assignment, {"task": "bounded implementation iteration"})

    def resume_session(
        self, state: GoalState, assignment: RoleAssignment, session_id: str
    ) -> ProviderResult:
        if not session_id:
            return ProviderResult(error="provider session id is required to resume a session", cost_usd=None)
        return self._run(
            state,
            assignment,
            {"task": "resume provider session", "resume_session_id": session_id},
        )

    def start_advisor(
        self, state: GoalState, incident: Mapping[str, Any], assignment: RoleAssignment
    ) -> ProviderResult:
        return self._run(state, assignment, {"task": "advisor review", "incident": dict(incident)})

    def _run(
        self, state: GoalState, assignment: RoleAssignment, extra: Mapping[str, Any]
    ) -> ProviderResult:
        payload = {
            "provider": self.provider,
            "role_assignment": dataclasses.asdict(assignment),
            "run_id": state.run_id,
            "goal": state.goal,
            "acceptance_criteria": state.acceptance_criteria,
            "iteration": state.iteration_count,
            "head_sha": state.head_sha,
            "worktree": state.worktree,
            "branch": state.branch,
            "current_phase": state.current_phase,
            "current_task": state.current_task,
            **extra,
        }
        executable = self.argv[0]
        if self.executable_lookup(executable) is None and not Path(executable).is_file():
            return ProviderResult(
                error=f"{self.provider} wrapper executable is unavailable: {executable}",
                human_action_required=f"install or authenticate the {self.provider} wrapper",
                failure_kind="provider_unavailable",
                outcome_known=True,
            )
        try:
            wall_limit = state.limits.get("max_wall_clock_seconds")
            if wall_limit is None:
                timeout = 3600.0
            else:
                remaining = float(wall_limit) - float(state.wall_clock_seconds)
                timeout = min(3600.0, max(0.001, remaining))
            result = subprocess.run(
                self.argv,
                cwd=state.worktree,
                input=json.dumps(payload),
                capture_output=True,
                text=True,
                shell=False,
                check=False,
                timeout=timeout,
            )
        except OSError as exc:
            return ProviderResult(
                error=f"{self.provider} adapter could not start: {exc}",
                human_action_required=f"start or authenticate the {self.provider} wrapper",
                failure_kind="provider_unavailable",
                outcome_known=True,
                cost_usd=None,
            )
        except subprocess.SubprocessError as exc:
            return ProviderResult(
                error=f"{self.provider} adapter outcome is unknown: {exc}",
                failure_kind="unknown",
                outcome_known=False,
                cost_usd=None,
            )
        output = (result.stdout or "") + (result.stderr or "")
        if result.returncode != 0:
            # Expected limit/unavailable responses must use the JSON contract
            # even when the wrapper exits non-zero.  Free-form stderr is never
            # enough evidence to retry: the command may have made changes.
            try:
                raw_failure = json.loads(result.stdout)
            except (json.JSONDecodeError, TypeError):
                raw_failure = None
            if isinstance(raw_failure, dict) and raw_failure.get("failure_kind") in {
                "provider_unavailable", "usage_limited"
            } and raw_failure.get("outcome_known") is True:
                return ProviderResult(
                    error=raw_failure.get("error") or output[-2000:],
                    human_action_required=raw_failure.get("human_action_required"),
                    failure_kind=raw_failure["failure_kind"],
                    outcome_known=True,
                    output=str(raw_failure.get("output", output))[-4000:],
                    cost_usd=0.0,
                )
            return ProviderResult(
                error=f"{self.provider} adapter outcome is unknown after exit {result.returncode}: {output[-2000:]}",
                output=output[-4000:],
                failure_kind="unknown",
                outcome_known=False,
                cost_usd=None,
            )
        try:
            raw = json.loads(result.stdout)
        except (json.JSONDecodeError, TypeError) as exc:
            return ProviderResult(
                error=f"{self.provider} adapter returned invalid JSON: {exc}",
                output=output[-4000:],
                failure_kind="unknown",
                outcome_known=False,
                cost_usd=None,
            )
        if not isinstance(raw, dict):
            return ProviderResult(
                error=f"{self.provider} adapter returned a non-object result",
                output=output[-4000:],
                failure_kind="unknown",
                outcome_known=False,
                cost_usd=None,
            )
        raw_cost = raw.get("cost_usd")
        if raw_cost is not None:
            try:
                raw_cost = float(raw_cost)
            except (TypeError, ValueError):
                return ProviderResult(error="provider adapter returned invalid cost_usd", output=output[-4000:], failure_kind="unknown", outcome_known=False, cost_usd=None)
            if not math.isfinite(raw_cost) or raw_cost < 0:
                return ProviderResult(error="provider adapter returned non-finite or negative cost_usd", output=output[-4000:], failure_kind="unknown", outcome_known=False, cost_usd=None)
        failure_kind = raw.get("failure_kind")
        if failure_kind is not None and failure_kind not in {
            "provider_unavailable", "usage_limited", "unknown"
        }:
            return ProviderResult(
                error="provider adapter returned an unsupported failure_kind",
                output=output[-4000:], failure_kind="unknown", outcome_known=False, cost_usd=None,
            )
        return ProviderResult(
            session_id=raw.get("session_id"),
            changed=bool(raw.get("changed")),
            completed=bool(raw.get("completed")),
            output=str(raw.get("output", output))[-4000:],
            error=raw.get("error"),
            human_action_required=raw.get("human_action_required"),
            failure_kind=failure_kind,
            # A safe fallback requires an explicit JSON boolean true.  A
            # missing/false/non-boolean value must not turn an unclassified
            # wrapper response into permission to repeat work.
            outcome_known=(
                raw.get("outcome_known", True)
                if failure_kind is None
                else raw.get("outcome_known") is True
            ),
            wall_clock_seconds=float(raw.get("wall_clock_seconds", 0.0)),
            cost_usd=raw_cost,
            new_head_sha=raw.get("new_head_sha"),
        )

    def inspect_session(self, session_id: str) -> Mapping[str, Any]:
        return {"status": "unknown", "session_id": session_id, "reason": "wrapper recovery is not implemented"}

    def capabilities(self) -> Mapping[str, bool]:
        executable = self.argv[0]
        return {
            "local_cli": self.executable_lookup(executable) is not None or Path(executable).is_file(),
            "remote_status": False,
            "remote_resume": False,
            "remote_pause": False,
            "mobile": False,
        }


class JiraStewardAdapter:
    """Adapter boundary for the existing jira-workflow-steward path.

    The callable is supplied by the host agent/session. This class deliberately
    has no acli or HTTP implementation, so it cannot bypass delegation tokens,
    phase maps, or Jira safety policy.
    """

    def __init__(self, steward_call: Callable[[Mapping[str, Any]], Mapping[str, Any]]):
        self.steward_call = steward_call

    @classmethod
    def from_environment(cls) -> Optional["JiraStewardAdapter"]:
        """Create the host-provided steward bridge without giving the runtime raw acli access."""
        command = os.environ.get("GOAL_LOOP_JIRA_STEWARD_COMMAND", "").strip()
        if not command:
            return None
        try:
            argv = shlex.split(command)
        except ValueError as exc:
            raise GoalLoopError(f"invalid GOAL_LOOP_JIRA_STEWARD_COMMAND: {exc}") from exc
        if not argv:
            raise GoalLoopError("GOAL_LOOP_JIRA_STEWARD_COMMAND cannot be empty")

        def call(request: Mapping[str, Any]) -> Mapping[str, Any]:
            try:
                result = subprocess.run(
                    argv, input=json.dumps(dict(request)), capture_output=True,
                    text=True, shell=False, check=False, timeout=60,
                )
            except (OSError, subprocess.SubprocessError) as exc:
                raise GoalLoopError(f"Jira steward bridge failed: {exc}") from exc
            if result.returncode != 0:
                raise GoalLoopError(f"Jira steward bridge exited {result.returncode}: {result.stderr[-1000:]}")
            try:
                payload = json.loads(result.stdout)
            except (json.JSONDecodeError, TypeError) as exc:
                raise GoalLoopError("Jira steward bridge returned invalid JSON") from exc
            if not isinstance(payload, Mapping):
                raise GoalLoopError("Jira steward bridge returned a non-object result")
            expected_action = request.get("action_id")
            if expected_action and payload.get("action_id") != expected_action:
                raise GoalLoopError("Jira steward bridge returned a mismatched action_id")
            if not (
                payload.get("ok") is True
                or str(payload.get("status", "")).lower()
                in {"ok", "success", "succeeded", "applied", "already_applied"}
            ):
                raise GoalLoopError("Jira steward bridge did not confirm success")
            return payload

        return cls(call)

    def progress(self, state: GoalState, action_id: str) -> Mapping[str, Any]:
        return self.steward_call(
            {
                "path": "jira-workflow-steward",
                "operation": "phase-progress",
                "key": state.jira.get("key"),
                "phase": state.current_phase,
                "action_id": action_id,
                "marker": f"goal-run:{state.run_id}:iteration:{state.iteration_count}",
                "comment": (
                    f"GoalRun {state.run_id} iteration {state.iteration_count}: "
                    f"{state.next_action or 'progress recorded'}"
                ),
            }
        )

    def create_from_proposal(
        self, state: GoalState, proposal: AdvisoryProposal, action_id: str
    ) -> Mapping[str, Any]:
        """Delegate approved advisory work creation to the existing steward."""
        proposal_id = _advisory_proposal_id(state.run_id, dataclasses.asdict(proposal))
        approval = next(
            (
                item for item in state.approved_advisory_proposals
                if item.get("proposal_id") == proposal_id
            ),
            None,
        )
        if approval is None:
            raise GoalLoopError(
                "advisory proposal must be explicitly approved before Jira handoff"
            )
        if approval.get("approval_action_id") != action_id:
            raise GoalLoopError(
                "Jira handoff action does not match the advisory approval action"
            )
        if not proposal.title.strip():
            raise GoalLoopError("advisory proposal cannot create Jira work without a summary")
        if not proposal.acceptance_criteria:
            raise GoalLoopError(
                "advisory proposal cannot create Jira work without acceptance criteria"
            )
        if not proposal.evidence:
            raise GoalLoopError(
                "advisory proposal cannot create Jira work without evidence"
            )
        issue_type = {
            "bug": "Bug",
            "feature": "Story",
            "refactor": "Task",
            "security": "Bug",
            "performance": "Task",
            "reliability": "Task",
            "documentation": "Task",
        }.get(proposal.kind.lower(), "Task")
        # The action id is the durable idempotency key. Keep the successful
        # result in GoalState as a fast path across calls and process
        # restarts; the steward bridge must also deduplicate the same key
        # because a crash can occur after Jira accepts the request but before
        # the checkpoint is written.
        created = state.jira.setdefault("created_work_items", {})
        if not isinstance(created, dict):
            raise GoalLoopError("persisted Jira created_work_items must be an object")
        stored = created.get(action_id)
        if isinstance(stored, Mapping):
            return dict(stored)
        result = self.steward_call(
            {
                "path": "jira-workflow-steward",
                "operation": "create-work-item",
                "action_id": action_id,
                "idempotency_key": action_id,
                "marker": f"goal-run:{state.run_id}:advisory:{proposal_id}",
                "kind": proposal.kind,
                "issue_type": issue_type,
                "priority": proposal.jira_priority,
                "summary": proposal.title,
                "description": {
                    "background": proposal.impact,
                    "scope": proposal.scope,
                    "acceptance_criteria": proposal.acceptance_criteria,
                    "evidence": proposal.evidence,
                    "confidence": proposal.confidence,
                    "risk": proposal.risk,
                    "alternatives": proposal.alternatives,
                    "workflow": proposal.workflow,
                },
                "jira_key": state.jira.get("key"),
            }
        )
        created[action_id] = dict(result)
        return result

    def reconcile(
        self, state: GoalState, action_id: str, payload: Mapping[str, Any]
    ) -> Mapping[str, Any]:
        return self.steward_call(
            {
                "path": "jira-workflow-steward",
                "operation": "reconcile-phase-progress",
                "key": state.jira.get("key"),
                "phase": payload.get("phase"),
                "action_id": action_id,
                "marker": f"goal-run:{state.run_id}:iteration:{payload.get('iteration')}",
            }
        )


@dataclasses.dataclass
class Assessment:
    classification: AdvisorClass
    reason: str
    evidence: dict[str, Any]
    next_action: Optional[str] = None


@dataclasses.dataclass
class GoalState:
    schema_version: int
    run_id: str
    goal: str
    acceptance_criteria: list[str]
    verifier_ids: list[str]
    repo: str
    worktree: str
    branch: str
    head_sha: str
    current_phase: str
    current_task: str
    planner_identity: str
    worker_identity: str
    monitor_identity: str
    status: RunStatus
    iteration_count: int
    wall_clock_seconds: float
    cost_usd: Optional[float]
    last_action: Optional[dict[str, Any]]
    last_verification: Optional[list[dict[str, Any]]]
    last_advisor_assessment: Optional[dict[str, Any]]
    pending_advisor_review: Optional[dict[str, Any]]
    pending_advisor_reviews: list[dict[str, Any]]
    advisory_proposals: list[dict[str, Any]]
    approved_advisory_proposals: list[dict[str, Any]]
    pending_human_action: Optional[str]
    next_action: Optional[str]
    stop_reason: Optional[str]
    provider: str
    provider_session_id: Optional[str]
    jira: dict[str, Any]
    beads: dict[str, Any]
    created_at: str
    updated_at: str
    checkpointed_at: Optional[str]
    limits: dict[str, Any]
    extra_fields: dict[str, Any] = dataclasses.field(default_factory=dict, repr=False)

    @classmethod
    def from_dict(cls, raw: Mapping[str, Any]) -> "GoalState":
        required = {
            "schema_version", "run_id", "goal", "acceptance_criteria",
            "verifier_ids", "repo", "worktree", "branch", "head_sha",
            "current_phase", "current_task", "status", "iteration_count",
            "wall_clock_seconds", "last_action", "last_verification",
            "last_advisor_assessment", "pending_human_action", "next_action",
            "stop_reason", "provider", "provider_session_id", "jira", "beads",
            "created_at", "updated_at", "checkpointed_at", "limits", "cost_usd",
        }
        missing = required - set(raw)
        if missing:
            raise StateError("state is missing fields: " + ", ".join(sorted(missing)))
        if raw["schema_version"] != SCHEMA_VERSION:
            raise StateError(f"unsupported state schema: {raw['schema_version']}")
        known_fields = {
            field.name for field in dataclasses.fields(cls)
            if field.name != "extra_fields"
        }
        extras = {
            key: value for key, value in raw.items()
            if key not in known_fields
        }
        try:
            status = RunStatus(raw["status"])
            return cls(
                schema_version=int(raw["schema_version"]),
                run_id=str(raw["run_id"]),
                goal=str(raw["goal"]),
                acceptance_criteria=list(raw["acceptance_criteria"]),
                verifier_ids=list(raw["verifier_ids"]),
                repo=str(raw["repo"]),
                worktree=str(raw["worktree"]),
                branch=str(raw["branch"]),
                head_sha=str(raw["head_sha"]),
                current_phase=str(raw["current_phase"]),
                current_task=str(raw["current_task"]),
                planner_identity=str(raw.get("planner_identity", "fable")),
                worker_identity=str(raw.get("worker_identity", "opus")),
                monitor_identity=str(raw.get("monitor_identity", "haiku")),
                status=status,
                iteration_count=int(raw["iteration_count"]),
                wall_clock_seconds=float(raw["wall_clock_seconds"]),
                cost_usd=None if raw["cost_usd"] is None else float(raw["cost_usd"]),
                last_action=raw["last_action"],
                last_verification=raw["last_verification"],
                last_advisor_assessment=raw["last_advisor_assessment"],
                pending_advisor_review=raw.get("pending_advisor_review"),
                pending_advisor_reviews=(
                    list(raw["pending_advisor_reviews"])
                    if isinstance(raw.get("pending_advisor_reviews"), list)
                    else ([raw["pending_advisor_review"]] if isinstance(raw.get("pending_advisor_review"), dict) else [])
                ),
                advisory_proposals=(
                    list(raw["advisory_proposals"])
                    if isinstance(raw.get("advisory_proposals"), list)
                    else []
                ),
                approved_advisory_proposals=(
                    list(raw["approved_advisory_proposals"])
                    if isinstance(raw.get("approved_advisory_proposals"), list)
                    else []
                ),
                pending_human_action=raw["pending_human_action"],
                next_action=raw["next_action"],
                stop_reason=raw["stop_reason"],
                provider=str(raw["provider"]),
                provider_session_id=raw["provider_session_id"],
                jira=dict(raw["jira"]),
                beads=dict(raw["beads"]),
                created_at=str(raw["created_at"]),
                updated_at=str(raw["updated_at"]),
                checkpointed_at=raw["checkpointed_at"],
                limits=dict(raw["limits"]),
                extra_fields=extras,
            )
        except (KeyError, TypeError, ValueError) as exc:
            raise StateError(f"invalid GoalRun state: {exc}") from exc

    def to_dict(self) -> dict[str, Any]:
        result = dataclasses.asdict(self)
        result.pop("extra_fields", None)
        result["status"] = self.status.value
        result.update(self.extra_fields)
        return result


def _now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _worktree_fingerprint(worktree: Path | str) -> str:
    """Hash tracked and untracked content so evidence is bound to the tree tested."""
    root = Path(worktree).resolve()
    digest = hashlib.sha256()
    try:
        diff = subprocess.run(
            ["git", "-C", str(root), "diff", "--binary", "HEAD"],
            capture_output=True, check=False, shell=False, timeout=30,
        )
        if diff.returncode != 0:
            return "nogit:" + hashlib.sha256(str(root).encode()).hexdigest()
        digest.update(diff.stdout)
        files = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "-z"],
            capture_output=True, check=False, shell=False, timeout=30,
        )
        if files.returncode != 0:
            return "nogit:" + hashlib.sha256(str(root).encode()).hexdigest()
        for raw_path in files.stdout.split(b"\0"):
            if not raw_path:
                continue
            path = root / os.fsdecode(raw_path)
            digest.update(raw_path)
            try:
                digest.update(path.read_bytes())
            except OSError:
                return "unreadable:" + hashlib.sha256(str(path).encode()).hexdigest()
        return digest.hexdigest()
    except (OSError, subprocess.SubprocessError):
        return "unavailable:" + hashlib.sha256(str(root).encode()).hexdigest()


def _stable_id(run_id: str, iteration: int, action_type: str, payload: Any) -> str:
    material = json.dumps(
        [run_id, iteration, action_type, payload],
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    ).encode()
    return "act_" + hashlib.sha256(material).hexdigest()[:24]


def _advisory_proposal_id(run_id: str, proposal: Mapping[str, Any]) -> str:
    material = json.dumps(
        [run_id, {key: value for key, value in proposal.items() if key != "proposal_id"}],
        sort_keys=True,
        separators=(",", ":"),
        default=str,
    ).encode()
    return "adv_" + hashlib.sha256(material).hexdigest()[:24]


class GoalStore:
    """Crash-safe state, journal, and lease storage for goal runs."""

    def __init__(self, root: Path | str):
        self.root = Path(root)
        self._ensure_directory(self.root)

    @staticmethod
    def _ensure_directory(path: Path) -> None:
        if path.exists() and (path.is_symlink() or not path.is_dir()):
            raise StateError(f"unsafe state directory: {path}")
        path.mkdir(parents=True, exist_ok=True)
        if path.is_symlink():
            raise StateError(f"unsafe state directory: {path}")

    def _run_dir(self, run_id: str) -> Path:
        if not run_id or run_id in {".", ".."} or Path(run_id).name != run_id or "/" in run_id:
            raise StateError("invalid run id")
        path = self.root / run_id
        if self.root.is_symlink():
            raise StateError(f"unsafe state directory: {self.root}")
        if path.exists() and (path.is_symlink() or not path.is_dir()):
            raise StateError(f"unsafe run directory: {path}")
        path.mkdir(exist_ok=True)
        return path

    def state_path(self, run_id: str) -> Path:
        return self._run_dir(run_id) / "state.json"

    def _path(self, run_id: str, name: str) -> Path:
        return self._run_dir(run_id) / name

    @staticmethod
    def _reject_symlink(path: Path) -> None:
        if path.is_symlink():
            raise StateError(f"refusing symlink state file: {path}")

    @staticmethod
    def _lease_expiry(lease: Any) -> float:
        if not isinstance(lease, dict):
            raise LeaseError("lease is not a JSON object")
        try:
            expiry = float(lease["expires_at"])
        except (KeyError, TypeError, ValueError) as exc:
            raise LeaseError("lease has invalid expiry evidence") from exc
        if not math.isfinite(expiry):
            raise LeaseError("lease has non-finite expiry evidence")
        return expiry

    @contextmanager
    def _lease_lock(self, run_id: str):
        """Serialize lease takeover/renewal/release within this state store."""

        import fcntl

        path = self._path(run_id, "lease.lock")
        self._reject_symlink(path)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def create(
        self,
        *,
        goal: str,
        acceptance_criteria: list[str],
        verifier_ids: list[str],
        repo: Path | str,
        worktree: Path | str,
        branch: str,
        head_sha: str,
        provider: str,
        jira_key: Optional[str] = None,
        max_wall_clock_seconds: Optional[float] = None,
        max_cost_usd: Optional[float] = None,
        max_iterations: Optional[int] = None,
        mutation_policy: str = "auto",
        test_only: bool = False,
        run_id: Optional[str] = None,
        current_phase: str = "in_progress",
        current_task: str = "goal run",
    ) -> GoalState:
        run_id = run_id or "gr_" + time.strftime("%Y%m%d%H%M%S") + "_" + uuid.uuid4().hex[:8]
        now = _now()
        state = GoalState(
            schema_version=SCHEMA_VERSION,
            run_id=run_id,
            goal=goal,
            acceptance_criteria=list(acceptance_criteria),
            verifier_ids=list(verifier_ids),
            repo=str(Path(repo).resolve()),
            worktree=str(Path(worktree).resolve()),
            branch=branch,
            head_sha=head_sha,
            current_phase=current_phase,
            current_task=current_task,
            planner_identity="fable" if provider == "claude" else "gpt-6-astra",
            worker_identity="opus" if provider == "claude" else "luna",
            monitor_identity="haiku" if provider == "claude" else "lightweight",
            status=RunStatus.RUNNING,
            iteration_count=0,
            wall_clock_seconds=0.0,
            cost_usd=0.0,
            last_action=None,
            last_verification=None,
            last_advisor_assessment=None,
            pending_advisor_review=None,
            pending_advisor_reviews=[],
            advisory_proposals=[],
            approved_advisory_proposals=[],
            pending_human_action=None,
            next_action="run worker iteration",
            stop_reason=None,
            provider=provider,
            provider_session_id=None,
            jira={"key": jira_key, "phase": None, "action_ids": [], "last_result": None},
            beads={"enabled": (Path(repo) / ".beads").is_dir(), "id": None, "last_result": None},
            created_at=now,
            updated_at=now,
            checkpointed_at=None,
            limits={
                "max_wall_clock_seconds": (
                    DEFAULT_MAX_WALL_CLOCK_SECONDS if max_wall_clock_seconds is None else max_wall_clock_seconds
                ),
                "max_cost_usd": DEFAULT_MAX_COST_USD if max_cost_usd is None else max_cost_usd,
                "max_iterations": DEFAULT_MAX_ITERATIONS if max_iterations is None else max_iterations,
                "no_progress_after": 2,
                "mutation_policy": mutation_policy,
                "test_only": bool(test_only),
            },
        )
        if self.state_path(run_id).exists():
            raise StateError(f"run already exists: {run_id}")
        self.save(state)
        self.append_event(run_id, {"type": "run.created", "run_id": run_id})
        return state

    def load(self, run_id: str) -> GoalState:
        path = self.state_path(run_id)
        if not path.exists() or not path.is_file():
            raise StateError(f"state not found: {path}")
        self._reject_symlink(path)
        try:
            raw = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise StateError(f"cannot read state: {path}") from exc
        if not isinstance(raw, dict):
            raise StateError("state must be a JSON object")
        return GoalState.from_dict(raw)

    def save(self, state: GoalState) -> None:
        path = self.state_path(state.run_id)
        self._reject_symlink(path)
        fd, temporary = tempfile.mkstemp(prefix=".state-", suffix=".tmp", dir=self._run_dir(state.run_id))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(state.to_dict(), handle, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
            try:
                directory_fd = os.open(self._run_dir(state.run_id), os.O_RDONLY)
                try:
                    os.fsync(directory_fd)
                finally:
                    os.close(directory_fd)
            except OSError:
                pass
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)

    def update(
        self, state: GoalState, *, lease: Optional[Mapping[str, Any]] = None
    ) -> GoalState:
        if lease is not None:
            # Keep the lease lock across validation and the atomic checkpoint;
            # a successor cannot take over between the fence and os.replace.
            with self._lease_lock(state.run_id):
                path = self._path(state.run_id, "lease.json")
                self._reject_symlink(path)
                try:
                    current = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError) as exc:
                    raise LeaseError("lease is unreadable") from exc
                expiry = self._lease_expiry(current)
                if (
                    current.get("owner") != lease.get("owner")
                    or current.get("token") != lease.get("token")
                    or current.get("generation") != lease.get("generation")
                    or expiry <= time.time()
                ):
                    raise LeaseFenceError("lease fence rejected stale worker")
                state.updated_at = _now()
                state.checkpointed_at = state.updated_at
                self.save(state)
                return state
        state.updated_at = _now()
        state.checkpointed_at = state.updated_at
        self.save(state)
        return state

    def events(self, run_id: str) -> list[dict[str, Any]]:
        path = self._path(run_id, "events.jsonl")
        if not path.exists():
            return []
        self._reject_symlink(path)
        result = []
        try:
            for line in path.read_text(encoding="utf-8").splitlines():
                if line.strip():
                    result.append(json.loads(line))
        except (OSError, json.JSONDecodeError) as exc:
            raise StateError(f"cannot read event journal: {path}") from exc
        return result

    def incomplete_runs(self) -> list[GoalState]:
        terminal = {RunStatus.COMPLETED, RunStatus.CANCELLED}
        states = []
        for child in sorted(self.root.iterdir()):
            if not child.is_dir() or child.is_symlink() or not (child / "state.json").exists():
                continue
            state = self.load(child.name)
            if state.status not in terminal:
                states.append(state)
        return states

    def append_event(self, run_id: str, event: Mapping[str, Any]) -> None:
        path = self._path(run_id, "events.jsonl")
        self._reject_symlink(path)
        record = dict(event)
        record.setdefault("timestamp", _now())
        data = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode()
        flags = os.O_WRONLY | os.O_CREAT | os.O_APPEND
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            fd = os.open(path, flags, 0o600)
            with os.fdopen(fd, "ab") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            raise StateError(f"cannot append journal: {path}") from exc

    def record_intent(self, run_id: str, action_type: str, payload: Mapping[str, Any]) -> str:
        state = self.load(run_id)
        action_id = _stable_id(run_id, state.iteration_count + 1, action_type, payload)
        self.append_event(
            run_id,
            {
                "type": "action.intent",
                "action_id": action_id,
                "action_type": action_type,
                "payload": dict(payload),
                "status": "INTENT",
            },
        )
        return action_id

    def record_action_result(
        self, run_id: str, action_id: str, status: str, result: Mapping[str, Any],
        *, lease: Optional[Mapping[str, Any]] = None,
    ) -> None:
        event = {
            "type": "action.result",
            "action_id": action_id,
            "status": status,
            "result": dict(result),
        }
        if lease is None:
            self.append_event(run_id, event)
            return
        # Hold the lease lock while validating and appending. Takeover cannot
        # occur between the fence check and the journal write.
        with self._lease_lock(run_id):
            path = self._path(run_id, "lease.json")
            self._reject_symlink(path)
            try:
                current = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise LeaseError("lease is unreadable") from exc
            current_expiry = self._lease_expiry(current)
            if (
                current.get("owner") != lease.get("owner")
                or current.get("token") != lease.get("token")
                or current.get("generation") != lease.get("generation")
                or current_expiry <= time.time()
            ):
                raise LeaseFenceError("lease fence rejected stale worker")
            self.append_event(run_id, event)

    def record_operational_incident(
        self,
        run_id: str,
        incident_type: str,
        evidence: Mapping[str, Any],
    ) -> str:
        """Persist one avoidable failure and require the next advisor cycle to act."""

        state = self.load(run_id)
        material = {"type": incident_type, "evidence": dict(evidence)}
        incident_id = "inc_" + hashlib.sha256(
            json.dumps(
                [run_id, state.iteration_count, material],
                sort_keys=True,
                separators=(",", ":"),
                default=str,
            ).encode()
        ).hexdigest()[:24]
        if any(event.get("incident_id") == incident_id for event in self.events(run_id)):
            return incident_id
        self.append_event(
            run_id,
            {
                "type": "self_improvement.incident",
                "incident_id": incident_id,
                "incident_type": incident_type,
                "evidence": dict(evidence),
            },
        )
        self.append_event(
            run_id,
            {
                "type": "self_improvement.advisor_review_required",
                "incident_id": incident_id,
                "status": "PENDING",
            },
        )
        incident = {
            "incident_id": incident_id,
            "incident_type": incident_type,
            "evidence": dict(evidence),
        }
        state.pending_advisor_reviews = [
            *state.pending_advisor_reviews,
            incident,
        ]
        state.pending_advisor_review = state.pending_advisor_reviews[0]
        self.update(state)
        return incident_id

    def record_advisor_action(
        self,
        run_id: str,
        incident: Mapping[str, Any],
        recommendation: str,
        action: str,
    ) -> str:
        """Record an idempotent advisor response and clear its pending review."""

        state = self.load(run_id)
        payload = {
            "incident_id": incident["incident_id"],
            "recommendation": recommendation,
            "action": action,
        }
        action_id = _stable_id(run_id, state.iteration_count, "self_improvement.advisor_action", payload)
        if not any(event.get("action_id") == action_id for event in self.events(run_id)):
            self.append_event(
                run_id,
                {
                    "type": "self_improvement.advisor_action",
                    "action_id": action_id,
                    **payload,
                    "status": "RECORDED",
                },
            )
        state.pending_advisor_reviews = [
            item for item in state.pending_advisor_reviews
            if item.get("incident_id") != incident.get("incident_id")
        ]
        state.pending_advisor_review = state.pending_advisor_reviews[0] if state.pending_advisor_reviews else None
        self.update(state)
        return action_id

    def record_advisory_proposals(
        self, run_id: str, proposals: list[Any]
    ) -> list[dict[str, Any]]:
        """Persist the latest ranked proposals so an advisor can resume safely."""

        state = self.load(run_id)
        serialized: list[dict[str, Any]] = []
        for proposal in proposals:
            if dataclasses.is_dataclass(proposal):
                item = dataclasses.asdict(proposal)
            elif isinstance(proposal, Mapping):
                item = dict(proposal)
            else:
                raise StateError("advisory proposal must be a dataclass or mapping")
            item["proposal_id"] = _advisory_proposal_id(run_id, item)
            serialized.append(item)
        if state.advisory_proposals == serialized:
            return serialized
        self.append_event(
            run_id,
            {
                "type": "advisory.proposals.recorded",
                "proposal_ids": [item["proposal_id"] for item in serialized],
                "proposals": serialized,
            },
        )
        state.advisory_proposals = serialized
        self.update(state)
        return serialized

    def approve_advisory_proposal(
        self, run_id: str, proposal_id: str
    ) -> dict[str, Any]:
        """Persist explicit approval without performing the external Jira write."""

        state = self.load(run_id)
        proposal = next(
            (
                item for item in state.advisory_proposals
                if item.get("proposal_id") == proposal_id
            ),
            None,
        )
        if proposal is None:
            raise StateError(f"advisory proposal not found: {proposal_id}")
        existing = next(
            (
                item for item in state.approved_advisory_proposals
                if item.get("proposal_id") == proposal_id
            ),
            None,
        )
        action_id = _stable_id(
            run_id, 0, "advisory.proposal.approval", {"proposal_id": proposal_id}
        )
        if existing is not None:
            return dict(existing)
        approval = {**proposal, "approval_action_id": action_id, "status": "APPROVED"}
        self.append_event(
            run_id,
            {
                "type": "advisory.proposal.approved",
                "proposal_id": proposal_id,
                "action_id": action_id,
                "status": "APPROVED",
            },
        )
        state.approved_advisory_proposals = [
            *state.approved_advisory_proposals, approval
        ]
        self.update(state)
        return approval

    def pending_actions(self, run_id: str) -> list[dict[str, Any]]:
        intents: dict[str, dict[str, Any]] = {}
        results: dict[str, str] = {}
        for event in self.events(run_id):
            if event.get("type") == "action.intent":
                intents[event["action_id"]] = event
            elif event.get("type") == "action.result":
                results[event["action_id"]] = event.get("status", "")
        return [
            event for action_id, event in intents.items()
            if results.get(action_id) not in {"SUCCEEDED", "FAILED", "SKIPPED"}
        ]

    def completed_actions(self, run_id: str) -> list[tuple[dict[str, Any], dict[str, Any]]]:
        """Return journaled intent/result pairs for crash-checkpoint recovery."""

        intents: dict[str, dict[str, Any]] = {}
        results: dict[str, dict[str, Any]] = {}
        for event in self.events(run_id):
            if event.get("type") == "action.intent":
                intents[event["action_id"]] = event
            elif event.get("type") == "action.result":
                results[event["action_id"]] = event
        return [
            (intent, results[action_id])
            for action_id, intent in intents.items()
            if action_id in results and results[action_id].get("status") == "SUCCEEDED"
        ]

    def acquire_lease(self, run_id: str, owner: str, ttl: float = 300) -> dict[str, Any]:
        path = self._path(run_id, "lease.json")
        with self._lease_lock(run_id):
            now = time.time()
            lease = {
                "owner": owner,
                "token": uuid.uuid4().hex,
                "generation": 1,
                "acquired_at": now,
                "heartbeat_at": now,
                "expires_at": now + ttl,
            }
            self._reject_symlink(path)
            if path.exists():
                try:
                    existing = json.loads(path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError) as exc:
                    raise LeaseError("lease exists but is unreadable") from exc
                if self._lease_expiry(existing) > now:
                    raise LeaseError(f"run {run_id} is leased by {existing.get('owner')}")
                # The lock makes expiry takeover a compare-and-swap operation
                # for every GoalStore worker; no stale owner can unlink a new lease.
                path.unlink()
                lease["generation"] = int(existing.get("generation", 0)) + 1
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(lease, handle)
                handle.flush()
                os.fsync(handle.fileno())
        self.append_event(run_id, {"type": "lease.acquired", "owner": owner})
        return lease

    def renew_lease(self, run_id: str, lease: Mapping[str, Any], ttl: float = 300) -> dict[str, Any]:
        path = self._path(run_id, "lease.json")
        with self._lease_lock(run_id):
            self._reject_symlink(path)
            try:
                current = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise LeaseError("lease is unreadable") from exc
            current_expiry = self._lease_expiry(current)
            if (
                current.get("owner") != lease.get("owner")
                or current.get("token") != lease.get("token")
                or current.get("generation") != lease.get("generation")
            ):
                raise LeaseFenceError("lease token mismatch")
            now = time.time()
            if current_expiry <= now:
                raise LeaseFenceError("lease expired; stale worker cannot renew it")
            refreshed = dict(current, heartbeat_at=now, expires_at=now + ttl)
            temporary = path.with_name(f".lease-{uuid.uuid4().hex}.tmp")
            try:
                temporary.write_text(json.dumps(refreshed), encoding="utf-8")
                os.replace(temporary, path)
            finally:
                if temporary.exists():
                    temporary.unlink()
            return refreshed

    def assert_lease_current(self, run_id: str, lease: Mapping[str, Any]) -> None:
        """Fence stale workers before and after every external action."""

        path = self._path(run_id, "lease.json")
        with self._lease_lock(run_id):
            self._reject_symlink(path)
            try:
                current = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise LeaseError("lease is unreadable") from exc
            current_expiry = self._lease_expiry(current)
            if (
                current.get("owner") != lease.get("owner")
                or current.get("token") != lease.get("token")
                or current.get("generation") != lease.get("generation")
                or current_expiry <= time.time()
            ):
                raise LeaseFenceError("lease fence rejected stale worker")

    def release_lease(self, run_id: str, lease: Mapping[str, Any]) -> None:
        path = self._path(run_id, "lease.json")
        if not path.exists():
            return
        with self._lease_lock(run_id):
            self._reject_symlink(path)
            try:
                current = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise LeaseError("lease is unreadable") from exc
            self._lease_expiry(current)
            if (
                current.get("owner") != lease.get("owner")
                or current.get("token") != lease.get("token")
                or current.get("generation") != lease.get("generation")
            ):
                # A replacement worker owns the lease; an old worker must not
                # remove or otherwise disturb the replacement's lease.
                return
            path.unlink()
        self.append_event(run_id, {"type": "lease.released", "owner": lease["owner"]})

    def transition(self, run_id: str, target: RunStatus) -> GoalState:
        state = self.load(run_id)
        allowed = {
            RunStatus.RUNNING: {RunStatus.PAUSED, RunStatus.RESUMABLE, RunStatus.HUMAN_ACTION_REQUIRED,
                                RunStatus.BLOCKED, RunStatus.FAILED, RunStatus.COMPLETE_CANDIDATE},
            RunStatus.PAUSED: {RunStatus.RESUMABLE, RunStatus.RUNNING, RunStatus.CANCELLED},
            RunStatus.RESUMABLE: {RunStatus.RUNNING, RunStatus.PAUSED, RunStatus.CANCELLED},
            RunStatus.HUMAN_ACTION_REQUIRED: {RunStatus.RESUMABLE, RunStatus.RUNNING, RunStatus.CANCELLED},
            RunStatus.BLOCKED: {RunStatus.RESUMABLE, RunStatus.CANCELLED},
            RunStatus.FAILED: {RunStatus.RESUMABLE, RunStatus.CANCELLED},
            RunStatus.COMPLETE_CANDIDATE: {RunStatus.COMPLETED, RunStatus.RESUMABLE, RunStatus.HUMAN_ACTION_REQUIRED},
            RunStatus.COMPLETED: set(),
            RunStatus.CANCELLED: set(),
        }
        if target not in allowed[state.status]:
            raise StateError(f"illegal transition {state.status.value} -> {target.value}")
        old = state.status
        state.status = target
        self.append_event(run_id, {"type": "state.transition", "from": old.value, "to": target.value})
        return self.update(state)


class LeaseHeartbeat:
    """Keep a long-running provider action exclusive to its owner."""

    def __init__(self, store: GoalStore, run_id: str, lease: Mapping[str, Any], ttl: float):
        self.store = store
        self.run_id = run_id
        self.lease = dict(lease)
        self.ttl = ttl
        self.stop_event = threading.Event()
        self.lost = False
        self.thread: Optional[threading.Thread] = None

    def start(self) -> None:
        interval = max(0.1, min(self.ttl / 3, 30))

        def renew() -> None:
            while not self.stop_event.wait(interval):
                try:
                    self.lease = self.store.renew_lease(self.run_id, self.lease, self.ttl)
                except LeaseError:
                    self.lost = True
                    self.stop_event.set()
                    return

        self.thread = threading.Thread(
            target=renew, name=f"goal-loop-lease-{self.run_id}", daemon=True
        )
        self.thread.start()

    def stop(self) -> None:
        self.stop_event.set()
        if self.thread is not None:
            self.thread.join(timeout=1)


class ToolboxVerificationRegistry:
    """Resolve manifest presence to toolbox-owned, literal argv commands."""

    COMMANDS = {
        "dotnet": {
            "detect": ("*.sln", "*.csproj"),
            "commands": {
                "test": ("dotnet", "test"),
                "lint": ("dotnet", "format", "--verify-no-changes"),
                "build": ("dotnet", "build"),
            },
        },
        "maven-wrapper": {
            "detect": ("mvnw",),
            "commands": {"test": ("./mvnw", "test"), "build": ("./mvnw", "-DskipTests", "package")},
        },
        "maven": {
            "detect": ("pom.xml",),
            "commands": {"test": ("mvn", "test"), "build": ("mvn", "-DskipTests", "package")},
        },
        "gradle-wrapper": {
            "detect": ("gradlew",),
            "commands": {"test": ("./gradlew", "test"), "build": ("./gradlew", "assemble")},
        },
        "gradle": {
            "detect": ("build.gradle", "build.gradle.kts"),
            "commands": {"test": ("gradle", "test"), "build": ("gradle", "assemble")},
        },
        "node-pnpm": {
            "detect": ("pnpm-lock.yaml",),
            "commands": {
                "test": ("pnpm", "test"),
                "lint": ("pnpm", "run", "lint"),
                "build": ("pnpm", "run", "build"),
            },
        },
        "node-yarn": {
            "detect": ("yarn.lock",),
            "commands": {
                "test": ("yarn", "test"),
                "lint": ("yarn", "run", "lint"),
                "build": ("yarn", "run", "build"),
            },
        },
        "node-npm": {
            "detect": ("package.json",),
            "commands": {
                "test": ("npm", "test"),
                "lint": ("npm", "run", "lint"),
                "build": ("npm", "run", "build"),
            },
        },
        "python": {
            "detect": ("pyproject.toml", "pytest.ini", "setup.cfg"),
            "commands": {
                "test": ("python3", "-m", "pytest"),
                "lint": ("python3", "-m", "ruff", "check"),
            },
        },
        "scala-sbt": {
            "detect": ("build.sbt",),
            "commands": {
                "test": ("sbt", "test"),
                "build": ("sbt", "compile"),
            },
        },
    }

    def __init__(
        self,
        worktree: Path | str,
        *,
        baseline_sha: Optional[str] = None,
        command_runner: Optional[Callable[..., Any]] = None,
    ):
        self.worktree = Path(worktree).resolve()
        self.baseline_sha = baseline_sha
        self.command_runner = command_runner or self._subprocess_runner

    def _project_settings(self) -> dict[str, Any]:
        config = self.worktree / ".claude" / "PROJECT.md"
        try:
            text = config.read_text(encoding="utf-8")
        except OSError:
            return {}
        section_match = re.search(r"(?ms)^verification:\s*$([\s\S]*?)(?=^\S|\Z)", text)
        if not section_match:
            return {}
        section = section_match.group(1)
        settings: dict[str, Any] = {}
        runner = re.search(r"(?m)^\s+runner:\s*([^#\s]+)", section)
        if runner:
            settings["runner"] = runner.group(1).strip(" \\\"'")
        gates = re.search(r"(?ms)^\s+gates:\s*\[([^]]*)\]", section)
        if gates:
            settings["gates"] = [item.strip(" \\\"'") for item in gates.group(1).split(",") if item.strip()]
        coverage = re.search(r"(?m)^\s+coverage_floor:\s*([0-9]+(?:\.[0-9]+)?)", section)
        if coverage:
            settings["coverage_floor"] = float(coverage.group(1))
        return settings

    @staticmethod
    def _subprocess_runner(argv: list[str], **kwargs: Any) -> Any:
        return subprocess.run(argv, **kwargs)

    def _ecosystem(self) -> Optional[str]:
        configured = self._project_settings().get("runner")
        if configured and configured != "auto":
            if configured not in self.COMMANDS:
                raise VerificationError(f"verification.runner is not registered: {configured}")
            return configured
        for name, definition in self.COMMANDS.items():
            if any(any(self.worktree.glob(pattern)) for pattern in definition["detect"]):
                return name
        return None

    def mapping(self) -> dict[str, Callable[[Mapping[str, Any]], Mapping[str, Any]]]:
        ecosystem = self._ecosystem()
        if ecosystem is None:
            return {}
        commands = self.COMMANDS[ecosystem]["commands"]
        settings = self._project_settings()
        mapping = {
            key: (lambda context, argv=list(argv): self._run(argv, context))
            for key, argv in commands.items()
        }
        configured_gates = settings.get("gates")
        if configured_gates:
            mapping = {key: value for key, value in mapping.items() if key in configured_gates}
        mapping["mutation"] = MutationTestingRegistry(
            self.worktree,
            ecosystem=ecosystem,
            base_sha=self.baseline_sha,
            command_runner=self.command_runner,
        ).run
        return mapping

    def _run(self, argv: list[str], context: Mapping[str, Any]) -> Mapping[str, Any]:
        try:
            result = self.command_runner(
                list(argv),
                cwd=str(self.worktree),
                capture_output=True,
                text=True,
                shell=False,
                check=False,
                timeout=3600,
            )
            if isinstance(result, Mapping):
                return {
                    "status": "PASS" if result.get("returncode", 1) == 0 else "FAIL",
                    "exit_code": result.get("returncode"),
                    "output": (str(result.get("stdout", "")) + str(result.get("stderr", "")))[-4000:],
                    "sha": context["current_sha"],
                "worktree": context["worktree"],
                "worktree_fingerprint": _worktree_fingerprint(self.worktree),
                }
            return {
                "status": "PASS" if result.returncode == 0 else "FAIL",
                "exit_code": result.returncode,
                "output": (result.stdout + result.stderr)[-4000:],
                "sha": context["current_sha"],
                "worktree": context["worktree"],
                "worktree_fingerprint": _worktree_fingerprint(self.worktree),
            }
        except (OSError, subprocess.SubprocessError) as exc:
            return {
                "status": "UNAVAILABLE",
                "error": str(exc),
                "sha": context["current_sha"],
                "worktree": context["worktree"],
            }


class MutationTestingRegistry:
    """Resolve a supported mutation runner using toolbox-owned argv only."""

    COMMANDS = {
        "node-npm": ("npx", "--no-install", "stryker", "run"),
        "node-pnpm": ("pnpm", "exec", "stryker", "run"),
        "node-yarn": ("yarn", "stryker", "run"),
        "dotnet": ("dotnet", "stryker"),
        "scala-sbt": ("sbt", "stryker"),
    }

    def __init__(
        self,
        worktree: Path | str,
        *,
        ecosystem: Optional[str] = None,
        base_sha: Optional[str] = None,
        command_runner: Optional[Callable[..., Any]] = None,
        executable_lookup: Callable[[str], Optional[str]] = shutil.which,
    ):
        self.worktree = Path(worktree).resolve()
        self.ecosystem = ecosystem
        self.base_sha = base_sha
        self.command_runner = command_runner or subprocess.run
        self.executable_lookup = executable_lookup

    def _detect_ecosystem(self) -> Optional[str]:
        if self.ecosystem:
            return self.ecosystem
        for name in ("dotnet", "node-pnpm", "node-yarn", "node-npm", "scala-sbt", "python"):
            definitions = ToolboxVerificationRegistry.COMMANDS.get(name, {})
            if any(any(self.worktree.glob(pattern)) for pattern in definitions.get("detect", ())):
                return name
        return None

    def _changed_files(self, current_sha: str) -> list[str]:
        names: set[str] = set()
        try:
            commands = []
            if self.base_sha and self.base_sha != current_sha:
                commands.append(["git", "-C", str(self.worktree), "diff", "--name-only", self.base_sha, current_sha])
            commands.extend([
                ["git", "-C", str(self.worktree), "diff", "--name-only"],
                ["git", "-C", str(self.worktree), "diff", "--cached", "--name-only"],
                ["git", "-C", str(self.worktree), "ls-files", "--others", "--exclude-standard"],
            ])
            for command in commands:
                result = subprocess.run(
                    command, capture_output=True, text=True, shell=False, check=False, timeout=30,
                )
                if result.returncode == 0:
                    names.update(line.strip() for line in result.stdout.splitlines() if line.strip())
        except (OSError, subprocess.SubprocessError):
            pass
        return sorted(names)

    @staticmethod
    def _is_test_path(path: str) -> bool:
        lowered = path.lower().replace("\\", "/")
        return any(part in {"test", "tests", "spec", "specs", "e2e", "fixture", "fixtures"}
                   for part in lowered.split("/"))

    def _has_mutable_production_code(self, current_sha: str, ecosystem: str) -> bool:
        extensions = {
            "node-npm": {".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs"},
            "dotnet": {".cs"},
            "scala-sbt": {".scala"},
        }.get(ecosystem, set())
        changed = self._changed_files(current_sha)
        if changed:
            return any(Path(path).suffix.lower() in extensions and not self._is_test_path(path) for path in changed)
        # A non-git fixture cannot provide a diff. Be conservative for supported
        # projects so the verifier is exercised instead of silently skipped.
        return any(path.suffix.lower() in extensions and not self._is_test_path(str(path))
                   for path in self.worktree.rglob("*"))

    def _runner_available(self, ecosystem: str) -> bool:
        if ecosystem in {"node-npm", "node-pnpm", "node-yarn"}:
            package = self.worktree / "package.json"
            executable = {"node-npm": "npx", "node-pnpm": "pnpm", "node-yarn": "yarn"}[ecosystem]
            if not package.is_file() or self.executable_lookup(executable) is None:
                return False
            try:
                manifest = json.loads(package.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                return False
            dependencies = {
                *dict(manifest.get("dependencies", {})),
                *dict(manifest.get("devDependencies", {})),
            }
            return any(name.startswith("@stryker-mutator/") for name in dependencies)
        return self.executable_lookup(self.COMMANDS[ecosystem][0]) is not None

    @staticmethod
    def _score_from_report(report: Any) -> Optional[float]:
        if isinstance(report, Mapping):
            for key, value in report.items():
                if key.lower() == "mutationscore" and isinstance(value, (int, float)):
                    return float(value)
                score = MutationTestingRegistry._score_from_report(value)
                if score is not None:
                    return score
        elif isinstance(report, list):
            for value in report:
                score = MutationTestingRegistry._score_from_report(value)
                if score is not None:
                    return score
        return None

    @staticmethod
    def _report_analysis(report: Any) -> dict[str, Any]:
        """Extract the stable Stryker report contract without trusting prose output.

        Stryker versions and reporters have emitted both percentage scores and
        fractional ``score`` values.  Some reports omit the score and only
        publish metric counts, so calculate it from the same killed/non-killed
        mutant categories.  The recursive walk also handles the JS report's
        ``files`` map and the .NET report's nested metric object.
        """
        counts: dict[str, int] = {}
        score: Optional[float] = None
        threshold: Optional[float] = None
        survivors: list[dict[str, Any]] = []
        mutant_counts: dict[str, int] = {}
        aggregate_counts_found = False
        provenance: dict[str, str] = {}
        aliases = {
            "killed": "killed", "survived": "survived", "timeout": "timeout",
            "nocoverage": "no_coverage", "runtimeerrors": "runtime_errors",
            "compileerrors": "compile_errors", "ignored": "ignored", "pending": "pending",
            "total": "total",
        }
        status_aliases = {
            "killed": "killed", "survived": "survived", "nocoverage": "no_coverage",
            "timeout": "timeout", "runtimeerror": "runtime_errors",
            "compileerror": "compile_errors", "ignored": "ignored", "pending": "pending",
        }
        survivor_statuses = {"survived"}

        def finite_number(value: Any) -> Optional[float]:
            if not isinstance(value, (int, float)):
                return None
            try:
                candidate = float(value)
            except (OverflowError, ValueError):
                return None
            return candidate if math.isfinite(candidate) else None

        def walk(node: Any, file_hint: Optional[str] = None) -> None:
            nonlocal score, threshold, aggregate_counts_found
            if isinstance(node, list):
                for item in node:
                    walk(item, file_hint)
                return
            if not isinstance(node, Mapping):
                return
            local_file = file_hint
            for raw_key, value in node.items():
                key = str(raw_key)
                normalized = re.sub(r"[^a-z0-9]", "", key.lower())
                if normalized in {"sha", "headsha", "commitsha", "commit"} and isinstance(value, str):
                    provenance["sha"] = value
                if normalized == "worktree" and isinstance(value, str):
                    provenance["worktree"] = value
                if normalized in {"worktreefingerprint", "fingerprint"} and isinstance(value, str):
                    provenance["worktree_fingerprint"] = value
                if normalized in {"mutationscore", "score"} and isinstance(value, (int, float)):
                    candidate = finite_number(value)
                    if candidate is not None and (normalized == "mutationscore" or score is None):
                        score = candidate * 100 if 0 <= candidate <= 1 else candidate
                if normalized in aliases and isinstance(value, (int, float)):
                    numeric_value = finite_number(value)
                    if numeric_value is not None and numeric_value >= 0:
                        counts[aliases[normalized]] = int(numeric_value)
                        aggregate_counts_found = True
                if normalized == "thresholds" and isinstance(value, Mapping):
                    high = value.get("high")
                    high_value = finite_number(high)
                    if high_value is not None:
                        threshold = high_value
                if normalized in {"file", "filepath", "filename", "sourcefile"} and isinstance(value, str):
                    local_file = value
                if normalized == "mutants" and isinstance(value, list):
                    for mutant in value:
                        if not isinstance(mutant, Mapping):
                            continue
                        status = re.sub(r"[^a-z0-9]", "", str(mutant.get("status", "")).lower())
                        category = status_aliases.get(status)
                        if category:
                            mutant_counts[category] = mutant_counts.get(category, 0) + 1
                        if status in survivor_statuses:
                            survivors.append({
                                "file": local_file,
                                "location": mutant.get("location"),
                                "mutator": mutant.get("mutatorName") or mutant.get("mutator_name"),
                            })
                if normalized == "files" and isinstance(value, Mapping):
                    for file_name, file_result in value.items():
                        walk(file_result, str(file_name))
                    continue
                walk(value, local_file)

        walk(report)
        count_keys = (
            "killed", "survived", "timeout", "no_coverage", "runtime_errors",
            "compile_errors", "ignored", "pending",
        )
        if mutant_counts and not aggregate_counts_found:
            counts = mutant_counts
        for count_key in count_keys:
            counts.setdefault(count_key, 0)
        if "total" not in counts:
            counts["total"] = sum(counts[key] for key in count_keys)
        if score is None:
            detected = counts["killed"] + counts["timeout"]
            valid = detected + counts["survived"] + counts["no_coverage"]
            if valid:
                score = detected / valid * 100
        if threshold is None:
            threshold = 80.0
        return {
            "score": score,
            "threshold": threshold,
            "counts": counts,
            "survivors": survivors,
            "provenance": provenance,
        }

    @staticmethod
    def _report_signature(path: Path) -> tuple[int, int, str]:
        stat = path.stat()
        return (stat.st_mtime_ns, stat.st_size, hashlib.sha256(path.read_bytes()).hexdigest())

    def _bind_report_provenance(
        self, claimed: Mapping[str, str], current_sha: str
    ) -> Optional[dict[str, str]]:
        """Bind a fresh standard Stryker report to this invocation.

        Standard Stryker JSON does not include repository identity. Freshness
        is established by the before/after report signature snapshot; any
        identity the report does claim is additionally checked here.
        """
        expected = {
            "sha": current_sha,
            "worktree": str(self.worktree),
            "worktree_fingerprint": _worktree_fingerprint(self.worktree),
            "source": "fresh report from registered mutation invocation",
        }
        if (
            (claimed.get("sha") and claimed["sha"] != expected["sha"])
            or (claimed.get("worktree") and str(Path(claimed["worktree"]).resolve()) != expected["worktree"])
            or (
                claimed.get("worktree_fingerprint")
                and claimed["worktree_fingerprint"] != expected["worktree_fingerprint"]
            )
        ):
            return None
        return expected

    def _report_signatures(self) -> dict[Path, tuple[int, int, str]]:
        signatures: dict[Path, tuple[int, int, str]] = {}
        for path in self.worktree.rglob("*.json"):
            if "node_modules" in path.parts or not path.is_file():
                continue
            if "mutation" not in path.name.lower() and "stryker" not in path.name.lower():
                continue
            try:
                signatures[path] = self._report_signature(path)
            except OSError:
                continue
        return signatures

    def _reports(
        self,
        started_at: float,
        previous_signatures: Optional[Mapping[Path, tuple[int, int, str]]] = None,
    ) -> list[Path]:
        candidates = []
        for path in self.worktree.rglob("*.json"):
            if "node_modules" in path.parts or not path.is_file():
                continue
            if "mutation" not in path.name.lower() and "stryker" not in path.name.lower():
                continue
            try:
                stat = path.stat()
                if stat.st_mtime < started_at - 1:
                    continue
                if previous_signatures is not None:
                    try:
                        if (
                            path in previous_signatures
                            and self._report_signature(path) == previous_signatures[path]
                        ):
                            continue
                    except OSError:
                        continue
                candidates.append(path)
            except OSError:
                continue
        return sorted(candidates, key=lambda path: path.stat().st_mtime, reverse=True)

    def run(self, context: Mapping[str, Any]) -> Mapping[str, Any]:
        current_sha = str(context["current_sha"])
        ecosystem = self._detect_ecosystem()
        base = {
            "sha": current_sha,
            "worktree": str(self.worktree),
            "runner": ecosystem or "none",
        }
        if ecosystem is None:
            return base | {"status": "NOT_APPLICABLE", "reason": "no supported mutation ecosystem detected"}
        if ecosystem == "python":
            return base | {"status": "NOT_APPLICABLE", "reason": "Stryker does not support Python"}
        changed = self._changed_files(current_sha)
        test_only_allowed = lambda path: (
            self._is_test_path(path)
            or Path(path).name.lower().startswith("stryker-config")
            or Path(path).name == ".gitignore"
            or (Path(path).parts and Path(path).parts[0] == ".build" and "stryker" in Path(path).name.lower())
        )
        production_changed = any(not test_only_allowed(path) for path in changed)
        production_files = [
            path for path in changed if not test_only_allowed(path)
        ]
        if context.get("test_only") and not production_changed:
            # A non-git fixture cannot expose staged/unstaged/untracked state.
            # Only use the conservative tree scan in that case; in a real git
            # worktree _changed_files already includes all three change sets.
            git_probe = subprocess.run(
                ["git", "-C", str(self.worktree), "rev-parse", "--is-inside-work-tree"],
                capture_output=True, text=True, shell=False, check=False, timeout=30,
            )
            if git_probe.returncode != 0:
                ignored_parts = {".git", "node_modules", "target", "bin", "obj", ".venv"}
                for path in self.worktree.rglob("*"):
                    relative_path = path.relative_to(self.worktree)
                    if (
                        path.is_file()
                        and not ignored_parts.intersection(relative_path.parts)
                        and path.suffix.lower() in {".js", ".jsx", ".ts", ".tsx", ".mjs", ".cjs", ".cs", ".scala"}
                    ):
                        relative = str(relative_path)
                        if not self._is_test_path(relative):
                            production_files.append(relative)
                production_changed = bool(production_files)
        if context.get("test_only") and production_changed:
            return base | {
                "status": "FAIL",
                "reason": "test-only verification found production-code changes",
                "production_files": sorted(set(production_files)),
            }
        if not self._has_mutable_production_code(current_sha, ecosystem) and not context.get("test_only"):
            return base | {"status": "NOT_APPLICABLE", "reason": "no mutable production code changed"}
        if not self._runner_available(ecosystem):
            return base | {
                "status": "UNAVAILABLE",
                "reason": f"registered {ecosystem} Stryker runner is not installed",
                "bootstrap": "install the registered Stryker runner",
            }
        argv = list(self.COMMANDS[ecosystem])
        started_at = time.time()
        previous_report_signatures = self._report_signatures()
        try:
            result = self.command_runner(
                argv, cwd=str(self.worktree), capture_output=True, text=True,
                shell=False, check=False, timeout=3600,
            )
            if isinstance(result, Mapping):
                output = (str(result.get("stdout", "")) + str(result.get("stderr", "")))[-4000:]
                record = base | {
                    "status": "PASS" if result.get("returncode", 1) == 0 else "FAIL",
                    "exit_code": result.get("returncode"),
                    "output": output,
                }
                reports = self._reports(started_at, previous_report_signatures)
                if result.get("returncode", 1) == 0 and not reports:
                    record["status"] = "FAIL"
                    record["reason"] = "Stryker completed without a structured JSON report"
                elif reports:
                    report = reports[0]
                    try:
                        analysis = self._report_analysis(json.loads(report.read_text(encoding="utf-8")))
                    except (OSError, json.JSONDecodeError):
                        analysis = {"score": None, "threshold": 80.0, "counts": {}, "survivors": [], "provenance": {}}
                    record["report_path"] = str(report)
                    bound_provenance = self._bind_report_provenance(analysis["provenance"], current_sha)
                    if bound_provenance is None:
                        record["status"] = "FAIL"
                        record["reason"] = "stale mutation report does not match the current SHA/worktree"
                        return record
                    record["provenance"] = bound_provenance
                    score = analysis["score"]
                    if score is None:
                        record["status"] = "FAIL"
                        record["reason"] = "Stryker report has no numeric score or usable mutant counts"
                    else:
                        record["mutation_score"] = score
                        record["threshold"] = analysis["threshold"]
                        record["mutant_counts"] = analysis["counts"]
                        record["surviving_mutants"] = analysis["survivors"]
                        if score < analysis["threshold"]:
                            record["status"] = "FAIL"
                            record["reason"] = (
                                f"Stryker mutation score {score:.2f} is below threshold "
                                f"{analysis['threshold']:.2f}"
                            )
                return record
            output = (result.stdout + result.stderr)[-4000:]
            record = base | {
                "status": "PASS" if result.returncode == 0 else "FAIL",
                "exit_code": result.returncode,
                "output": output,
            }
            reports = self._reports(started_at, previous_report_signatures)
            if result.returncode == 0 and not reports:
                record["status"] = "FAIL"
                record["reason"] = "Stryker completed without a structured JSON report"
            elif reports:
                report = reports[0]
                try:
                    analysis = self._report_analysis(json.loads(report.read_text(encoding="utf-8")))
                except (OSError, json.JSONDecodeError):
                    analysis = {"score": None, "threshold": 80.0, "counts": {}, "survivors": [], "provenance": {}}
                record["report_path"] = str(report)
                bound_provenance = self._bind_report_provenance(analysis["provenance"], current_sha)
                if bound_provenance is None:
                    record["status"] = "FAIL"
                    record["reason"] = "stale mutation report does not match the current SHA/worktree"
                    return record
                record["provenance"] = bound_provenance
                score = analysis["score"]
                if score is None:
                    record["status"] = "FAIL"
                    record["reason"] = "Stryker report has no numeric score or usable mutant counts"
                else:
                    record["mutation_score"] = score
                    record["threshold"] = analysis["threshold"]
                    record["mutant_counts"] = analysis["counts"]
                    record["surviving_mutants"] = analysis["survivors"]
                    if score < analysis["threshold"]:
                        record["status"] = "FAIL"
                        record["reason"] = (
                            f"Stryker mutation score {score:.2f} is below threshold "
                            f"{analysis['threshold']:.2f}"
                        )
            return record
        except FileNotFoundError as exc:
            return base | {"status": "UNAVAILABLE", "error": str(exc), "bootstrap": "install the registered Stryker runner"}
        except (OSError, subprocess.SubprocessError) as exc:
            return base | {"status": "UNAVAILABLE", "error": str(exc)}


class VerificationRunner:
    def __init__(self, registry: Mapping[str, Callable[[Mapping[str, Any]], Mapping[str, Any]]]):
        self.registry = dict(registry)

    def run(
        self, verifier_ids: list[str], current_sha: str, worktree: Path | str,
        *, test_only: bool = False, mutation_policy: str = "auto",
    ) -> list[dict[str, Any]]:
        evidence = []
        canonical_worktree = str(Path(worktree).resolve())
        keys = list(verifier_ids)
        if "mutation" in self.registry and "mutation" not in keys:
            keys.append("mutation")
        for key in keys:
            if key not in self.registry:
                raise VerificationError(f"verifier key is not registered: {key}")
            if key == "mutation" and mutation_policy in {"no", "manual"}:
                evidence.append({
                    "key": key, "status": "NOT_APPLICABLE", "sha": current_sha,
                    "worktree": canonical_worktree, "reason": f"mutation policy is {mutation_policy}",
                })
                continue
            if key == "mutation" and mutation_policy == "test_only_prs" and not test_only:
                evidence.append({
                    "key": key, "status": "NOT_APPLICABLE", "sha": current_sha,
                    "worktree": canonical_worktree, "reason": "change is not test-only",
                })
                continue
            started = time.monotonic()
            fingerprint_before = self._worktree_fingerprint(canonical_worktree)
            try:
                raw = dict(self.registry[key]({
                    "verifier_id": key,
                    "current_sha": current_sha,
                    "worktree": canonical_worktree,
                    "test_only": test_only,
                }))
            except Exception as exc:  # registry adapters must become evidence, not crashes
                raw = {"status": "FAIL", "error": str(exc)}
            status = str(raw.get("status", "UNAVAILABLE")).upper()
            fingerprint_after = self._worktree_fingerprint(canonical_worktree)
            observed_fingerprint = raw.get("worktree_fingerprint", fingerprint_after)
            if status == "PASS" and (
                raw.get("sha") != current_sha
                or str(Path(raw.get("worktree", "")).resolve()) != canonical_worktree
                or fingerprint_before != fingerprint_after
                or observed_fingerprint != fingerprint_after
            ):
                status = "STALE"
            record = {
                "key": key,
                "status": status if status in {"PASS", "FAIL", "STALE", "UNAVAILABLE", "NOT_APPLICABLE"} else "UNAVAILABLE",
                "sha": raw.get("sha"),
                "worktree": raw.get("worktree"),
                "exit_code": raw.get("exit_code"),
                "duration_seconds": round(time.monotonic() - started, 6),
                "output": str(raw.get("output", ""))[-4000:],
                "worktree_fingerprint": fingerprint_after,
            }
            for field in (
                "error", "reason", "runner", "report_path", "mutation_score", "threshold",
                "mutant_counts", "surviving_mutants", "production_files",
            ):
                if raw.get(field) is not None:
                    record[field] = raw[field]
            evidence.append(record)
        return evidence

    @staticmethod
    def completable(evidence: list[Mapping[str, Any]]) -> bool:
        return bool(evidence) and all(
            item.get("status") in {"PASS", "NOT_APPLICABLE"} for item in evidence
        )

    @staticmethod
    def _worktree_fingerprint(worktree: Path | str) -> str:
        return _worktree_fingerprint(worktree)


class Advisor:
    def __init__(self, idle_after: float = 300, stale_after: float = 900):
        self.idle_after = idle_after
        self.stale_after = stale_after

    @staticmethod
    def recommend(incident: Mapping[str, Any]) -> dict[str, str]:
        recommendations = {
            "stale_evidence": (
                "Re-run the required verifiers at the current HEAD",
                "refresh evidence before the next worker iteration",
            ),
            "repeated_no_progress": (
                "Change the approach after repeated identical progress signatures",
                "inspect the failure signature and select a new bounded action",
            ),
            "failed_tool_invocation": (
                "Repair or re-check the failed tool invocation",
                "retry only after the registered tool is available",
            ),
            "lost_external_state": (
                "Reconcile the journaled external action before retrying",
                "recover the pending action and verify the external result",
            ),
            "provider_or_hook_friction": (
                "Inspect provider or hook friction and preserve the human gate if needed",
                "check capability and permission evidence before retrying",
            ),
        }
        return dict(zip(("recommendation", "action"), recommendations.get(
            str(incident.get("incident_type")),
            ("Review the operational incident", "inspect the incident before continuing"),
        )))

    def assess(
        self,
        state: GoalState,
        provider: ProviderResult,
        evidence: list[Mapping[str, Any]],
        progress: Mapping[str, Any],
        age: float = 0,
    ) -> Assessment:
        if provider.human_action_required:
            return Assessment(
                AdvisorClass.HUMAN_ACTION_REQUIRED,
                "provider requires a human action",
                {"pending_human_action": provider.human_action_required},
                "wait for human action",
            )
        if provider.error or any(
            item.get("status") in {"FAIL", "STALE", "UNAVAILABLE"} for item in evidence
        ):
            return Assessment(
                AdvisorClass.FAILED,
                "provider or required verification failed",
                {"provider_error": provider.error, "evidence": list(evidence)},
                "fix the failing evidence",
            )
        if progress.get("status") == "STOP":
            return Assessment(
                AdvisorClass.STALE,
                "no-progress detector reached its threshold",
                dict(progress),
                "inspect the repeated failure",
            )
        if age >= self.stale_after:
            return Assessment(AdvisorClass.STALE, "last action is stale", {"age": age}, "resume after inspection")
        if age >= self.idle_after:
            return Assessment(AdvisorClass.IDLE, "worker has been idle", {"age": age}, "resume the worker")
        if provider.completed and VerificationRunner.completable(list(evidence)):
            return Assessment(
                AdvisorClass.COMPLETE_CANDIDATE,
                "provider finished and all required verifiers passed",
                {"evidence": list(evidence)},
                "checkpoint and review completion",
            )
        return Assessment(
            AdvisorClass.HEALTHY_PROGRESS,
            "worker produced a bounded iteration",
            {"changed": provider.changed, "evidence": list(evidence)},
            "continue with the next iteration",
        )


class CapabilityDetector:
    def __init__(self, executable_lookup: Callable[[str], Optional[str]] = shutil.which):
        self.executable_lookup = executable_lookup

    def detect(self, provider: str, env: Optional[Mapping[str, str]] = None) -> dict[str, bool]:
        env = dict(os.environ if env is None else env)
        provider = provider.lower()
        local_name = "claude" if provider == "claude" else "codex"
        local = self.executable_lookup(local_name) is not None
        if provider == "claude":
            remote = env.get("CLAUDE_REMOTE_CONTROL", "").lower() in {"1", "true", "yes"}
        else:
            remote = env.get("CODEX_DESKTOP_REMOTE", "").lower() in {"1", "true", "yes"}
        mobile = (
            provider == "codex"
            and remote
            and env.get("CODEX_MOBILE_SUPPORTED", "").lower() in {"1", "true", "yes"}
        )
        return {
            "local_cli": local,
            "remote_status": remote,
            "remote_resume": remote,
            "remote_pause": remote,
            "mobile": mobile,
        }


class GoalLoop:
    """Executes exactly one bounded worker iteration."""

    def __init__(
        self,
        store: GoalStore,
        provider: Any,
        verifier_runner: VerificationRunner,
        *,
        provider_registry: Optional[ProviderAdapterRegistry] = None,
        progress_detector: Optional[Callable[[GoalState, list[dict[str, Any]]], Mapping[str, Any]]] = None,
        advisor: Optional[Advisor] = None,
        jira: Any = None,
        beads: Any = None,
        owner: Optional[str] = None,
        lease_ttl: float = 300,
    ):
        self.store = store
        self.provider = provider
        self.provider_registry = provider_registry
        self.verifier_runner = verifier_runner
        self.progress_detector = progress_detector or self._default_progress_detector
        self.advisor = advisor or Advisor()
        self.jira = jira
        self.beads = beads
        self.owner = owner or f"{os.getpid()}-{uuid.uuid4().hex[:8]}"
        self.lease_ttl = lease_ttl

    @staticmethod
    def _fallback_allowed(result: ProviderResult) -> bool:
        return (
            result.outcome_known
            and result.failure_kind in {"provider_unavailable", "usage_limited"}
        )

    def _provider_candidates(self, preferred: str) -> list[tuple[str, Any]]:
        if self.provider_registry is not None:
            return self.provider_registry.candidates(preferred)
        # Directly constructed GoalLoops remain compatible with in-process
        # test/host adapters. They have no safe alternate unless the caller
        # supplies a registry explicitly.
        return [(preferred.lower(), self.provider)]

    def _switch_provider(
        self,
        state: GoalState,
        from_provider: str,
        to_provider: str,
        reason: str,
        *,
        lease: Optional[Mapping[str, Any]] = None,
    ) -> None:
        sessions = state.extra_fields.setdefault("provider_sessions", {})
        if not isinstance(sessions, dict):
            sessions = {}
            state.extra_fields["provider_sessions"] = sessions
        session_owner = state.extra_fields.get("provider_session_provider", from_provider)
        if state.provider_session_id and session_owner == from_provider:
            sessions[from_provider] = state.provider_session_id
        state.provider = to_provider
        state.planner_identity = RoleRouter().planner_assignment(to_provider).identity
        state.worker_identity = RoleRouter().provider_assignment(to_provider).identity
        state.monitor_identity = (
            "haiku" if to_provider == "claude" else "lightweight"
        )
        state.provider_session_id = sessions.get(to_provider)
        state.extra_fields["provider_session_provider"] = to_provider
        history = state.extra_fields.setdefault("provider_history", [])
        if not isinstance(history, list):
            history = []
            state.extra_fields["provider_history"] = history
        history.append(
            {
                "from": from_provider,
                "to": to_provider,
                "reason": reason,
                "at": _now(),
            }
        )
        del history[:-20]
        self.store.append_event(
            state.run_id,
            {
                "type": "provider.fallback",
                "from": from_provider,
                "to": to_provider,
                "reason": reason,
            },
        )
        self.store.update(state, lease=lease)

    def _start_iteration_with_fallback(
        self,
        state: GoalState,
        lease: Mapping[str, Any],
        heartbeat: "LeaseHeartbeat",
    ) -> tuple[ProviderResult, str, str, bool, bool]:
        """Run one logical iteration, trying the other provider only safely."""
        candidates = self._provider_candidates(state.provider)
        last_result = ProviderResult(
            error="no provider adapter is available",
            human_action_required="configure a Claude or Codex goal-loop wrapper",
            failure_kind="provider_unavailable",
            outcome_known=True,
        )
        for attempt, (provider_name, adapter) in enumerate(candidates, start=1):
            assignment = RoleRouter().provider_assignment(provider_name)
            payload = {
                "provider": provider_name,
                "role_assignment": dataclasses.asdict(assignment),
                "iteration": state.iteration_count,
                "head_sha": state.head_sha,
                "goal": state.goal,
                "lease_generation": lease.get("generation"),
                "attempt": attempt,
            }
            provider_action = self.store.record_intent(
                state.run_id, "provider.iteration", payload
            )
            self.store.assert_lease_current(state.run_id, lease)
            provider_started = time.monotonic()
            try:
                result = self._start_iteration(adapter, state, assignment)
            except Exception as exc:
                result = ProviderResult(
                    error=str(exc), failure_kind="unknown", outcome_known=False, cost_usd=None
                )
            result.wall_clock_seconds = max(
                float(result.wall_clock_seconds), time.monotonic() - provider_started
            )
            try:
                if heartbeat.lost:
                    raise LeaseFenceError("lease heartbeat lost while provider action was running")
                self.store.assert_lease_current(state.run_id, lease)
            except LeaseFenceError:
                try:
                    self.store.record_action_result(
                        state.run_id,
                        provider_action,
                        "UNKNOWN",
                        {
                            "error": "lease fence rejected worker after provider action",
                            "provider": provider_name,
                            "lease_generation": lease.get("generation"),
                        },
                        lease=lease,
                    )
                except LeaseFenceError:
                    pass
                return result, provider_action, provider_name, True, True

            if self._fallback_allowed(result):
                self.store.record_action_result(
                    state.run_id,
                    provider_action,
                    "FAILED",
                    {
                        "provider": provider_name,
                        "failure_kind": result.failure_kind,
                        "error": result.error,
                        "human_action_required": result.human_action_required,
                        "outcome_known": True,
                    },
                    lease=lease,
                )
                last_result = result
                if attempt < len(candidates):
                    next_provider = candidates[attempt][0]
                    self._switch_provider(
                        state,
                        provider_name,
                        next_provider,
                        result.failure_kind or "provider unavailable",
                        lease=lease,
                    )
                    continue
                return result, provider_action, provider_name, False, True
            return result, provider_action, provider_name, False, False
        return last_result, "", state.provider, False, True

    def _start_advisor_with_fallback(
        self,
        state: GoalState,
        incident: Mapping[str, Any],
        lease: Mapping[str, Any],
    ) -> Optional[ProviderResult]:
        for attempt, (provider_name, adapter) in enumerate(
            self._provider_candidates(state.provider), start=1
        ):
            start_advisor = getattr(adapter, "start_advisor", None)
            if not callable(start_advisor):
                result = ProviderResult(
                    error=f"{provider_name} adapter has no advisor capability",
                    failure_kind="provider_unavailable",
                    outcome_known=True,
                )
            else:
                try:
                    result = start_advisor(
                        state, incident, RoleRouter().planner_assignment(provider_name)
                    )
                except Exception as exc:
                    result = ProviderResult(
                        error=str(exc), failure_kind="unknown", outcome_known=False, cost_usd=None
                    )
            self.store.assert_lease_current(state.run_id, lease)
            if self._fallback_allowed(result) and attempt < 2:
                self._switch_provider(
                    state,
                    provider_name,
                    "codex" if provider_name == "claude" else "claude",
                    result.failure_kind or "provider unavailable",
                    lease=lease,
                )
                continue
            return result
        return None

    @staticmethod
    def _observed_head_sha(state: GoalState) -> Optional[str]:
        """Read the worktree HEAD; provider-reported SHAs are not authoritative."""
        try:
            result = subprocess.run(
                ["git", "-C", state.worktree, "rev-parse", "HEAD"],
                capture_output=True, text=True, shell=False, check=False, timeout=30,
            )
            observed = result.stdout.strip()
            if result.returncode == 0 and observed:
                return observed
        except (OSError, subprocess.SubprocessError):
            pass
        return None

    @staticmethod
    def _start_iteration(provider: Any, state: GoalState, assignment: RoleAssignment) -> ProviderResult:
        """Call the current contract while tolerating legacy host adapters."""

        method = provider.start_iteration
        try:
            parameter_count = len(inspect.signature(method).parameters)
        except (TypeError, ValueError):
            parameter_count = 2
        if parameter_count >= 2:
            return method(state, assignment)
        return method(state)

    def _default_progress_detector(
        self, state: GoalState, evidence: list[dict[str, Any]]
    ) -> Mapping[str, Any]:
        script = Path(__file__).with_name("loop-progress-signature.sh")
        if not script.exists():
            return {"status": "ERROR", "reason": "existing progress detector unavailable"}
        bash_bin = next(
            (
                candidate
                for candidate in ("/bin/bash", "/usr/bin/bash", "/opt/homebrew/bin/bash")
                if Path(candidate).is_file() and os.access(candidate, os.X_OK)
            ),
            None,
        )
        if bash_bin is None:
            return {"status": "ERROR", "reason": "trusted bash executable unavailable"}
        progress_state = self.store._path(state.run_id, "progress.json")
        failures = ",".join(item["key"] for item in evidence if item["status"] != "PASS")
        threshold = str(state.limits.get("no_progress_after", 2))
        try:
            proc = subprocess.run(
                [
                    bash_bin, str(script), "--state", str(progress_state),
                    "--failing-gates", failures, "--threshold", threshold,
                ],
                capture_output=True,
                text=True,
                check=False,
                timeout=30,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            return {"status": "ERROR", "reason": str(exc)}
        if proc.returncode == 3:
            return {"status": "STOP", "output": proc.stdout[-1000:]}
        if proc.returncode == 0:
            return {"status": "KEEP_GOING", "output": proc.stdout[-1000:]}
        return {"status": "ERROR", "output": (proc.stderr or proc.stdout)[-1000:]}

    def _budget_exceeded(self, state: GoalState) -> Optional[str]:
        iteration_limit = state.limits.get("max_iterations")
        wall_limit = state.limits.get("max_wall_clock_seconds")
        cost_limit = state.limits.get("max_cost_usd")
        last = state.last_action or {}
        if iteration_limit is not None and state.iteration_count >= int(iteration_limit):
            return "iteration ceiling reached"
        if wall_limit is not None and state.wall_clock_seconds >= float(wall_limit):
            return "cumulative wall-clock budget exhausted"
        if cost_limit is not None and state.cost_usd is not None and state.cost_usd >= float(cost_limit):
            return "cumulative cost budget exhausted"
        # A conservative reservation prevents starting another action when the
        # previous action already consumed more than the remaining budget.
        if wall_limit is not None and last.get("wall_clock_seconds", 0) > max(
            0, float(wall_limit) - state.wall_clock_seconds
        ):
            return "next action would exceed cumulative wall-clock budget"
        if cost_limit is not None and last.get("cost_usd") is not None and (
            float(last["cost_usd"]) > max(0, float(cost_limit) - (state.cost_usd or 0))
        ):
            return "next action would exceed cumulative cost budget"
        return None

    @staticmethod
    def _cost_issue(value: Optional[float]) -> Optional[str]:
        if value is None:
            return "provider cost evidence is missing"
        if not math.isfinite(float(value)) or float(value) < 0:
            return "provider cost evidence is non-finite or negative"
        return None

    def _set_status(self, state: GoalState, status: RunStatus, reason: str) -> None:
        if state.status == status:
            state.stop_reason = reason
            self.store.update(state)
            return
        allowed = {
            RunStatus.RUNNING: {RunStatus.BLOCKED, RunStatus.HUMAN_ACTION_REQUIRED,
                                RunStatus.FAILED, RunStatus.COMPLETE_CANDIDATE},
            RunStatus.BLOCKED: {RunStatus.HUMAN_ACTION_REQUIRED, RunStatus.RESUMABLE},
            RunStatus.FAILED: {RunStatus.HUMAN_ACTION_REQUIRED, RunStatus.RESUMABLE},
        }
        if status not in allowed.get(state.status, set()):
            raise StateError(f"cannot set {state.status.value} -> {status.value}")
        state.status = status
        state.stop_reason = reason
        self.store.update(state)

    def _incident(
        self, state: GoalState, incident_type: str, evidence: Mapping[str, Any]
    ) -> str:
        incident_id = self.store.record_operational_incident(
            state.run_id, incident_type, evidence
        )
        # The caller's state may predate another incident written by the store.
        # Hydrate both compatibility fields before the caller checkpoints state;
        # updating only the singular field would overwrite queued incidents.
        refreshed = self.store.load(state.run_id)
        state.pending_advisor_review = refreshed.pending_advisor_review
        state.pending_advisor_reviews = list(refreshed.pending_advisor_reviews)
        return incident_id

    def advisor_cycle(self, run_id: str) -> dict[str, Any]:
        """Run the lightweight advisor response for a pending incident once."""

        state = self.store.load(run_id)
        lease = self.store.acquire_lease(run_id, self.owner, self.lease_ttl)
        heartbeat = LeaseHeartbeat(self.store, run_id, lease, self.lease_ttl)
        heartbeat.start()
        try:
            incident = (
                state.pending_advisor_reviews[0]
                if state.pending_advisor_reviews
                else state.pending_advisor_review
            )
            if not incident:
                return state.last_advisor_assessment or {}
            advisor_result = self._start_advisor_with_fallback(state, incident, lease)
            if advisor_result is not None:
                advisor_started = time.monotonic()
                state.wall_clock_seconds += max(
                    float(advisor_result.wall_clock_seconds), time.monotonic() - advisor_started
                )
                cost_issue = self._cost_issue(advisor_result.cost_usd)
                if advisor_result.human_action_required:
                    reason = advisor_result.human_action_required
                    if cost_issue:
                        reason += f"; {cost_issue}"
                    state.pending_human_action = reason
                    self._set_status(state, RunStatus.HUMAN_ACTION_REQUIRED, reason)
                    return self.store.load(run_id).to_dict()
                if state.limits.get("max_cost_usd") is not None and cost_issue:
                    state.pending_human_action = f"advisor {cost_issue}; reconcile usage before continuing"
                    self._set_status(state, RunStatus.HUMAN_ACTION_REQUIRED, state.pending_human_action)
                    return self.store.load(run_id).to_dict()
                if (
                    state.limits.get("max_wall_clock_seconds") is not None
                    and state.wall_clock_seconds >= float(state.limits["max_wall_clock_seconds"])
                ):
                    self._set_status(state, RunStatus.BLOCKED, "cumulative wall-clock budget exhausted during advisor cycle")
                    return self.store.load(run_id).to_dict()
                if advisor_result.cost_usd is not None:
                    state.cost_usd = (state.cost_usd or 0) + float(advisor_result.cost_usd)
                if advisor_result.error:
                    self.store.append_event(
                        run_id,
                        {
                            "type": "advisor.provider_error",
                            "provider": state.provider,
                            "error": advisor_result.error,
                        },
                    )
            response = self.advisor.recommend(incident)
            action_id = self.store.record_advisor_action(
                run_id,
                incident,
                response["recommendation"],
                response["action"],
            )
            state = self.store.load(run_id)
            assessment = dict(state.last_advisor_assessment or {})
            assessment.update(
                {
                    "classification": assessment.get(
                        "classification", AdvisorClass.FAILED.value
                    ),
                    "incident_id": incident["incident_id"],
                    "recommendation": response["recommendation"],
                    "action": response["action"],
                    "action_id": action_id,
                }
            )
            state.last_advisor_assessment = assessment
            state.next_action = response["action"]
            self.store.append_event(
                run_id,
                {
                    "type": "advisor.assessed",
                    "classification": assessment["classification"],
                    "reason": "self-improvement review completed",
                    "incident_id": incident["incident_id"],
                },
            )
            self.store.update(state)
            refreshed = self.store.load(run_id)
            if not refreshed.pending_advisor_reviews and refreshed.status in {
                RunStatus.BLOCKED, RunStatus.FAILED
            }:
                refreshed = self.store.transition(run_id, RunStatus.RESUMABLE)
            return response | {"action_id": action_id, "incident_id": incident["incident_id"]}
        finally:
            heartbeat.stop()
            self.store.release_lease(run_id, lease)

    def run_iteration(self, run_id: str) -> GoalState:
        state = self.store.load(run_id)
        if state.status == RunStatus.RESUMABLE:
            state = self.store.transition(run_id, RunStatus.RUNNING)
        if state.status != RunStatus.RUNNING:
            return state
        if state.pending_advisor_reviews or state.pending_advisor_review:
            self._set_status(state, RunStatus.BLOCKED, "advisor review required before another worker iteration")
            return self.store.load(run_id)
        if self.store.pending_actions(run_id):
            reason = "journaled external action must be reconciled before another worker iteration"
            state.pending_human_action = reason
            self._set_status(state, RunStatus.HUMAN_ACTION_REQUIRED, reason)
            return self.store.load(run_id)
        lease = self.store.acquire_lease(run_id, self.owner, self.lease_ttl)
        heartbeat = LeaseHeartbeat(self.store, run_id, lease, self.lease_ttl)
        heartbeat.start()
        started = time.monotonic()
        try:
            if (reason := self._budget_exceeded(state)):
                self._set_status(state, RunStatus.BLOCKED, reason)
                return self.store.load(run_id)

            observed_before = self._observed_head_sha(state)
            if observed_before is None:
                reason = "unable to verify worktree HEAD; human action required before continuing"
                state.pending_human_action = reason
                self._set_status(state, RunStatus.HUMAN_ACTION_REQUIRED, reason)
                return self.store.load(run_id)
            if observed_before != state.head_sha:
                self.store.append_event(
                    run_id,
                    {
                        "type": "head.reconciled_before_iteration",
                        "stored_sha": state.head_sha,
                        "observed_sha": observed_before,
                    },
                )
                state.head_sha = observed_before
            baseline_sha = state.head_sha
            state.iteration_count += 1
            result, provider_action, provider_name, lease_lost, action_closed = (
                self._start_iteration_with_fallback(state, lease, heartbeat)
            )
            if lease_lost:
                return self.store.load(run_id)

            consumed_wall_clock = max(float(result.wall_clock_seconds), 0.0)
            state.provider_session_id = result.session_id or state.provider_session_id
            if result.session_id:
                state.extra_fields["provider_session_provider"] = provider_name
            state.last_action = {
                "type": "provider.iteration",
                "provider": provider_name,
                "iteration": state.iteration_count,
                "wall_clock_seconds": consumed_wall_clock,
                "cost_usd": result.cost_usd,
            }
            state.wall_clock_seconds += consumed_wall_clock
            if result.cost_usd is not None and self._cost_issue(result.cost_usd) is None:
                state.cost_usd = (state.cost_usd or 0) + float(result.cost_usd)
            if action_closed:
                # The terminal unavailable/limited attempt was already closed
                # as FAILED by the fallback helper. Do not run verifiers or
                # manufacture a successful provider result for it.
                self.store.update(state, lease=lease)
                reason = result.human_action_required or result.error or (
                    f"{provider_name} provider is unavailable"
                )
                state.pending_human_action = reason
                self._set_status(state, RunStatus.HUMAN_ACTION_REQUIRED, reason)
                return self.store.load(run_id)
            observed_after = self._observed_head_sha(state)
            if observed_after is None:
                reason = "unable to verify worktree HEAD after provider action; reconcile before retrying"
                self.store.append_event(run_id, {"type": "head.verification_failed", "reason": reason})
                state.pending_human_action = reason
                self._set_status(state, RunStatus.HUMAN_ACTION_REQUIRED, reason)
                return self.store.load(run_id)
            if result.new_head_sha and result.new_head_sha != observed_after:
                self.store.append_event(
                    run_id,
                    {
                        "type": "provider.head_claim_ignored",
                        "claimed_sha": result.new_head_sha,
                        "observed_sha": observed_after,
                    },
                )
            state.head_sha = observed_after

            # Record the complete bounded provider outcome only after the
            # runtime has observed the resulting HEAD. If the process crashes
            # before the next state checkpoint, recovery can reconcile this
            # successful journal entry instead of losing the session/result or
            # repeating the external iteration.
            result_status = (
                "UNKNOWN" if not result.outcome_known
                else ("FAILED" if result.error or result.human_action_required else "SUCCEEDED")
            )
            self.store.record_action_result(
                run_id,
                provider_action,
                result_status,
                {
                    "provider": provider_name,
                    "session_id": result.session_id,
                    "changed": result.changed,
                    "completed": result.completed,
                    "output": result.output[-4000:],
                    "error": result.error,
                    "human_action_required": result.human_action_required,
                    "failure_kind": result.failure_kind,
                    "outcome_known": result.outcome_known,
                    "wall_clock_seconds": consumed_wall_clock,
                    "cost_usd": result.cost_usd,
                    "observed_head_sha": observed_after,
                }, lease=lease,
            )

            # Persist the completed provider action before verifier resolution.
            # If configuration is invalid, a later recovery cannot replay the
            # external provider action.
            try:
                self.store.update(state, lease=lease)
            except LeaseFenceError:
                # The successor owns the checkpoint; never let stale state
                # escape as an overwrite or an unhandled worker failure.
                return self.store.load(run_id)

            if result.human_action_required:
                reason = result.human_action_required
                if (cost_issue := self._cost_issue(result.cost_usd)):
                    reason += f"; {cost_issue}"
                state.pending_human_action = reason
                self._set_status(state, RunStatus.HUMAN_ACTION_REQUIRED, reason)
                return self.store.load(run_id)
            if result.error:
                if state.pending_advisor_review is None:
                    incident_type = (
                        "provider_or_hook_friction"
                        if any(word in result.error.lower() for word in ("hook", "permission"))
                        else "failed_tool_invocation"
                    )
                    self._incident(state, incident_type, {"action": "provider.iteration", "error": result.error})
                self._set_status(state, RunStatus.FAILED, result.error)
                return self.store.load(run_id)
            if state.limits.get("max_cost_usd") is not None and (cost_issue := self._cost_issue(result.cost_usd)):
                reason = f"{cost_issue}; reconcile usage before continuing"
                self._incident(state, "lost_external_state", {"action": "provider.iteration", "error": reason})
                state.pending_human_action = reason
                self._set_status(state, RunStatus.HUMAN_ACTION_REQUIRED, reason)
                return self.store.load(run_id)

            if (
                state.limits.get("max_wall_clock_seconds") is not None
                and state.wall_clock_seconds >= float(state.limits["max_wall_clock_seconds"])
            ):
                self._set_status(state, RunStatus.BLOCKED, "cumulative wall-clock budget exhausted")
                return self.store.load(run_id)

            try:
                self.store.assert_lease_current(run_id, lease)
                evidence = self.verifier_runner.run(
                    state.verifier_ids,
                    state.head_sha,
                    state.worktree,
                    mutation_policy=str(state.limits.get("mutation_policy", "auto")),
                    test_only=bool(state.limits.get("test_only", False)),
                )
            except VerificationError as exc:
                state.last_verification = [{"status": "UNAVAILABLE", "error": str(exc)}]
                self._incident(
                    state, "failed_tool_invocation",
                    {"action": "verification", "error": str(exc)},
                )
                self.store.update(state)
                self._set_status(state, RunStatus.BLOCKED, f"verification configuration failed: {exc}")
                return self.store.load(run_id)
            self.store.assert_lease_current(run_id, lease)
            state.last_verification = evidence
            stale = [item for item in evidence if item.get("status") == "STALE"]
            failed = [
                item for item in evidence
                if item.get("status") in {"FAIL", "UNAVAILABLE"}
            ]
            if stale:
                self._incident(state, "stale_evidence", {"evidence": stale})
            elif failed:
                self._incident(state, "failed_tool_invocation", {"evidence": failed})
            self.store.update(state)
            if stale or failed:
                reason = "advisor review required before another worker iteration"
                self._set_status(state, RunStatus.BLOCKED, reason)
                return self.store.load(run_id)
            progress = dict(self.progress_detector(state, evidence))
            self.store.append_event(run_id, {"type": "progress.assessed", "result": progress})
            if progress.get("status") == "ERROR":
                reason = f"progress detector unavailable: {progress.get('reason', 'unknown error')}"
                self._incident(state, "failed_tool_invocation", {"action": "progress_detector", "error": reason})
                state.pending_human_action = reason
                self._set_status(state, RunStatus.HUMAN_ACTION_REQUIRED, reason)
                return self.store.load(run_id)
            if progress.get("status") == "STOP":
                self._incident(state, "repeated_no_progress", dict(progress))
            assessment = self.advisor.assess(
                state, result, evidence, progress, age=time.monotonic() - started
            )
            state.last_advisor_assessment = {
                "classification": assessment.classification.value,
                "reason": assessment.reason,
                "evidence": assessment.evidence,
                "next_action": assessment.next_action,
            }
            state.next_action = assessment.next_action
            self.store.append_event(
                run_id,
                {
                    "type": "advisor.assessed",
                    "classification": assessment.classification.value,
                    "reason": assessment.reason,
                },
            )

            if assessment.classification == AdvisorClass.COMPLETE_CANDIDATE:
                self._set_status(state, RunStatus.COMPLETE_CANDIDATE, assessment.reason)
            elif assessment.classification == AdvisorClass.STALE:
                self._set_status(state, RunStatus.BLOCKED, assessment.reason)

            self.store.assert_lease_current(run_id, lease)
            self._jira_progress(run_id, state)
            self.store.assert_lease_current(run_id, lease)
            self._beads_progress(run_id, state)
            return self.store.update(state)
        finally:
            heartbeat.stop()
            self.store.release_lease(run_id, lease)


    def _jira_progress(self, run_id: str, state: GoalState) -> None:
        if self.jira is None or not state.jira.get("key"):
            self.store.append_event(run_id, {"type": "jira.fallback", "reason": "Jira adapter unavailable or no key"})
            return
        payload = {"phase": state.current_phase, "iteration": state.iteration_count}
        action_id = self.store.record_intent(run_id, "jira.progress", payload)
        try:
            result = self.jira.progress(state, action_id)
        except Exception as exc:
            # The external outcome is unknown: retain the intent for reconcile
            # rather than marking it terminal and silently losing progress.
            self.store.record_action_result(run_id, action_id, "UNKNOWN", {"error": str(exc)})
            self.store.append_event(
                run_id,
                {"type": "jira.fallback", "reason": str(exc), "action_id": action_id},
            )
            self._incident(state, "lost_external_state", {"action": "jira.progress", "error": str(exc)})
            return
        self.store.record_action_result(run_id, action_id, "SUCCEEDED", result)
        state.jira.setdefault("action_ids", []).append(action_id)
        state.jira["last_result"] = result

    def _beads_progress(self, run_id: str, state: GoalState) -> None:
        if self.beads is None or not state.beads.get("enabled"):
            self.store.append_event(run_id, {"type": "beads.fallback", "reason": "Beads not initialized"})
            return
        try:
            result = self.beads.progress(state)
            state.beads["last_result"] = result
        except Exception as exc:
            state.beads["last_result"] = {"status": "fallback", "reason": str(exc)}
            self.store.append_event(run_id, {"type": "beads.fallback", "reason": str(exc)})

    def recover(self, run_id: str) -> GoalState:
        state = self.store.load(run_id)
        lease = self.store.acquire_lease(run_id, self.owner, self.lease_ttl)
        try:
            # A provider can finish after its result is journaled but before the
            # state checkpoint is durable. Reconcile the bounded journal result
            # into state before deciding whether another action is needed.
            for intent, result in self.store.completed_actions(run_id):
                if intent.get("action_type") != "provider.iteration":
                    continue
                payload = intent.get("payload") or {}
                if int(payload.get("iteration", 0)) <= state.iteration_count:
                    continue
                action_id = intent["action_id"]
                recorded = result.get("result") or {}
                iteration = int(payload.get("iteration", 0))
                observed_head = recorded.get("observed_head_sha")
                if not isinstance(observed_head, str) or not observed_head:
                    state.pending_human_action = (
                        f"provider action {action_id} has no observed HEAD in its journal result; "
                        "verify the external result before retrying"
                    )
                    state.status = RunStatus.HUMAN_ACTION_REQUIRED
                    state.stop_reason = state.pending_human_action
                    self.store.update(state)
                    self.store.append_event(run_id, {
                        "type": "recovery.checkpoint_gap",
                        "action_id": action_id,
                        "result_status": result.get("status"),
                    })
                    return state
                elapsed = float(recorded.get("wall_clock_seconds", 0.0) or 0.0)
                if not math.isfinite(elapsed) or elapsed < 0:
                    raise StateError(f"provider action {action_id} has invalid wall-clock evidence")
                state.iteration_count = iteration
                state.provider_session_id = recorded.get("session_id") or state.provider_session_id
                state.head_sha = observed_head
                state.last_action = {
                    "type": "provider.iteration",
                    "iteration": iteration,
                    "wall_clock_seconds": elapsed,
                    "cost_usd": recorded.get("cost_usd"),
                    "recovered_action_id": action_id,
                }
                state.wall_clock_seconds += elapsed
                cost = recorded.get("cost_usd")
                if cost is not None and self._cost_issue(cost) is None:
                    state.cost_usd = (state.cost_usd or 0) + float(cost)
                state.status = RunStatus.RESUMABLE
                state.pending_human_action = None
                state.stop_reason = None
                state.next_action = "verify recovered provider iteration"
                self.store.update(state)
                self.store.append_event(
                    run_id,
                    {
                        "type": "recovery.checkpoint_reconciled",
                        "action_id": action_id,
                        "iteration": iteration,
                        "session_id": recorded.get("session_id"),
                        "observed_head_sha": observed_head,
                    },
                )
            for intent in self.store.pending_actions(run_id):
                action_id = intent["action_id"]
                action_type = intent["action_type"]
                try:
                    if action_type == "jira.progress" and self.jira is not None:
                        result = self.jira.reconcile(state, action_id, intent["payload"])
                        self.store.record_action_result(run_id, action_id, "SUCCEEDED", result)
                    elif action_type == "provider.iteration":
                        # The persisted session id belongs to the last
                        # checkpoint, not necessarily to this intent. Without
                        # an action-bound provider idempotency key, inspecting
                        # it could falsely reconcile an older session and then
                        # replay this iteration. Require explicit human
                        # reconciliation until the provider supplies that key.
                        raise UnknownAction(action_type)
                    else:
                        raise UnknownAction(action_type)
                except Exception as exc:
                    state.pending_human_action = f"Reconcile action {action_id}: {exc}"
                    state.status = RunStatus.HUMAN_ACTION_REQUIRED
                    state.stop_reason = state.pending_human_action
                    self.store.update(state)
                    self.store.append_event(run_id, {"type": "recovery.human_action", "action_id": action_id})
                    return state
            if state.status in {RunStatus.PAUSED, RunStatus.BLOCKED, RunStatus.FAILED}:
                state.status = RunStatus.RESUMABLE
                state.stop_reason = None
                state.next_action = "run worker iteration"
            self.store.append_event(run_id, {"type": "recovery.completed"})
            return self.store.update(state)
        finally:
            self.store.release_lease(run_id, lease)

    def resolve_human_action(self, run_id: str, note: str, cost_usd: Optional[float] = None) -> GoalState:
        """Acknowledge a human gate only through an explicit user-supplied note."""
        if not note.strip():
            raise GoalLoopError("human-action resolution requires a non-empty note")
        state = self.store.load(run_id)
        lease = self.store.acquire_lease(run_id, self.owner, self.lease_ttl)
        try:
            if state.status != RunStatus.HUMAN_ACTION_REQUIRED:
                raise StateError("run is not waiting for human action")
            if self.store.pending_actions(run_id):
                raise StateError("journaled external actions must be reconciled before clearing this gate")
            for intent, result in self.store.completed_actions(run_id):
                if intent.get("action_type") == "provider.iteration":
                    payload = intent.get("payload") or {}
                    if int(payload.get("iteration", 0)) > state.iteration_count:
                        raise StateError("a completed provider action needs reconciliation before clearing this gate")
            last_action = state.last_action or {}
            cost_required = (
                last_action.get("cost_usd") is None
                or "cost evidence" in str(state.pending_human_action or "").lower()
                or "cost evidence" in str(state.stop_reason or "").lower()
            )
            if cost_required:
                if cost_usd is None:
                    raise StateError("cost_usd is required to resolve a missing-cost gate")
                if self._cost_issue(cost_usd):
                    raise StateError(self._cost_issue(cost_usd) or "invalid cost evidence")
                state.cost_usd = (state.cost_usd or 0) + float(cost_usd)
                if last_action:
                    last_action["cost_usd"] = float(cost_usd)
                    state.last_action = last_action
            state.pending_human_action = None
            state.status = RunStatus.RESUMABLE
            state.stop_reason = None
            state.next_action = "run worker iteration"
            self.store.append_event(run_id, {"type": "human_action.resolved", "note": note.strip()})
            return self.store.update(state)
        finally:
            self.store.release_lease(run_id, lease)

    def recover_incomplete(self) -> list[Any]:
        """Reconcile every run while isolating corrupt state from healthy runs."""
        results: list[Any] = []
        for child in sorted(self.store.root.iterdir()):
            if not child.is_dir() or child.is_symlink() or not (child / "state.json").exists():
                continue
            try:
                state = self.store.load(child.name)
            except StateError as exc:
                results.append({
                    "run_id": child.name,
                    "status": RunStatus.HUMAN_ACTION_REQUIRED.value,
                    "error": f"corrupt GoalRun state; repair or restore before recovery: {exc}",
                })
                continue
            if state.status in {RunStatus.COMPLETED, RunStatus.CANCELLED}:
                continue
            try:
                results.append(self.recover(state.run_id))
            except GoalLoopError as exc:
                results.append({
                    "run_id": state.run_id,
                    "status": RunStatus.HUMAN_ACTION_REQUIRED.value,
                    "error": f"recovery failed; human reconciliation required: {exc}",
                })
        return results


def _print_json(value: Any) -> None:
    print(json.dumps(value, indent=2, sort_keys=True, default=str))


def cli_main(argv: Optional[list[str]] = None) -> int:
    """Command entry point used by the installed goal-loop executable."""
    import argparse

    parser = argparse.ArgumentParser(prog="goal-loop")
    parser.add_argument("--state-dir", default=".claude/goal-runs")
    sub = parser.add_subparsers(dest="command", required=True)

    start = sub.add_parser("start")
    start.add_argument("--goal", required=True)
    start.add_argument("--acceptance", action="append", default=[])
    start.add_argument("--verifier", action="append", dest="verifier_ids", default=[])
    start.add_argument("--repo", default=".")
    start.add_argument("--worktree", default=".")
    start.add_argument("--branch", required=True)
    start.add_argument("--head-sha", required=True)
    start.add_argument("--provider", choices=["claude", "codex"], default="claude")
    start.add_argument("--max-iterations", type=int, default=DEFAULT_MAX_ITERATIONS)
    start.add_argument("--max-wall-clock-seconds", type=float, default=DEFAULT_MAX_WALL_CLOCK_SECONDS)
    start.add_argument("--max-cost-usd", type=float, default=DEFAULT_MAX_COST_USD)
    start.add_argument(
        "--mutation-policy", choices=["auto", "test_only_prs", "manual", "no"], default="auto",
    )
    start.add_argument(
        "--test-only",
        action="store_true",
        help="run mutation verification only when the change is confined to tests",
    )
    start.add_argument("--jira-key")
    start.add_argument("--phase", default="in_progress")
    start.add_argument("--task", default="goal run")
    start.add_argument("--run-id")

    capabilities = sub.add_parser("capabilities")
    capabilities.add_argument("--provider", choices=["claude", "codex"], required=True)

    watch = sub.add_parser("watch")
    watch.add_argument("--run-id", required=True)
    watch.add_argument("--interval", type=float, default=60.0)
    watch.add_argument("--max-cycles", type=int, default=25)

    advise = sub.add_parser("advise")
    advise.add_argument("--scope", required=True)
    advise.add_argument("--findings", required=True, help="JSON array of read-only findings")
    advise.add_argument("--run-id", help="persist proposals in an existing GoalRun")

    approve_advisory = sub.add_parser("approve-advisory")
    approve_advisory.add_argument("--run-id", required=True)
    approve_advisory.add_argument("--proposal-id", required=True)

    merge_gate = sub.add_parser("merge-gate")
    merge_gate.add_argument("--repo", required=True)
    merge_gate.add_argument("--pr", type=int, required=True)
    merge_gate.add_argument(
        "--worktree",
        help="optional clean checkout to bind evidence to; GitHub-live evidence works without one",
    )
    merge_gate.add_argument("--evidence", help="optional audit evidence file; live evidence is always recollected")
    merge_gate.add_argument(
        "--marker-dir",
        default=os.environ.get("CLAUDE_STATE_DIR", str(Path.home() / ".claude")),
    )

    for name in (
        "status", "advisor-status", "advisor-cycle", "recover", "resume",
        "pause", "cancel", "iterate", "complete",
    ):
        command = sub.add_parser(name)
        command.add_argument("--run-id", required=(name != "status"))
        if name == "resume":
            command.add_argument(
                "--resolve-human-action", metavar="NOTE",
                help="explicitly acknowledge a HUMAN_ACTION_REQUIRED gate",
            )
            command.add_argument("--cost-usd", type=float, help="cost consumed by the resolved action")
    sub.add_parser("recover-all")

    args = parser.parse_args(argv)
    try:
        store = GoalStore(args.state_dir)
        def make_loop(current: GoalState) -> GoalLoop:
            registry = ToolboxVerificationRegistry(
                current.worktree, baseline_sha=current.head_sha
            ).mapping()
            providers = ProviderAdapterRegistry.from_environment()
            provider = providers.select(current.provider)
            jira = JiraStewardAdapter.from_environment() if current.jira.get("key") else None
            return GoalLoop(
                store,
                provider,
                VerificationRunner(registry),
                provider_registry=providers,
                jira=jira,
            )

        if args.command == "start":
            state = store.create(
                goal=args.goal,
                acceptance_criteria=args.acceptance,
                verifier_ids=args.verifier_ids,
                repo=args.repo,
                worktree=args.worktree,
                branch=args.branch,
                head_sha=args.head_sha,
                provider=args.provider,
                jira_key=args.jira_key,
                max_iterations=args.max_iterations,
                max_wall_clock_seconds=args.max_wall_clock_seconds,
                max_cost_usd=args.max_cost_usd,
                mutation_policy=args.mutation_policy,
                test_only=args.test_only,
                run_id=args.run_id,
                current_phase=args.phase,
                current_task=args.task,
            )
            _print_json(state.to_dict())
            return 0
        if args.command == "status":
            if args.run_id:
                _print_json(store.load(args.run_id).to_dict())
            else:
                runs = []
                for child in sorted(store.root.iterdir()):
                    if child.is_dir() and not child.is_symlink() and (child / "state.json").exists():
                        try:
                            runs.append(store.load(child.name).to_dict())
                        except StateError:
                            runs.append({"run_id": child.name, "status": "UNREADABLE"})
                _print_json(runs)
            return 0
        if args.command == "capabilities":
            _print_json(CapabilityDetector().detect(args.provider))
            return 0
        if args.command == "watch":
            if args.interval < 0 or args.max_cycles < 1:
                raise GoalLoopError("watch interval must be non-negative and max-cycles must be positive")
            for cycle in range(1, args.max_cycles + 1):
                current = store.load(args.run_id)
                if current.status in {RunStatus.BLOCKED, RunStatus.FAILED} and (
                    current.pending_advisor_reviews or current.pending_advisor_review
                ):
                    make_loop(current).advisor_cycle(args.run_id)
                    current = store.load(args.run_id)
                    _print_json({
                        "run_id": current.run_id,
                        "cycle": cycle,
                        "phase": "advisor",
                        "status": current.status.value,
                        "provider": current.provider,
                        "iteration": current.iteration_count,
                        "next_action": current.next_action,
                    })
                    if current.status not in {RunStatus.RESUMABLE, RunStatus.RUNNING}:
                        return 0
                if current.status not in {RunStatus.RUNNING, RunStatus.RESUMABLE}:
                    _print_json({
                        "run_id": current.run_id,
                        "cycle": cycle - 1,
                        "status": current.status.value,
                        "provider": current.provider,
                        "iteration": current.iteration_count,
                        "next_action": current.next_action,
                    })
                    return 0
                current = make_loop(current).run_iteration(args.run_id)
                _print_json({
                    "run_id": current.run_id,
                    "cycle": cycle,
                    "status": current.status.value,
                    "provider": current.provider,
                    "iteration": current.iteration_count,
                    "next_action": current.next_action,
                })
                if current.status != RunStatus.RUNNING or cycle == args.max_cycles:
                    return 0
                if args.interval:
                    time.sleep(args.interval)
            return 0
        if args.command == "advise":
            try:
                findings = json.loads(Path(args.findings).read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError) as exc:
                raise GoalLoopError(f"cannot read advisory findings: {exc}") from exc
            if not isinstance(findings, list):
                raise GoalLoopError("advisory findings must be a JSON array")
            proposals = [dataclasses.asdict(item) for item in AdvisoryDiscovery().rank(args.scope, findings)]
            if args.run_id:
                proposals = store.record_advisory_proposals(args.run_id, proposals)
            _print_json(proposals)
            return 0
        if args.command == "approve-advisory":
            _print_json(store.approve_advisory_proposal(args.run_id, args.proposal_id))
            return 0
        if args.command == "merge-gate":
            evidence = {}
            if args.evidence:
                try:
                    evidence = json.loads(Path(args.evidence).read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError) as exc:
                    raise GoalLoopError(f"cannot read merge evidence: {exc}") from exc
                if not isinstance(evidence, dict):
                    raise GoalLoopError("merge evidence must be a JSON object")
            # Caller-supplied evidence is retained only as an audit input. A
            # non-toolbox repo is rejected without probing it; the toolbox gate
            # collects live GitHub, thread, changed-file, and local HEAD evidence.
            if args.repo != MergePolicy.TOOLBOX_REPO:
                result = MergePolicy.evaluate(args.repo, evidence)
                _print_json(result)
                return 1
            live = MergePolicy.collect_live_evidence(
                args.repo, args.pr, args.worktree
            )
            result = MergePolicy.evaluate(args.repo, live)
            if result["allowed"]:
                marker = MergePolicy.write_marker(
                    args.repo, args.pr, args.marker_dir,
                    head_sha=str(live["current_head_sha"]),
                )
                result["marker"] = str(marker)
            _print_json(result)
            return 0 if result["allowed"] else 1
        if args.command == "recover-all":
            recovered = []
            for result in GoalLoop(
                store, UnavailableProvider("recovery"), VerificationRunner({}),
                jira=JiraStewardAdapter.from_environment(),
            ).recover_incomplete():
                if isinstance(result, GoalState):
                    recovered.append(result.to_dict())
                else:
                    recovered.append(result)
            _print_json(recovered)
            return 0
        state = store.load(args.run_id)
        if args.command == "iterate":
            _print_json(make_loop(state).run_iteration(args.run_id).to_dict())
        elif args.command == "advisor-status":
            _print_json(state.last_advisor_assessment or {})
        elif args.command == "advisor-cycle":
            _print_json(make_loop(state).advisor_cycle(args.run_id))
        elif args.command == "recover":
            _print_json(make_loop(state).recover(args.run_id).to_dict())
        elif args.command == "pause":
            store.transition(args.run_id, RunStatus.PAUSED)
            _print_json(store.load(args.run_id).to_dict())
        elif args.command == "resume":
            if args.resolve_human_action:
                _print_json(make_loop(state).resolve_human_action(
                    args.run_id, args.resolve_human_action, args.cost_usd
                ).to_dict())
                return 0
            state = make_loop(state).recover(args.run_id)
            if state.status == RunStatus.HUMAN_ACTION_REQUIRED:
                _print_json(state.to_dict())
                return 2
            _print_json(store.load(args.run_id).to_dict())
        elif args.command == "cancel":
            if state.status not in {RunStatus.CANCELLED, RunStatus.COMPLETED}:
                store.transition(args.run_id, RunStatus.CANCELLED)
            _print_json(store.load(args.run_id).to_dict())
        elif args.command == "complete":
            if state.status != RunStatus.COMPLETE_CANDIDATE:
                raise StateError("a GoalRun can be completed only from COMPLETE_CANDIDATE")
            store.transition(args.run_id, RunStatus.COMPLETED)
            _print_json(store.load(args.run_id).to_dict())
        return 0
    except GoalLoopError as exc:
        print(f"goal-loop: {exc}", file=os.sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(cli_main())
