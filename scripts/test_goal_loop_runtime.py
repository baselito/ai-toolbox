#!/usr/bin/env python3
"""Offline contract tests for the durable goal-loop runtime."""

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))

from goal_loop_runtime import (  # noqa: E402
    Advisor,
    AdvisorClass,
    CapabilityDetector,
    GoalLoop,
    GoalLoopError,
    GoalStore,
    JiraStewardAdapter,
    MergePolicy,
    MutationTestingRegistry,
    AdvisoryProposal,
    AdvisoryDiscovery,
    UnavailableProvider,
    LeaseError,
    ProviderResult,
    ProviderAdapter,
    RoleAssignment,
    RunStatus,
    StateError,
    ToolboxVerificationRegistry,
    VerificationError,
    VerificationRunner,
    cli_main,
)
import goal_loop_runtime as runtime  # noqa: E402


class FakeProvider:
    def __init__(self, result=None):
        self.result = result or ProviderResult(session_id="session-1", changed=True)
        self.calls = 0
        self.assignments = []
        self.advisor_assignments = []

    def start_iteration(self, state, assignment=None):
        self.calls += 1
        self.assignments.append(assignment)
        return self.result

    def start_advisor(self, state, incident, assignment):
        self.advisor_assignments.append(assignment)
        return ProviderResult()

    def inspect_session(self, session_id):
        return {"status": "finished", "session_id": session_id}

    def capabilities(self):
        return {"local_cli": True}


class FakeJira:
    def __init__(self, fail=False):
        self.fail = fail
        self.calls = []
        self.reconciled = []

    def progress(self, state, action_id):
        self.calls.append(action_id)
        if self.fail:
            raise RuntimeError("acli unavailable")
        return {"action_id": action_id, "status": "applied", "phase": "in_progress"}

    def reconcile(self, state, action_id, payload):
        self.reconciled.append(action_id)
        return {"action_id": action_id, "status": "already_applied"}


class GoalLoopRuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.store = GoalStore(self.root)
        self.state = self.store.create(
            goal="Implement the durable loop",
            acceptance_criteria=["all required gates pass"],
            verifier_ids=["test"],
            repo=self.root,
            worktree=self.root,
            branch="feature/GOAL-1-loop",
            head_sha="sha-1",
            provider="claude",
            jira_key="GOAL-1",
            max_wall_clock_seconds=60,
            max_cost_usd=1.0,
        )
        # These fixtures model a worktree without creating Git metadata. The
        # production runtime still fails closed when its real Git lookup
        # cannot observe HEAD; here we stub that external lookup so each test
        # can exercise the behavior under test.
        self.observed_head_patch = patch.object(
            GoalLoop, "_observed_head_sha", staticmethod(lambda state: state.head_sha)
        )
        self.observed_head_patch.start()

    def tearDown(self):
        self.observed_head_patch.stop()
        self.temp.cleanup()

    def test_state_transitions_are_explicit(self):
        self.store.transition(self.state.run_id, RunStatus.PAUSED)
        self.assertEqual(self.store.load(self.state.run_id).status, RunStatus.PAUSED)
        with self.assertRaises(StateError):
            self.store.transition(self.state.run_id, RunStatus.COMPLETED)

    def test_atomic_state_rejects_corrupt_and_symlink_files(self):
        state_path = self.store.state_path(self.state.run_id)
        state_path.write_text("{not-json", encoding="utf-8")
        with self.assertRaises(StateError):
            self.store.load(self.state.run_id)

        state_path.unlink()
        state_path.symlink_to(self.root / "elsewhere")
        with self.assertRaises(StateError):
            self.store.load(self.state.run_id)

    def test_run_store_rejects_dot_and_parent_run_ids(self):
        for run_id in (".", ".."):
            with self.assertRaises(StateError):
                self.store.state_path(run_id)

    def test_journal_recovery_does_not_repeat_applied_jira_action(self):
        action_id = self.store.record_intent(
            self.state.run_id, "jira.progress", {"phase": "in_progress"}
        )
        self.store.record_action_result(
            self.state.run_id, action_id, "UNKNOWN", {"reason": "crash"}
        )
        jira = FakeJira()
        loop = GoalLoop(self.store, FakeProvider(), self._verifiers(), jira=jira)
        loop.recover(self.state.run_id)
        self.assertEqual(jira.reconciled, [action_id])
        self.assertEqual(self.store.pending_actions(self.state.run_id), [])

    def test_recovery_skips_jira_action_that_was_successful_before_checkpoint(self):
        action_id = self.store.record_intent(
            self.state.run_id, "jira.progress", {"phase": "in_progress"}
        )
        self.store.record_action_result(
            self.state.run_id, action_id, "SUCCEEDED", {"status": "applied"}
        )
        jira = FakeJira()
        loop = GoalLoop(self.store, FakeProvider(), self._verifiers(), jira=jira)
        loop.recover(self.state.run_id)
        self.assertEqual(jira.reconciled, [])


    def test_advisor_classifies_idle_stale_and_failed_evidence(self):
        advisor = Advisor(idle_after=5, stale_after=10)
        idle = advisor.assess(self.state, ProviderResult(), [], {"status": "KEEP_GOING"}, age=6)
        stale = advisor.assess(self.state, ProviderResult(), [], {"status": "KEEP_GOING"}, age=11)
        failed = advisor.assess(
            self.state,
            ProviderResult(error="provider failed"),
            [{"key": "test", "status": "FAIL"}],
            {"status": "STOP"},
            age=0,
        )
        self.assertEqual(idle.classification, AdvisorClass.IDLE)
        self.assertEqual(stale.classification, AdvisorClass.STALE)
        self.assertEqual(failed.classification, AdvisorClass.FAILED)

    def test_progress_detector_runs_on_every_iteration(self):
        calls = []

        def detector(state, evidence):
            calls.append((state.run_id, evidence))
            return {"status": "KEEP_GOING", "signature": "test:error"}

        loop = GoalLoop(
            self.store,
            FakeProvider(),
            self._verifiers(),
            progress_detector=detector,
            jira=FakeJira(),
        )
        loop.run_iteration(self.state.run_id)
        loop.run_iteration(self.state.run_id)
        self.assertEqual(len(calls), 2)

    def test_verification_rejects_stale_sha_evidence(self):
        runner = VerificationRunner(
            {"test": lambda context: {"status": "PASS", "sha": "old", "worktree": str(self.root)}}
        )
        evidence = runner.run(["test"], current_sha="sha-1", worktree=self.root)
        self.assertEqual(evidence[0]["status"], "STALE")
        self.assertFalse(runner.completable(evidence))

    def test_verification_rejects_changed_worktree_evidence(self):
        runner = VerificationRunner({
            "test": lambda context: {
                "status": "PASS", "sha": context["current_sha"],
                "worktree": context["worktree"],
                "worktree_fingerprint": "provider-observed",
            }
        })
        runner._worktree_fingerprint = lambda worktree: "runner-observed"
        evidence = runner.run(["test"], current_sha="sha-1", worktree=self.root)
        self.assertEqual(evidence[0]["status"], "STALE")
        self.assertIn("worktree_fingerprint", evidence[0])

    def test_toolbox_registry_uses_fixed_argument_lists_for_detected_project(self):
        (self.root / "package.json").write_text("{}", encoding="utf-8")
        calls = []

        def command_runner(argv, **kwargs):
            calls.append((argv, kwargs))
            return {"returncode": 0, "stdout": "0 failures", "stderr": ""}

        registry = ToolboxVerificationRegistry(self.root, command_runner=command_runner)
        mapping = registry.mapping()
        result = mapping["test"](
            {"current_sha": "sha-1", "worktree": str(self.root)}
        )
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(calls[0][0], ["npm", "test"])
        self.assertEqual(calls[0][1]["cwd"], str(self.root.resolve()))
        self.assertFalse(calls[0][1]["shell"])

    def test_toolbox_registry_prefers_lockfile_package_manager(self):
        (self.root / "package.json").write_text("{}", encoding="utf-8")
        (self.root / "pnpm-lock.yaml").write_text("lockfileVersion: 9\n", encoding="utf-8")
        calls = []

        def command_runner(argv, **kwargs):
            calls.append(argv)
            return {"returncode": 0, "stdout": "", "stderr": ""}

        result = ToolboxVerificationRegistry(self.root, command_runner=command_runner).mapping()["test"](
            {"current_sha": "sha-1", "worktree": str(self.root)}
        )
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(calls[0], ["pnpm", "test"])

    def test_mutation_registry_uses_fixed_stryker_command_for_node(self):
        (self.root / "package.json").write_text(
            json.dumps({"devDependencies": {"vitest": "latest", "@stryker-mutator/core": "latest"}}), encoding="utf-8"
        )
        (self.root / "src").mkdir()
        (self.root / "src" / "app.js").write_text("export const answer = 42;\n", encoding="utf-8")
        calls = []

        def command_runner(argv, **kwargs):
            calls.append((argv, kwargs))
            report = self.root / "reports" / "mutation" / "mutation.json"
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text(json.dumps({"metrics": {"mutationScore": 91}}), encoding="utf-8")
            return {"returncode": 0, "stdout": "", "stderr": ""}

        registry = MutationTestingRegistry(
            self.root, base_sha="sha-1", command_runner=command_runner
        )
        result = registry.run({"current_sha": "sha-2", "worktree": str(self.root)})
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["mutation_score"], 91.0)
        self.assertEqual(result["provenance"]["sha"], "sha-2")
        self.assertEqual(result["provenance"]["source"], "fresh report from registered mutation invocation")
        self.assertEqual(calls[0][0], ["npx", "--no-install", "stryker", "run"])
        self.assertFalse(calls[0][1]["shell"])

    def test_mutation_registry_distinguishes_missing_runner_and_bad_report(self):
        (self.root / "package.json").write_text(
            json.dumps({"devDependencies": {"@stryker-mutator/core": "latest"}}), encoding="utf-8"
        )
        (self.root / "src").mkdir()
        (self.root / "src" / "app.js").write_text("export const answer = 42;\n", encoding="utf-8")
        unavailable = MutationTestingRegistry(
            self.root, base_sha="sha-1", executable_lookup=lambda name: None
        ).run({"current_sha": "sha-2", "worktree": str(self.root)})
        self.assertEqual(unavailable["status"], "UNAVAILABLE")

        def bad_report(argv, **kwargs):
            report = self.root / "mutation.json"
            report.write_text(json.dumps({"files": []}), encoding="utf-8")
            return {"returncode": 0, "stdout": "", "stderr": ""}

        malformed = MutationTestingRegistry(
            self.root, base_sha="sha-1", command_runner=bad_report,
            executable_lookup=lambda name: "/usr/bin/" + name,
        ).run({"current_sha": "sha-2", "worktree": str(self.root)})
        self.assertEqual(malformed["status"], "FAIL")

    def test_mutation_registry_rejects_non_finite_scores(self):
        (self.root / "package.json").write_text(
            json.dumps({"devDependencies": {"@stryker-mutator/core": "latest"}}), encoding="utf-8"
        )
        (self.root / "src").mkdir()
        (self.root / "src" / "app.js").write_text("export const answer = 42;\n", encoding="utf-8")

        def non_finite_report(argv, **kwargs):
            report = self.root / "mutation.json"
            report.write_text('{"metrics":{"mutationScore":NaN}}', encoding="utf-8")
            return {"returncode": 0, "stdout": "", "stderr": ""}

        result = MutationTestingRegistry(
            self.root, base_sha="sha-1", command_runner=non_finite_report,
            executable_lookup=lambda name: "/usr/bin/" + name,
        ).run({"current_sha": "sha-2", "worktree": str(self.root)})
        self.assertEqual(result["status"], "FAIL")
        self.assertNotIn("mutation_score", result)
        self.assertIn("numeric score", result["reason"])

    def test_mutation_registry_rejects_overflowing_counts(self):
        (self.root / "package.json").write_text(
            json.dumps({"devDependencies": {"@stryker-mutator/core": "latest"}}), encoding="utf-8"
        )
        (self.root / "src").mkdir()
        (self.root / "src" / "app.js").write_text("export const answer = 42;\n", encoding="utf-8")

        def overflowing_report(argv, **kwargs):
            report = self.root / "mutation.json"
            report.write_text('{"metrics":{"killed":' + ("9" * 1000) + '}}', encoding="utf-8")
            return {"returncode": 0, "stdout": "", "stderr": ""}

        result = MutationTestingRegistry(
            self.root, base_sha="sha-1", command_runner=overflowing_report,
            executable_lookup=lambda name: "/usr/bin/" + name,
        ).run({"current_sha": "sha-2", "worktree": str(self.root)})
        self.assertEqual(result["status"], "FAIL")
        self.assertIn("numeric score", result["reason"])

    def test_mutation_registry_rejects_report_from_another_sha_or_worktree(self):
        (self.root / "package.json").write_text(
            json.dumps({"devDependencies": {"@stryker-mutator/core": "latest"}}), encoding="utf-8"
        )
        (self.root / "src").mkdir()
        (self.root / "src" / "app.js").write_text("export const answer = 42;\n", encoding="utf-8")

        def stale_report(argv, **kwargs):
            report = self.root / "mutation.json"
            report.write_text(json.dumps({
                "metadata": {"sha": "old-sha", "worktree": "/tmp/old-worktree"},
                "metrics": {"mutationScore": 99},
            }), encoding="utf-8")
            return {"returncode": 0, "stdout": "", "stderr": ""}

        result = MutationTestingRegistry(
            self.root, base_sha="sha-1", command_runner=stale_report,
            executable_lookup=lambda name: "/usr/bin/" + name,
        ).run({"current_sha": "sha-2", "worktree": str(self.root)})
        self.assertEqual(result["status"], "FAIL")
        self.assertIn("stale", result["reason"])

    def test_mutation_registry_rejects_unchanged_unbound_report(self):
        (self.root / "package.json").write_text(
            json.dumps({"devDependencies": {"@stryker-mutator/core": "latest"}}), encoding="utf-8"
        )
        (self.root / "src").mkdir()
        (self.root / "src" / "app.js").write_text("export const answer = 42;\n", encoding="utf-8")
        report = self.root / "mutation.json"
        report.write_text(json.dumps({"metrics": {"mutationScore": 99}}), encoding="utf-8")

        result = MutationTestingRegistry(
            self.root,
            base_sha="sha-1",
            command_runner=lambda argv, **kwargs: {"returncode": 0, "stdout": "", "stderr": ""},
            executable_lookup=lambda name: "/usr/bin/" + name,
        ).run({"current_sha": "sha-2", "worktree": str(self.root)})
        self.assertEqual(result["status"], "FAIL")
        self.assertIn("structured JSON report", result["reason"])

    def test_mutation_registry_marks_python_as_not_applicable(self):
        (self.root / "pyproject.toml").write_text("[tool.pytest.ini_options]\n", encoding="utf-8")
        registry = MutationTestingRegistry(self.root, base_sha="sha-1")
        result = registry.run({"current_sha": "sha-2", "worktree": str(self.root)})
        self.assertEqual(result["status"], "NOT_APPLICABLE")
        self.assertIn("Stryker", result["reason"])

    def test_mutation_registry_parses_stryker_score_counts_threshold_and_survivors(self):
        (self.root / "package.json").write_text(
            json.dumps({"devDependencies": {"@stryker-mutator/core": "latest"}}), encoding="utf-8"
        )
        (self.root / "src").mkdir()
        (self.root / "src" / "app.js").write_text("export const answer = 42;\n", encoding="utf-8")

        def command_runner(argv, **kwargs):
            report = self.root / "reports" / "mutation" / "mutation.json"
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text(json.dumps({
                "metrics": {"score": 0.91, "killed": 91, "survived": 9, "total": 100},
                "thresholds": {"high": 80, "low": 60},
                "files": {"src/app.js": {"mutants": [
                    {"status": "Survived", "location": {"start": {"line": 1, "column": 1}}},
                ]}},
            }), encoding="utf-8")
            return {"returncode": 0, "stdout": "", "stderr": ""}

        result = MutationTestingRegistry(
            self.root, base_sha="sha-1", command_runner=command_runner,
            executable_lookup=lambda name: "/usr/bin/" + name,
        ).run({"current_sha": "sha-2", "worktree": str(self.root)})
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["mutation_score"], 91.0)
        self.assertEqual(result["sha"], "sha-2")
        self.assertEqual(result["threshold"], 80.0)
        self.assertEqual(result["mutant_counts"]["total"], 100)
        self.assertEqual(len(result["surviving_mutants"]), 1)

    def test_mutation_registry_calculates_score_from_stryker_counts_and_enforces_threshold(self):
        (self.root / "package.json").write_text(
            json.dumps({"devDependencies": {"@stryker-mutator/core": "latest"}}), encoding="utf-8"
        )
        (self.root / "src").mkdir()
        (self.root / "src" / "app.js").write_text("export const answer = 42;\n", encoding="utf-8")

        def command_runner(argv, **kwargs):
            report = self.root / "mutation.json"
            report.write_text(json.dumps({
                "metrics": {"killed": 5, "survived": 5, "timeout": 0},
                "thresholds": {"high": 80},
            }), encoding="utf-8")
            return {"returncode": 0, "stdout": "", "stderr": ""}

        result = MutationTestingRegistry(
            self.root, base_sha="sha-1", command_runner=command_runner,
            executable_lookup=lambda name: "/usr/bin/" + name,
        ).run({"current_sha": "sha-2", "worktree": str(self.root)})
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["mutation_score"], 50.0)
        self.assertEqual(result["threshold"], 80.0)
        self.assertIn("threshold", result["reason"])

    def test_mutation_registry_parses_standard_stryker_report_schema(self):
        (self.root / "package.json").write_text(
            json.dumps({"devDependencies": {"@stryker-mutator/core": "latest"}}), encoding="utf-8"
        )
        (self.root / "src").mkdir()
        (self.root / "src" / "app.js").write_text("export const answer = 42;\n", encoding="utf-8")

        def command_runner(argv, **kwargs):
            report = self.root / "reports" / "stryker" / "mutation.json"
            report.parent.mkdir(parents=True, exist_ok=True)
            report.write_text(json.dumps({
                "schemaVersion": "2.0.0",
                "thresholds": {"high": 40, "low": 20, "break": 0},
                "files": {"src/app.js": {"language": "javascript", "source": "...", "mutants": [
                    {"id": "1", "mutatorName": "EqualityOperator", "status": "Killed",
                     "location": {"start": {"line": 1, "column": 1}}},
                    {"id": "2", "mutatorName": "EqualityOperator", "status": "Survived",
                     "location": {"start": {"line": 1, "column": 2}}},
                    {"id": "3", "mutatorName": "EqualityOperator", "status": "NoCoverage",
                     "location": {"start": {"line": 1, "column": 3}}},
                    {"id": "4", "mutatorName": "EqualityOperator", "status": "Timeout",
                     "location": {"start": {"line": 1, "column": 4}}},
                    {"id": "5", "mutatorName": "EqualityOperator", "status": "RuntimeError",
                     "location": {"start": {"line": 1, "column": 5}}},
                    {"id": "6", "mutatorName": "EqualityOperator", "status": "CompileError",
                     "location": {"start": {"line": 1, "column": 6}}},
                    {"id": "7", "mutatorName": "EqualityOperator", "status": "Ignored",
                     "location": {"start": {"line": 1, "column": 7}}},
                    {"id": "8", "mutatorName": "EqualityOperator", "status": "Pending",
                     "location": {"start": {"line": 1, "column": 8}}},
                ]}},
            }), encoding="utf-8")
            return {"returncode": 0, "stdout": "", "stderr": ""}

        result = MutationTestingRegistry(
            self.root, base_sha="sha-1", command_runner=command_runner,
            executable_lookup=lambda name: "/usr/bin/" + name,
        ).run({"current_sha": "sha-2", "worktree": str(self.root)})
        self.assertEqual(result["status"], "PASS")
        self.assertEqual(result["mutation_score"], 50.0)
        self.assertEqual(result["mutant_counts"], {
            "killed": 1, "survived": 1, "no_coverage": 1, "timeout": 1,
            "runtime_errors": 1, "compile_errors": 1, "ignored": 1,
            "pending": 1, "total": 8,
        })
        self.assertEqual(result["surviving_mutants"][0]["file"], "src/app.js")

    def test_mutation_registry_rejects_production_changes_in_test_only_mode(self):
        (self.root / "package.json").write_text(
            json.dumps({"devDependencies": {"@stryker-mutator/core": "latest"}}), encoding="utf-8"
        )
        (self.root / "src").mkdir()
        (self.root / "src" / "app.js").write_text("export const answer = 42;\n", encoding="utf-8")
        registry = MutationTestingRegistry(
            self.root, base_sha="sha-1", executable_lookup=lambda name: "/usr/bin/" + name,
        )
        registry._changed_files = lambda current_sha: ["src/app.js"]
        result = registry.run({"current_sha": "sha-2", "worktree": str(self.root), "test_only": True})
        self.assertEqual(result["status"], "FAIL")
        self.assertEqual(result["production_files"], ["src/app.js"])

    def test_recover_all_isolates_corrupt_runs(self):
        corrupt = self.root / "runs" / "gr_corrupt"
        corrupt.mkdir(parents=True)
        (corrupt / "state.json").write_text("{not-json", encoding="utf-8")
        malformed = self.root / "runs" / "gr_malformed"
        malformed.mkdir(parents=True)
        malformed_state = self.state.to_dict()
        malformed_state.pop("cost_usd")
        (malformed / "state.json").write_text(json.dumps(malformed_state), encoding="utf-8")
        healthy = GoalStore(self.root / "runs").create(
            goal="recover", acceptance_criteria=[], verifier_ids=[], repo=self.root,
            worktree=self.root, branch="feature/recover", head_sha="sha-1", provider="claude",
            run_id="gr_healthy",
        )
        results = GoalLoop(
            GoalStore(self.root / "runs"), FakeProvider(), self._verifiers()
        ).recover_incomplete()
        self.assertEqual(
            {item["run_id"] for item in results if isinstance(item, dict)},
            {"gr_corrupt", "gr_malformed"},
        )
        self.assertTrue(any(getattr(item, "run_id", None) == healthy.run_id for item in results))

    def test_verification_runner_adds_registered_mutation_gate_by_default(self):
        runner = VerificationRunner(
            {
                "test": lambda context: {
                    "status": "PASS", "sha": context["current_sha"],
                    "worktree": context["worktree"],
                },
                "mutation": lambda context: {
                    "status": "NOT_APPLICABLE", "sha": context["current_sha"],
                    "worktree": context["worktree"], "reason": "docs-only change",
                },
            }
        )
        evidence = runner.run(["test"], "sha-1", self.root)
        self.assertEqual([item["key"] for item in evidence], ["test", "mutation"])
        self.assertTrue(runner.completable(evidence))

    def test_verification_runner_can_skip_or_advisory_report_mutation(self):
        runner = VerificationRunner({
            "test": lambda context: {
                "status": "PASS", "sha": context["current_sha"],
                "worktree": context["worktree"],
            },
            "mutation": lambda context: {
                "status": "FAIL", "sha": context["current_sha"],
                "worktree": context["worktree"], "reason": "survivors",
            },
        })
        skipped = runner.run(["test"], "sha-1", self.root, mutation_policy="manual")
        self.assertEqual(skipped[-1]["status"], "NOT_APPLICABLE")
        failed = runner.run(["test"], "sha-1", self.root, mutation_policy="auto")
        self.assertEqual(failed[-1]["status"], "FAIL")
        self.assertFalse(runner.completable(failed))

    def test_state_preserves_unknown_same_schema_fields(self):
        raw = self.state.to_dict()
        raw["future_extension"] = {"owner": "new-runtime", "enabled": True}
        restored = runtime.GoalState.from_dict(raw)
        self.assertEqual(restored.to_dict()["future_extension"], raw["future_extension"])

    def test_resume_does_not_clear_human_action_gate(self):
        provider = FakeProvider(ProviderResult(human_action_required="approve provider access"))
        loop = GoalLoop(self.store, provider, self._verifiers())
        loop.run_iteration(self.state.run_id)
        self.assertEqual(
            cli_main(["--state-dir", str(self.store.root), "resume", "--run-id", self.state.run_id]),
            2,
        )
        self.assertEqual(self.store.load(self.state.run_id).status, RunStatus.HUMAN_ACTION_REQUIRED)

    def test_resume_can_acknowledge_resolved_human_action_explicitly(self):
        provider = FakeProvider(ProviderResult(human_action_required="approve provider access"))
        loop = GoalLoop(self.store, provider, self._verifiers())
        loop.run_iteration(self.state.run_id)
        self.assertEqual(
            cli_main([
                "--state-dir", str(self.store.root), "resume", "--run-id", self.state.run_id,
                "--resolve-human-action", "access approved by user",
            ]),
            0,
        )
        resumed = self.store.load(self.state.run_id)
        self.assertEqual(resumed.status, RunStatus.RESUMABLE)
        self.assertIsNone(resumed.pending_human_action)

    def test_verifier_resolution_failure_checkpoints_provider_iteration(self):
        provider = FakeProvider(ProviderResult(changed=True))
        loop = GoalLoop(self.store, provider, VerificationRunner({}))
        state = loop.run_iteration(self.state.run_id)
        self.assertEqual(state.status, RunStatus.BLOCKED)
        self.assertEqual(provider.calls, 1)
        loop.run_iteration(self.state.run_id)
        self.assertEqual(provider.calls, 1)

    def test_actual_provider_time_counts_when_result_omits_duration(self):
        class SlowProvider(FakeProvider):
            def start_iteration(self, state, assignment=None):
                time.sleep(0.02)
                return super().start_iteration(state, assignment)

        provider = SlowProvider(ProviderResult(changed=True))
        loop = GoalLoop(self.store, provider, self._verifiers())
        loop.run_iteration(self.state.run_id)
        self.assertGreaterEqual(self.store.load(self.state.run_id).wall_clock_seconds, 0.02)

    def test_missing_provider_cost_evidence_requires_human_action(self):
        provider = FakeProvider(ProviderResult(changed=True, cost_usd=None))
        loop = GoalLoop(self.store, provider, self._verifiers())
        loop.run_iteration(self.state.run_id)
        state = self.store.load(self.state.run_id)
        self.assertEqual(state.status, RunStatus.HUMAN_ACTION_REQUIRED)
        self.assertIn("cost evidence", state.pending_human_action.lower())
        with self.assertRaises(StateError):
            loop.resolve_human_action(self.state.run_id, "usage checked")
        resolved = loop.resolve_human_action(self.state.run_id, "usage checked", 0.25)
        self.assertEqual(resolved.status, RunStatus.RESUMABLE)
        self.assertAlmostEqual(resolved.cost_usd, 0.25)

    def test_negative_provider_cost_evidence_requires_human_action(self):
        provider = FakeProvider(ProviderResult(changed=True, cost_usd=-1.0))
        loop = GoalLoop(self.store, provider, self._verifiers())
        loop.run_iteration(self.state.run_id)
        state = self.store.load(self.state.run_id)
        self.assertEqual(state.status, RunStatus.HUMAN_ACTION_REQUIRED)
        self.assertIn("non-finite or negative", state.pending_human_action.lower())

    def test_jira_bridge_rejects_unconfirmed_or_mismatched_results(self):
        with patch.dict(os.environ, {"GOAL_LOOP_JIRA_STEWARD_COMMAND": "jira-steward"}):
            adapter = JiraStewardAdapter.from_environment()
        with patch("goal_loop_runtime.subprocess.run", return_value=SimpleNamespace(
            returncode=0, stdout="{}", stderr=""
        )):
            with self.assertRaises(GoalLoopError):
                adapter.steward_call({"action_id": "act-1"})

    def test_goal_loop_uses_observed_head_not_provider_claim(self):
        provider = FakeProvider(ProviderResult(changed=True, new_head_sha="provider-claim"))
        loop = GoalLoop(self.store, provider, self._verifiers(), jira=FakeJira())
        heads = iter(["sha-1", "sha-2"])
        loop._observed_head_sha = lambda state: next(heads)
        loop.run_iteration(self.state.run_id)
        self.assertEqual(self.store.load(self.state.run_id).head_sha, "sha-2")

    def test_goal_loop_blocks_when_worktree_head_cannot_be_verified(self):
        provider = FakeProvider()
        loop = GoalLoop(self.store, provider, self._verifiers())
        loop._observed_head_sha = lambda state: None
        result = loop.run_iteration(self.state.run_id)
        self.assertEqual(result.status, RunStatus.HUMAN_ACTION_REQUIRED)
        self.assertIn("head", result.pending_human_action.lower())
        self.assertEqual(provider.calls, 0)

    def test_goal_loop_stops_at_iteration_ceiling(self):
        state = self.store.load(self.state.run_id)
        state.limits["max_iterations"] = 1
        self.store.update(state)
        loop = GoalLoop(self.store, FakeProvider(), self._verifiers(), jira=FakeJira())
        loop.run_iteration(self.state.run_id)
        loop.run_iteration(self.state.run_id)
        final = self.store.load(self.state.run_id)
        self.assertEqual(final.status, RunStatus.BLOCKED)
        self.assertIn("iteration", final.stop_reason.lower())

    def test_goal_loop_completes_through_cli_command(self):
        state = self.store.load(self.state.run_id)
        state.status = RunStatus.COMPLETE_CANDIDATE
        self.store.update(state)
        self.assertEqual(
            cli_main(["--state-dir", str(self.root), "complete", "--run-id", self.state.run_id]),
            0,
        )
        self.assertEqual(self.store.load(self.state.run_id).status, RunStatus.COMPLETED)

    def test_cli_start_persists_bounded_limits_and_mutation_policy(self):
        self.assertEqual(cli_main([
            "--state-dir", str(self.root), "start", "--goal", "bounded",
            "--branch", "feature/bounded", "--head-sha", "sha-1",
            "--max-iterations", "3", "--max-wall-clock-seconds", "12",
            "--max-cost-usd", "0.5", "--mutation-policy", "manual",
            "--run-id", "bounded",
        ]), 0)
        limits = self.store.load("bounded").limits
        self.assertEqual(limits["max_iterations"], 3)
        self.assertEqual(limits["max_wall_clock_seconds"], 12)
        self.assertEqual(limits["max_cost_usd"], 0.5)
        self.assertEqual(limits["mutation_policy"], "manual")

    def test_advisor_provider_failure_escalates_without_state_error(self):
        class FailingAdvisorProvider(FakeProvider):
            def start_advisor(self, state, incident, assignment):
                raise RuntimeError("provider unavailable")

        self.store.record_operational_incident(self.state.run_id, "failed_tool_invocation", {"error": "x"})
        state = self.store.load(self.state.run_id)
        state.status = RunStatus.BLOCKED
        self.store.update(state)
        result = GoalLoop(self.store, FailingAdvisorProvider(), self._verifiers()).advisor_cycle(self.state.run_id)
        self.assertEqual(result["status"], RunStatus.HUMAN_ACTION_REQUIRED.value)

    def test_merge_policy_deduplicates_retried_checks(self):
        statuses = MergePolicy._latest_check_statuses([
            {"name": "CI", "conclusion": "FAILURE", "completedAt": "2026-08-29T10:00:00Z"},
            {"name": "CI", "conclusion": "SUCCESS", "completedAt": "2026-08-29T10:01:00Z"},
        ])
        self.assertEqual(statuses, ["SUCCESS"])

    def test_loop_routes_worker_and_advisor_to_assigned_roles(self):
        provider = FakeProvider(ProviderResult(completed=True, changed=True))
        loop = GoalLoop(self.store, provider, self._verifiers())
        loop.run_iteration(self.state.run_id)
        self.assertEqual(provider.assignments[0].identity, "opus")
        self.store.record_operational_incident(
            self.state.run_id, "failed_tool_invocation", {"error": "test"}
        )
        loop.advisor_cycle(self.state.run_id)
        self.assertEqual(provider.advisor_assignments[0].identity, "fable")

    def test_advisory_discovery_ranks_proposals_without_creating_jira(self):
        discovery = AdvisoryDiscovery()
        proposals = discovery.rank(
            "repository",
            [
                {"kind": "refactor", "title": "Remove duplicate parser", "risk": "low", "impact": 2},
                {"kind": "bug", "title": "Retry loses state", "risk": "high", "impact": 5},
            ],
        )
        self.assertIsInstance(proposals[0], AdvisoryProposal)
        self.assertEqual(proposals[0].kind, "bug")
        self.assertIsNone(proposals[0].jira_key)
        self.assertEqual(proposals[0].confidence, "medium")
        self.assertEqual(proposals[0].alternatives, [])
        self.assertEqual(proposals[0].jira_priority, "High")
        self.assertEqual(proposals[0].workflow, "/bug")

    def test_advisory_discovery_treats_scalar_evidence_as_one_item(self):
        proposal = AdvisoryDiscovery().rank(
            "repository",
            [{
                "kind": "bug", "title": "Bad retry", "evidence": "src/retry.ts",
                "acceptance_criteria": "retry preserves state",
                "alternatives": "document the limitation",
            }],
        )[0]
        self.assertEqual(proposal.evidence, ["src/retry.ts"])
        self.assertEqual(proposal.acceptance_criteria, ["retry preserves state"])
        self.assertEqual(proposal.alternatives, ["document the limitation"])

    def test_advisory_cli_emits_ranked_proposals_without_jira_side_effects(self):
        findings_path = self.root / "findings.json"
        findings_path.write_text(
            json.dumps([{"kind": "feature", "title": "Add export", "impact_score": 3}]),
            encoding="utf-8",
        )
        self.assertEqual(
            cli_main([
                "--state-dir", str(self.root / "runs"), "advise",
                "--scope", "repository", "--findings", str(findings_path),
            ]),
            0,
        )

    def test_advisory_proposals_and_approval_survive_resume_idempotently(self):
        proposal = AdvisoryProposal(
            kind="bug", title="Retry loses state", evidence=["scripts/loop.py"],
            impact="run can lose progress", scope="repair retry journal",
            acceptance_criteria=["recovery is durable"], confidence="high",
            alternatives=["document manual recovery"],
        )
        recorded = self.store.record_advisory_proposals(
            self.state.run_id, [proposal]
        )
        self.assertEqual(len(recorded), 1)
        proposal_id = recorded[0]["proposal_id"]
        resumed = self.store.load(self.state.run_id)
        self.assertEqual(resumed.advisory_proposals[0]["proposal_id"], proposal_id)
        self.assertEqual(resumed.advisory_proposals[0]["confidence"], "high")

        approval = self.store.approve_advisory_proposal(
            self.state.run_id, proposal_id
        )
        duplicate = self.store.approve_advisory_proposal(
            self.state.run_id, proposal_id
        )
        self.assertEqual(approval, duplicate)
        final = self.store.load(self.state.run_id)
        self.assertEqual(len(final.approved_advisory_proposals), 1)
        self.assertEqual(final.approved_advisory_proposals[0]["proposal_id"], proposal_id)
        self.assertEqual(
            len([
                event for event in self.store.events(self.state.run_id)
                if event.get("type") == "advisory.proposal.approved"
            ]),
            1,
        )

    def test_jira_advisory_handoff_is_delegated_and_idempotent_by_action(self):
        calls = []

        def steward(request):
            calls.append(request)
            return {"key": "DEV-99", "status": "created"}

        adapter = JiraStewardAdapter(steward)
        proposal = AdvisoryProposal(
            kind="bug", title="Retry loses state", evidence=["scripts/loop.py"],
            impact="run can lose progress", scope="repair retry journal", acceptance_criteria=["recovery is durable"],
            workflow="/bug",
        )
        recorded = self.store.record_advisory_proposals(self.state.run_id, [proposal])
        approval = self.store.approve_advisory_proposal(
            self.state.run_id, recorded[0]["proposal_id"]
        )
        persisted = self.store.load(self.state.run_id)
        result = adapter.create_from_proposal(
            persisted, proposal, approval["approval_action_id"]
        )
        self.store.update(persisted)
        # A fresh adapter instance must use the persisted GoalState record,
        # not a process-local cache, to deduplicate after a restart.
        duplicate = JiraStewardAdapter(steward).create_from_proposal(
            self.store.load(self.state.run_id), proposal, approval["approval_action_id"]
        )
        self.assertEqual(result["key"], "DEV-99")
        self.assertEqual(duplicate, result)
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["operation"], "create-work-item")
        self.assertEqual(calls[0]["action_id"], approval["approval_action_id"])
        self.assertEqual(calls[0]["idempotency_key"], approval["approval_action_id"])
        self.assertIn("goal-run:", calls[0]["marker"])
        self.assertEqual(calls[0]["issue_type"], "Bug")
        self.assertEqual(calls[0]["priority"], "Medium")
        self.assertEqual(calls[0]["description"]["confidence"], "medium")
        self.assertEqual(calls[0]["description"]["workflow"], "/bug")
        self.assertIn("alternatives", calls[0]["description"])

    def test_jira_advisory_handoff_refuses_ticket_without_acceptance_criteria(self):
        adapter = JiraStewardAdapter(lambda request: request)
        proposal = AdvisoryProposal(
            kind="feature", title="Incomplete proposal", evidence=["README.md"],
            impact="users need this", scope="small", acceptance_criteria=[],
        )
        with self.assertRaises(GoalLoopError):
            adapter.create_from_proposal(self.state, proposal, "act_incomplete")

    def test_jira_advisory_handoff_refuses_unapproved_proposal(self):
        adapter = JiraStewardAdapter(lambda request: request)
        proposal = AdvisoryProposal(
            kind="bug", title="Unapproved", evidence=["scripts/loop.py"],
            impact="impact", scope="scope", acceptance_criteria=["it is fixed"],
        )
        with self.assertRaises(GoalLoopError):
            adapter.create_from_proposal(self.state, proposal, "act_unapproved")

    def test_unknown_verifier_key_fails_closed(self):
        with self.assertRaises(VerificationError):
            VerificationRunner({}).run(["not-registered"], "sha-1", self.root)

    def test_unavailable_required_evidence_is_not_healthy(self):
        runner = VerificationRunner(
            {"test": lambda context: {"status": "UNAVAILABLE", "error": "tool missing"}}
        )
        evidence = runner.run(["test"], "sha-1", self.root)
        advisor = Advisor().assess(
            self.state,
            ProviderResult(),
            evidence,
            {"status": "KEEP_GOING"},
        )
        self.assertEqual(advisor.classification, AdvisorClass.FAILED)

    def test_progress_detector_error_requires_human_action(self):
        loop = GoalLoop(
            self.store,
            FakeProvider(),
            self._verifiers(),
            progress_detector=lambda state, evidence: {
                "status": "ERROR",
                "reason": "detector unavailable",
            },
            jira=FakeJira(),
        )
        loop.run_iteration(self.state.run_id)
        state = self.store.load(self.state.run_id)
        self.assertEqual(state.status, RunStatus.HUMAN_ACTION_REQUIRED)
        self.assertIn("progress detector", state.pending_human_action.lower())

    def test_cumulative_limits_survive_resume(self):
        provider = FakeProvider(ProviderResult(wall_clock_seconds=40, cost_usd=0.75))
        loop = GoalLoop(self.store, provider, self._verifiers(), jira=FakeJira())
        loop.run_iteration(self.state.run_id)
        resumed = self.store.load(self.state.run_id)
        self.assertEqual(resumed.iteration_count, 1)
        self.assertEqual(resumed.wall_clock_seconds, 40)
        self.assertAlmostEqual(resumed.cost_usd, 0.75)
        loop.run_iteration(self.state.run_id)
        final = self.store.load(self.state.run_id)
        self.assertEqual(final.status, RunStatus.BLOCKED)
        self.assertIn("budget", final.stop_reason.lower())
        self.assertEqual(provider.calls, 1)

    def test_single_run_lease_blocks_concurrency(self):
        lease = self.store.acquire_lease(self.state.run_id, owner="worker-a", ttl=60)
        with self.assertRaises(LeaseError):
            self.store.acquire_lease(self.state.run_id, owner="worker-b", ttl=60)
        self.store.release_lease(self.state.run_id, lease)

    def test_lease_renewal_requires_owner_token(self):
        lease = self.store.acquire_lease(self.state.run_id, owner="worker-a", ttl=1)
        renewed = self.store.renew_lease(self.state.run_id, lease, ttl=60)
        self.assertGreater(renewed["expires_at"], lease["expires_at"])
        with self.assertRaises(LeaseError):
            self.store.renew_lease(
                self.state.run_id,
                {"owner": "worker-a", "token": "forged"},
                ttl=60,
            )
        self.store.release_lease(self.state.run_id, renewed)

    def test_expired_lease_cannot_be_renewed(self):
        lease = self.store.acquire_lease(self.state.run_id, owner="worker-a", ttl=0.01)
        time.sleep(0.03)
        with self.assertRaises(LeaseError):
            self.store.renew_lease(self.state.run_id, lease, ttl=60)
        self.store.release_lease(self.state.run_id, lease)

    def test_malformed_lease_evidence_fails_closed(self):
        lease = self.store.acquire_lease(self.state.run_id, owner="worker-a", ttl=60)
        lease_path = self.store._path(self.state.run_id, "lease.json")
        lease_path.write_text("[]", encoding="utf-8")
        with self.assertRaises(LeaseError):
            self.store.assert_lease_current(self.state.run_id, lease)
        with self.assertRaises(LeaseError):
            self.store.renew_lease(self.state.run_id, lease, ttl=60)
        with self.assertRaises(LeaseError):
            self.store.update(self.state, lease=lease)

    def test_lease_fenced_checkpoint_rejects_replaced_worker(self):
        lease = self.store.acquire_lease(self.state.run_id, owner="worker-a", ttl=0.01)
        time.sleep(0.03)
        replacement = self.store.acquire_lease(self.state.run_id, owner="worker-b", ttl=60)
        self.state.next_action = "stale overwrite"
        with self.assertRaises(LeaseError):
            self.store.update(self.state, lease=lease)
        self.assertNotEqual(self.store.load(self.state.run_id).next_action, "stale overwrite")
        self.store.release_lease(self.state.run_id, replacement)

    def test_expired_lease_takeover_fences_stale_generation(self):
        lease = self.store.acquire_lease(self.state.run_id, owner="worker-a", ttl=0.01)
        time.sleep(0.03)
        replacement = self.store.acquire_lease(self.state.run_id, owner="worker-b", ttl=60)
        self.assertEqual(replacement["generation"], lease["generation"] + 1)
        with self.assertRaises(LeaseError):
            self.store.assert_lease_current(self.state.run_id, lease)
        self.store.release_lease(self.state.run_id, replacement)

    def test_recovery_discovers_incomplete_runs(self):
        loop = GoalLoop(self.store, FakeProvider(), self._verifiers())
        discovered = loop.recover_incomplete()
        self.assertEqual([state.run_id for state in discovered], [self.state.run_id])
        self.assertEqual(self.store.load(self.state.run_id).status, RunStatus.RUNNING)

    def test_human_action_escalates_durably(self):
        provider = FakeProvider(
            ProviderResult(human_action_required="Approve production deployment")
        )
        loop = GoalLoop(self.store, provider, self._verifiers(), jira=FakeJira())
        loop.run_iteration(self.state.run_id)
        state = self.store.load(self.state.run_id)
        self.assertEqual(state.status, RunStatus.HUMAN_ACTION_REQUIRED)
        self.assertEqual(state.pending_human_action, "Approve production deployment")

    def test_capability_detection_never_claims_codex_mobile_unconditionally(self):
        detector = CapabilityDetector(
            executable_lookup=lambda name: name in {"claude", "codex"}
        )
        claude = detector.detect("claude", {"CLAUDE_REMOTE_CONTROL": "1"})
        codex = detector.detect("codex", {"CODEX_DESKTOP_REMOTE": "1"})
        self.assertTrue(claude["local_cli"])
        self.assertTrue(claude["remote_status"])
        self.assertTrue(codex["local_cli"])
        self.assertTrue(codex["remote_status"])
        self.assertFalse(codex["mobile"])

    def test_jira_and_beads_failures_fall_back_without_losing_run(self):
        loop = GoalLoop(
            self.store,
            FakeProvider(),
            self._verifiers(),
            jira=FakeJira(fail=True),
            beads=None,
        )
        loop.run_iteration(self.state.run_id)
        state = self.store.load(self.state.run_id)
        self.assertNotEqual(state.status, RunStatus.FAILED)
        events = self.store.events(self.state.run_id)
        self.assertTrue(any(event["type"] == "jira.fallback" for event in events))
        self.assertTrue(any(event["type"] == "beads.fallback" for event in events))

    def test_failed_jira_progress_is_visible_and_recoverable(self):
        loop = GoalLoop(
            self.store,
            FakeProvider(),
            self._verifiers(),
            jira=FakeJira(fail=True),
        )
        loop.run_iteration(self.state.run_id)
        pending = self.store.pending_actions(self.state.run_id)
        self.assertEqual(len(pending), 1)
        self.assertEqual(pending[0]["action_type"], "jira.progress")
        self.assertTrue(
            any(event["type"] == "self_improvement.incident" for event in self.store.events(self.state.run_id))
        )

        jira = FakeJira()
        recovered = GoalLoop(
            self.store,
            FakeProvider(),
            self._verifiers(),
            jira=jira,
        ).recover(self.state.run_id)
        self.assertEqual(recovered.status, RunStatus.RUNNING)
        self.assertEqual(self.store.pending_actions(self.state.run_id), [])
        self.assertEqual(len(jira.reconciled), 1)

    def test_role_router_exposes_abstract_roles_and_preserves_named_assignments(self):
        self.assertTrue(hasattr(runtime, "RoleRouter"))
        if not hasattr(runtime, "RoleRouter"):
            return
        policy = runtime.RoleRouter.policy()
        self.assertEqual(
            policy["planner_advisor_project_manager"]["identities"],
            ["gpt-6-astra", "fable"],
        )
        self.assertEqual(
            policy["implementation_review_worker"]["identities"],
            ["opus", "luna"],
        )
        self.assertEqual(
            policy["routine_operations"]["identities"], ["lightweight"]
        )
        router = runtime.RoleRouter()
        self.assertEqual(router.route("planning").role, "planner_advisor_project_manager")
        self.assertEqual(router.route("implementation").role, "implementation_review_worker")
        self.assertEqual(router.route("heartbeat").role, "routine_operations")
        self.assertEqual(router.named_role("jira-workflow-steward"), "routine_operations")
        self.assertEqual(router.named_role("reality-checker"), "implementation_review_worker")
        # RoleRouter._named_roles is only reachable through named_role() — this is the sole
        # coverage of the planner-advisor entry, so a rename that drops it fails here.
        self.assertEqual(router.named_role("gpt-6-astra"), "planner_advisor_project_manager")
        # planner_assignment() branches on provider. Pin BOTH branches so renaming the Codex
        # planner cannot silently swap the Claude one (or vice versa).
        self.assertEqual(router.planner_assignment("codex").identity, "gpt-6-astra")
        self.assertEqual(router.planner_assignment("claude").identity, "fable")
        # No back-compat alias: a stale "sol" entry could silently re-enter the policy surface.
        # named_role() has no production caller today, so this pins the policy map, not routing.
        with self.assertRaisesRegex(ValueError, "unknown named agent identity"):
            router.named_role("sol")
        self.assertTrue(hasattr(UnavailableProvider("codex"), "role_policy"))

    def test_goal_state_persists_provider_specific_advisor_worker_and_monitor_roles(self):
        codex_state = self.store.create(
            goal="codex goal", acceptance_criteria=[], verifier_ids=[], repo=self.root,
            worktree=self.root, branch="feature/GOAL-2-loop", head_sha="sha-1",
            provider="codex", run_id="codex-roles",
        )
        self.assertEqual((self.state.planner_identity, self.state.worker_identity, self.state.monitor_identity), ("fable", "opus", "haiku"))
        self.assertEqual((codex_state.planner_identity, codex_state.worker_identity, codex_state.monitor_identity), ("gpt-6-astra", "luna", "lightweight"))

    def test_provider_registry_selects_only_registered_adapter_and_safe_fallback(self):
        self.assertTrue(hasattr(runtime, "ProviderAdapterRegistry"))
        if not hasattr(runtime, "ProviderAdapterRegistry"):
            return
        claude = FakeProvider()
        registry = runtime.ProviderAdapterRegistry({"claude": claude})
        self.assertIs(registry.select("claude"), claude)
        fallback = registry.select("codex")
        self.assertIsInstance(fallback, UnavailableProvider)
        self.assertEqual(fallback.provider, "codex")
        self.assertEqual(fallback.role_policy()["implementation_review_worker"]["identities"], ["opus", "luna"])

    def test_command_adapter_is_selected_from_json_argv_environment(self):
        self.assertTrue(hasattr(runtime, "CommandProviderAdapter"))
        if not hasattr(runtime, "CommandProviderAdapter"):
            return
        registry = runtime.ProviderAdapterRegistry.from_environment(
            {
                "GOAL_LOOP_CLAUDE_COMMAND": '["claude-wrapper", "--goal-loop"]',
            },
            executable_lookup=lambda name: "/usr/local/bin/" + name,
        )
        adapter = registry.select("claude")
        self.assertIsInstance(adapter, runtime.CommandProviderAdapter)
        self.assertEqual(adapter.argv, ["claude-wrapper", "--goal-loop"])
        self.assertIsInstance(registry.select("codex"), UnavailableProvider)

    def test_command_adapter_rejects_non_json_or_empty_command(self):
        with self.assertRaises(ValueError):
            runtime.ProviderAdapterRegistry.from_environment(
                {"GOAL_LOOP_CLAUDE_COMMAND": "claude --goal-loop"},
                executable_lookup=lambda name: "/usr/local/bin/" + name,
            )

    def test_command_adapter_requires_explicit_boolean_for_safe_fallback(self):
        adapter = runtime.CommandProviderAdapter(
            "claude", ["claude-wrapper"], executable_lookup=lambda name: "/usr/local/bin/" + name
        )
        with patch(
            "goal_loop_runtime.subprocess.run",
            return_value=SimpleNamespace(
                returncode=0,
                stdout=json.dumps(
                    {
                        "failure_kind": "usage_limited",
                        "outcome_known": "true",
                    }
                ),
                stderr="",
            ),
        ):
            result = adapter.start_iteration(self.state, runtime.RoleRouter().provider_assignment("claude"))

        self.assertFalse(result.outcome_known)
        self.assertFalse(GoalLoop._fallback_allowed(result))

    def test_provider_fallback_switches_roles_and_preserves_journal(self):
        claude = FakeProvider(ProviderResult(
            error="Claude weekly limit reached",
            human_action_required="Claude usage is exhausted",
            failure_kind="usage_limited",
            outcome_known=True,
        ))
        codex = FakeProvider(ProviderResult(changed=True))
        registry = runtime.ProviderAdapterRegistry({"claude": claude, "codex": codex})
        loop = GoalLoop(
            self.store,
            claude,
            self._verifiers(),
            provider_registry=registry,
            progress_detector=lambda state, evidence: {"status": "KEEP_GOING"},
        )

        state = loop.run_iteration(self.state.run_id)

        self.assertEqual(state.provider, "codex")
        self.assertEqual((state.planner_identity, state.worker_identity, state.monitor_identity), ("gpt-6-astra", "luna", "lightweight"))
        self.assertEqual(claude.calls, 1)
        self.assertEqual(codex.calls, 1)
        self.assertEqual(state.status, RunStatus.RUNNING)
        self.assertEqual(state.extra_fields["provider_history"][0]["to"], "codex")
        events = self.store.events(self.state.run_id)
        self.assertTrue(any(event.get("type") == "provider.fallback" for event in events))
        results = [event for event in events if event.get("type") == "action.result"]
        self.assertEqual([event["status"] for event in results], ["FAILED", "SUCCEEDED"])
        intents = [event for event in events if event.get("type") == "action.intent"]
        self.assertEqual(len(intents), 2)
        self.assertEqual(
            {event["action_id"] for event in intents},
            {event["action_id"] for event in results},
        )
        self.assertEqual(state.run_id, self.state.run_id)
        self.assertEqual(self.store.pending_actions(self.state.run_id), [])

    def test_watch_runs_iteration_after_advisor_recovers_resumable_run(self):
        self.store.record_operational_incident(
            self.state.run_id,
            "failed_tool_invocation",
            {"action": "provider.iteration", "error": "temporary failure"},
        )
        self.store.transition(self.state.run_id, RunStatus.BLOCKED)
        advisor_calls = []
        iteration_calls = []
        call_order = []

        def recover(run_id):
            advisor_calls.append(run_id)
            call_order.append("advisor")
            state = self.store.load(run_id)
            state.pending_advisor_review = None
            state.pending_advisor_reviews = []
            state.status = RunStatus.RESUMABLE
            return self.store.update(state)

        def iterate(run_id):
            iteration_calls.append(run_id)
            call_order.append("iteration")
            state = self.store.load(run_id)
            state.status = RunStatus.RUNNING
            return self.store.update(state)

        with patch.object(GoalLoop, "advisor_cycle", side_effect=recover), patch.object(
            GoalLoop, "run_iteration", side_effect=iterate
        ):
            self.assertEqual(
                cli_main(
                    [
                        "--state-dir",
                        str(self.store.root),
                        "watch",
                        "--run-id",
                        self.state.run_id,
                        "--max-cycles",
                        "1",
                    ]
                ),
                0,
            )

        self.assertEqual(advisor_calls, [self.state.run_id])
        self.assertEqual(iteration_calls, [self.state.run_id])
        self.assertEqual(call_order, ["advisor", "iteration"])
        self.assertEqual(self.store.load(self.state.run_id).status, RunStatus.RUNNING)

    def test_unknown_provider_outcome_does_not_fallback_or_repeat_work(self):
        claude = FakeProvider(ProviderResult(
            error="wrapper disconnected after starting work",
            failure_kind="unknown",
            outcome_known=False,
            cost_usd=None,
        ))
        codex = FakeProvider(ProviderResult(changed=True))
        registry = runtime.ProviderAdapterRegistry({"claude": claude, "codex": codex})
        loop = GoalLoop(
            self.store,
            claude,
            self._verifiers(),
            provider_registry=registry,
            progress_detector=lambda state, evidence: {"status": "KEEP_GOING"},
        )

        state = loop.run_iteration(self.state.run_id)

        self.assertEqual(state.provider, "claude")
        self.assertEqual(codex.calls, 0)
        self.assertEqual(state.status, RunStatus.FAILED)
        self.assertEqual(len(self.store.pending_actions(self.state.run_id)), 1)
        results = [event for event in self.store.events(self.state.run_id) if event.get("type") == "action.result"]
        self.assertEqual(results[-1]["status"], "UNKNOWN")

    def test_both_unavailable_stop_after_safe_attempts(self):
        claude = FakeProvider(ProviderResult(
            error="Claude unavailable", human_action_required="authenticate Claude",
            failure_kind="provider_unavailable", outcome_known=True,
        ))
        codex = FakeProvider(ProviderResult(
            error="Codex unavailable", human_action_required="authenticate Codex",
            failure_kind="provider_unavailable", outcome_known=True,
        ))
        registry = runtime.ProviderAdapterRegistry({"claude": claude, "codex": codex})
        loop = GoalLoop(
            self.store,
            claude,
            self._verifiers(),
            provider_registry=registry,
            progress_detector=lambda state, evidence: {"status": "KEEP_GOING"},
        )

        state = loop.run_iteration(self.state.run_id)

        self.assertEqual(state.status, RunStatus.HUMAN_ACTION_REQUIRED)
        self.assertEqual(state.provider, "codex")
        self.assertEqual(self.store.pending_actions(self.state.run_id), [])
        results = [event for event in self.store.events(self.state.run_id) if event.get("type") == "action.result"]
        self.assertEqual([event["status"] for event in results], ["FAILED", "FAILED"])

    def test_merge_policy_is_exact_toolbox_only_and_current_head_bound(self):
        evidence = {
            "open": True,
            "mergeable": True,
            "ci_green": True,
            "review_decision": "APPROVED",
            "unresolved_threads": [],
            "current_head_sha": "sha-current",
            "checked_head_sha": "sha-current",
            "branch_protection": True,
            "marker_valid": True,
            "live_verified": True,
            "evidence_source": "github-live",
        }
        self.assertEqual(
            MergePolicy.evaluate("baselito/ai-engineering", evidence)["action"],
            "AUTO_MERGE",
        )
        self.assertEqual(
            MergePolicy.evaluate(
                "baselito/ai-engineering",
                dict(evidence, evidence_source="github-live+clean-worktree"),
            )["action"],
            "AUTO_MERGE",
        )
        for repo, changed in [
            ("baselito/customer-service", {}),
            ("baselito/ai-engineering-fork", {}),
            ("baselito/ai-engineering", {"checked_head_sha": "sha-old"}),
            ("baselito/ai-engineering", {"unresolved_threads": [{"resolved": False, "outdated": False}]}),
            ("baselito/ai-engineering", {"ci_green": False}),
            ("baselito/ai-engineering", {"marker_valid": False}),
        ]:
            result = MergePolicy.evaluate(repo, dict(evidence, **changed))
            self.assertFalse(result["allowed"], (repo, changed, result))
            if repo != "baselito/ai-engineering":
                self.assertEqual(result["action"], "REPORT_MERGE_READY")

    def test_merge_policy_rejects_conflicted_or_behind_live_state(self):
        evidence = {
            "open": True,
            # This boolean can be stale while GitHub is still reporting the
            # authoritative merge-state status. The live status must win.
            "mergeable": True,
            "ci_green": True,
            "review_decision": "APPROVED",
            "unresolved_threads": [],
            "current_head_sha": "sha-current",
            "checked_head_sha": "sha-current",
            "branch_protection": True,
            "marker_valid": True,
            "live_verified": True,
            "evidence_source": "github-live",
        }
        for status in ("DIRTY", "BEHIND", "BLOCKED", "UNKNOWN"):
            result = MergePolicy.evaluate(
                "baselito/ai-engineering",
                dict(evidence, merge_state_status=status),
            )
            self.assertFalse(result["allowed"], status)
            self.assertIn("merge_state_status", result["failed_gates"], status)

    def test_mutation_test_only_guard_sees_uncommitted_production_files(self):
        (self.root / "package.json").write_text(
            json.dumps({"devDependencies": {"@stryker-mutator/core": "latest"}}), encoding="utf-8"
        )
        (self.root / "src").mkdir()
        (self.root / "src" / "app.js").write_text("export const answer = 42;\n", encoding="utf-8")
        registry = MutationTestingRegistry(
            self.root, base_sha="HEAD", executable_lookup=lambda name: "/usr/bin/" + name,
        )
        result = registry.run({"current_sha": "HEAD", "worktree": str(self.root), "test_only": True})
        self.assertEqual(result["status"], "FAIL")
        self.assertIn("src/app.js", result["production_files"])

    def test_merge_gate_cli_creates_marker_only_for_toolbox_after_preflight(self):
        evidence = {
            "open": True,
            "mergeable": True,
            "ci_green": True,
            "review_decision": "APPROVED",
            "unresolved_threads": [],
            "current_head_sha": "sha-current",
            "checked_head_sha": "sha-current",
            "branch_protection": True,
            "marker_valid": False,
            "live_verified": True,
            "evidence_source": "github-live",
        }
        evidence_path = self.root / "merge-evidence.json"
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        marker_dir = self.root / "state"
        live = dict(evidence, evidence_source="github-live", marker_valid=True)
        with patch.object(MergePolicy, "collect_live_evidence", return_value=live):
            self.assertEqual(
                cli_main([
                    "--state-dir", str(self.root / "runs"), "merge-gate",
                    "--repo", "baselito/ai-engineering", "--pr", "123",
                    "--evidence", str(evidence_path), "--marker-dir", str(marker_dir),
                ]),
                0,
            )
        self.assertTrue((marker_dir / ".pr-merge-gate-baselito-ai-engineering-123").is_file())
        self.assertEqual(
            cli_main([
                "--state-dir", str(self.root / "runs"), "merge-gate",
                "--repo", "baselito/other", "--pr", "123",
                "--evidence", str(evidence_path), "--marker-dir", str(marker_dir),
            ]),
            1,
        )

    def test_avoidable_failure_creates_incident_and_next_advisor_cycle_acts(self):
        runner = VerificationRunner(
            {"test": lambda context: {"status": "FAIL", "error": "tool failed"}}
        )
        loop = GoalLoop(self.store, FakeProvider(), runner, jira=FakeJira())
        loop.run_iteration(self.state.run_id)
        state = self.store.load(self.state.run_id)
        self.assertIsNotNone(getattr(state, "pending_advisor_review", None))
        incidents = [
            event for event in self.store.events(self.state.run_id)
            if event["type"] == "self_improvement.incident"
        ]
        self.assertEqual(len(incidents), 1)

        review = loop.advisor_cycle(self.state.run_id)
        self.assertIsNotNone(review["recommendation"])
        self.assertIsNone(self.store.load(self.state.run_id).pending_advisor_review)
        self.assertEqual(self.store.load(self.state.run_id).pending_advisor_reviews, [])
        actions = [
            event for event in self.store.events(self.state.run_id)
            if event["type"] == "self_improvement.advisor_action"
        ]
        self.assertEqual(len(actions), 1)
        loop.advisor_cycle(self.state.run_id)
        self.assertEqual(
            len([
                event for event in self.store.events(self.state.run_id)
                if event["type"] == "self_improvement.advisor_action"
            ]),
            1,
        )

    def test_failed_verification_blocks_worker_until_advisor_cycle(self):
        provider = FakeProvider()
        runner = VerificationRunner(
            {"test": lambda context: {
                "status": "FAIL", "sha": context["current_sha"],
                "worktree": context["worktree"], "error": "broken",
            }}
        )
        loop = GoalLoop(self.store, provider, runner)
        loop.run_iteration(self.state.run_id)
        self.assertEqual(self.store.load(self.state.run_id).status, RunStatus.BLOCKED)
        self.assertEqual(provider.calls, 1)
        loop.run_iteration(self.state.run_id)
        self.assertEqual(provider.calls, 1)
        loop.advisor_cycle(self.state.run_id)
        self.assertEqual(self.store.load(self.state.run_id).status, RunStatus.RESUMABLE)

    def test_unknown_recovery_action_enters_human_action_required(self):
        # A result record without a known action type must still be recoverable
        # as a durable human gate rather than being silently dropped.
        self.store.append_event(
            self.state.run_id,
            {
                "type": "action.intent",
                "action_id": "act_unknown",
                "action_type": "unknown.external.write",
                "payload": {"target": "production"},
                "status": "INTENT",
            },
        )
        loop = GoalLoop(self.store, FakeProvider(), self._verifiers())
        state = loop.recover(self.state.run_id)
        self.assertEqual(state.status, RunStatus.HUMAN_ACTION_REQUIRED)
        self.assertIn("act_unknown", state.pending_human_action)

    def test_recovery_reconciles_completed_provider_before_checkpoint(self):
        self.store.append_event(
            self.state.run_id,
            {
                "type": "action.intent",
                "action_id": "act_provider_completed",
                "action_type": "provider.iteration",
                "payload": {"iteration": 1},
                "status": "INTENT",
            },
        )
        self.store.append_event(
            self.state.run_id,
            {
                "type": "action.result",
                "action_id": "act_provider_completed",
                "status": "SUCCEEDED",
                "result": {
                    "session_id": "session-recovered",
                    "changed": True,
                    "wall_clock_seconds": 1.5,
                    "cost_usd": 0.25,
                    "observed_head_sha": "sha-recovered",
                },
            },
        )
        provider = FakeProvider()
        loop = GoalLoop(self.store, provider, self._verifiers())
        recovered = loop.recover(self.state.run_id)
        self.assertEqual(recovered.status, RunStatus.RESUMABLE)
        self.assertEqual(recovered.provider_session_id, "session-recovered")
        self.assertEqual(recovered.head_sha, "sha-recovered")
        self.assertEqual(recovered.iteration_count, 1)
        self.assertEqual(provider.calls, 0)

    def test_pending_provider_recovery_never_reuses_previous_session(self):
        state = self.store.load(self.state.run_id)
        state.provider_session_id = "previous-session"
        self.store.update(state)
        self.store.append_event(
            self.state.run_id,
            {
                "type": "action.intent",
                "action_id": "act_provider_pending",
                "action_type": "provider.iteration",
                "payload": {"iteration": 2},
                "status": "INTENT",
            },
        )
        provider = FakeProvider()
        loop = GoalLoop(self.store, provider, self._verifiers())
        recovered = loop.recover(self.state.run_id)
        self.assertEqual(recovered.status, RunStatus.HUMAN_ACTION_REQUIRED)
        self.assertIn("act_provider_pending", recovered.pending_human_action)

    def test_jira_adapter_delegates_phase_comment_without_direct_api(self):
        calls = []

        def steward(request):
            calls.append(request)
            return {"action_id": request["action_id"], "status": "applied"}

        adapter = JiraStewardAdapter(steward)
        result = adapter.progress(self.state, "act_jira")
        self.assertEqual(result["status"], "applied")
        self.assertEqual(calls[0]["phase"], "in_progress")
        self.assertEqual(calls[0]["action_id"], "act_jira")
        self.assertIn("jira-workflow-steward", calls[0]["path"])

    def test_unavailable_provider_escalates_without_inventing_credentials(self):
        result = UnavailableProvider("codex").start_iteration(self.state)
        self.assertIn("provider", result.human_action_required.lower())
        self.assertIsNone(result.session_id)

    def test_provider_contract_exposes_explicit_session_resume(self):
        assignment = RoleAssignment(
            role="implementation_review_worker", identity="luna",
            model_tier="worker", task_kind="implementation",
        )
        self.assertTrue(hasattr(ProviderAdapter, "resume_session"))
        result = UnavailableProvider("codex").resume_session(
            self.state, assignment, "previous-session"
        )
        self.assertIn("provider", result.human_action_required.lower())

    def test_cli_supports_durable_start_status_pause_resume_cancel_and_advisor_status(self):
        state_dir = self.root / "runs"
        args = [
            "--state-dir", str(state_dir),
            "start",
            "--goal", "Ship the goal loop",
            "--acceptance", "the test gate passes",
            "--verifier", "test",
            "--repo", str(self.root),
            "--worktree", str(self.root),
            "--branch", "feature/GOAL-1-loop",
            "--head-sha", "sha-1",
            "--provider", "claude",
            "--test-only",
            "--run-id", "gr_cli",
        ]
        self.assertEqual(cli_main(args), 0)
        self.assertTrue(GoalStore(state_dir).load("gr_cli").limits["test_only"])
        self.assertEqual(cli_main(["--state-dir", str(state_dir), "status", "--run-id", "gr_cli"]), 0)
        self.assertEqual(
            cli_main(["--state-dir", str(state_dir), "advisor-status", "--run-id", "gr_cli"]),
            0,
        )
        self.assertEqual(cli_main(["--state-dir", str(state_dir), "pause", "--run-id", "gr_cli"]), 0)
        self.assertEqual(
            GoalStore(state_dir).load("gr_cli").status,
            RunStatus.PAUSED,
        )
        self.assertEqual(cli_main(["--state-dir", str(state_dir), "resume", "--run-id", "gr_cli"]), 0)
        self.assertEqual(
            GoalStore(state_dir).load("gr_cli").status,
            RunStatus.RESUMABLE,
        )
        self.assertEqual(cli_main(["--state-dir", str(state_dir), "cancel", "--run-id", "gr_cli"]), 0)
        self.assertEqual(
            GoalStore(state_dir).load("gr_cli").status,
            RunStatus.CANCELLED,
        )

    def test_iterate_resumes_a_resumable_run_before_running_one_cycle(self):
        state_dir = self.root / "resume-run"
        cli_main(
            [
                "--state-dir", str(state_dir), "start",
                "--goal", "resume me",
                "--repo", str(self.root),
                "--worktree", str(self.root),
                "--branch", "feature/GOAL-1-loop",
                "--head-sha", "sha-1",
                "--provider", "claude",
                "--run-id", "gr_resume",
            ]
        )
        cli_main(["--state-dir", str(state_dir), "pause", "--run-id", "gr_resume"])
        cli_main(["--state-dir", str(state_dir), "resume", "--run-id", "gr_resume"])
        cli_main(["--state-dir", str(state_dir), "iterate", "--run-id", "gr_resume"])
        state = GoalStore(state_dir).load("gr_resume")
        self.assertEqual(state.iteration_count, 1)
        self.assertEqual(state.status, RunStatus.HUMAN_ACTION_REQUIRED)

    def test_iterate_is_one_bounded_cycle_and_escalates_without_provider_session(self):
        state_dir = self.root / "runs-once"
        self.assertEqual(
            cli_main(
                [
                    "--state-dir", str(state_dir), "start",
                    "--goal", "one iteration",
                    "--verifier", "test",
                    "--repo", str(self.root),
                    "--worktree", str(self.root),
                    "--branch", "feature/GOAL-1-loop",
                    "--head-sha", "sha-1",
                    "--provider", "codex",
                    "--run-id", "gr_once",
                ]
            ),
            0,
        )
        self.assertEqual(
            cli_main(["--state-dir", str(state_dir), "iterate", "--run-id", "gr_once"]),
            0,
        )
        state = GoalStore(state_dir).load("gr_once")
        self.assertEqual(state.iteration_count, 1)
        self.assertEqual(state.status, RunStatus.HUMAN_ACTION_REQUIRED)

    def test_installed_goal_loop_wrapper_is_present_and_executable(self):
        wrapper = Path(__file__).with_name("goal-loop")
        self.assertTrue(wrapper.is_file())
        self.assertTrue(os.access(wrapper, os.X_OK))

    def test_presentation_skill_asset_and_menu_entries_are_packaged_together(self):
        repo_root = Path(__file__).parent.parent
        skill = repo_root / "skills" / "presentation-master"
        self.assertTrue((skill / "SKILL.md").is_file())
        self.assertIn("PPTX_TEMPLATE", (skill / "SKILL.md").read_text())
        self.assertTrue((skill / "assets" / "template.pptx").is_file())
        self.assertTrue((repo_root / "commands" / "presentation.md").is_file())
        menu = (repo_root / "commands" / "commands.md").read_text(encoding="utf-8")
        skill_list = (repo_root / "docs" / "reference" / "skill-list.md").read_text(encoding="utf-8")
        self.assertIn("/presentation", menu)
        self.assertIn("presentation-master", skill_list)

    def test_cli_exposes_detected_provider_capabilities(self):
        self.assertEqual(
            cli_main(["capabilities", "--provider", "codex"]),
            0,
        )

    def _verifiers(self):
        return VerificationRunner(
            {
                "test": lambda context: {
                    "status": "PASS",
                    "sha": context["current_sha"],
                    "worktree": context["worktree"],
                }
            }
        )


if __name__ == "__main__":
    unittest.main()
