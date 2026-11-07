#!/usr/bin/env python3
# test-jira-comment-ordering.py
#
# Behavioural tests for scripts/check-jira-comment-ordering.py — the audit
# tool that warns about phase-emoji / content / column mismatches in a Jira
# ticket's comments.
#
# Strategy: feed crafted CommentRecord lists directly into the check_*
# functions and assert the warning count + content. Avoids spinning up acli;
# the live integration is exercised separately if needed.
#
# Tests cover:
#   T1  — emoji tense mismatch: 🚀 starting + "Implementation complete" body
#   T2  — emoji tense mismatch: ✅ completion + "starting" body
#   T3  — recurring emoji (🔍) is NOT flagged for tense mismatch
#   T4  — phase order: 🔗 PR Created BEFORE 🚀 Implementation flagged
#   T5  — phase order: standard order (🔍 → 🚀 → ✅ → 🔗) NOT flagged
#   T6  — column match: "🔍 Discovery — ..." on board WITHOUT Discovery flagged
#   T7  — column match: Fix A's adapted form ("(board has no X column)") NOT flagged
#   T8  — column match: jira_columns=None disables the check (no false positives)
#   T9  — emoji detection: leading whitespace tolerated; mid-line emojis ignored
#   T10 — fixture loading: parse_comment_records handles both list and {comments:[…]} shapes

from __future__ import annotations

import sys
from pathlib import Path

# Ensure the script under test is importable. test files live in scripts/
# alongside the script under test.
SCRIPTS_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS_DIR))

# Imported via importlib because the script's filename has hyphens.
import importlib.util

_SPEC = importlib.util.spec_from_file_location(
    "check_jira_comment_ordering",
    SCRIPTS_DIR / "check-jira-comment-ordering.py",
)
assert _SPEC is not None and _SPEC.loader is not None, "could not load script under test"
audit = importlib.util.module_from_spec(_SPEC)
# Register in sys.modules BEFORE exec_module — Python 3.9's dataclass
# decorator calls sys.modules.get(cls.__module__) during class creation;
# without this, the lookup returns None and blows up.
sys.modules["check_jira_comment_ordering"] = audit
_SPEC.loader.exec_module(audit)

# Aliases for readability
CommentRecord = audit.CommentRecord
detect_emoji = audit.detect_emoji
parse_comment_records = audit.parse_comment_records
check_emoji_tense_mismatch = audit.check_emoji_tense_mismatch
check_phase_order = audit.check_phase_order
check_column_match = audit.check_column_match


# ---------------------------------------------------------------------------
# Test bookkeeping
# ---------------------------------------------------------------------------
_GREEN = "\033[0;32m" if sys.stdout.isatty() else ""
_RED = "\033[0;31m" if sys.stdout.isatty() else ""
_NC = "\033[0m" if sys.stdout.isatty() else ""

PASS_COUNT = 0
FAIL_COUNT = 0
FAILURES: list[str] = []


def _passed(name: str) -> None:
    global PASS_COUNT
    PASS_COUNT += 1
    print(f"  {_GREEN}PASS{_NC}: {name}")


def _failed(name: str, why: str) -> None:
    global FAIL_COUNT
    FAIL_COUNT += 1
    FAILURES.append(f"{name}: {why}")
    print(f"  {_RED}FAIL{_NC}: {name} — {why}")


def _record(body: str, *, created: str = "2026-05-05T10:00:00Z") -> CommentRecord:
    """Helper to build a CommentRecord with auto-detected emoji."""
    return CommentRecord(body=body, created=created, emoji=detect_emoji(body))


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
print("\n=== test-jira-comment-ordering.py ===\n")

# T1 — 🚀 starting emoji on completion-language body must be flagged.
_recs = [
    _record("🚀 In Progress — Implementation started\n\nFiles changed: x.py\nTests: 7 passing — implementation complete."),
]
_warnings = check_emoji_tense_mismatch(_recs)
if len(_warnings) == 1 and "🚀" in _warnings[0] and "completion" in _warnings[0].lower():
    _passed("T1: 🚀 starting emoji on completion-language body is flagged")
else:
    _failed(
        "T1: 🚀 starting emoji on completion-language body is flagged",
        f"got {_warnings}",
    )

# T2 — ✅ completion emoji on starting-language body must be flagged.
_recs = [
    _record("✅ Status Update\n\nStarting investigation of test coverage gaps."),
]
_warnings = check_emoji_tense_mismatch(_recs)
if len(_warnings) == 1 and "✅" in _warnings[0]:
    _passed("T2: ✅ completion emoji on starting-language body is flagged")
else:
    _failed(
        "T2: ✅ completion emoji on starting-language body is flagged",
        f"got {_warnings}",
    )

# T3 — recurring emoji (🔍 used for both Discovery and Code Review) gets the
# "either" frame and is NOT flagged regardless of tense.
_recs = [
    _record("🔍 Discovery — Investigation complete with all findings recorded"),
    _record("🔍 Code Review Started — beginning review now"),
]
_warnings = check_emoji_tense_mismatch(_recs)
if not _warnings:
    _passed("T3: recurring 🔍 emoji is NOT flagged for tense mismatch (frame=either)")
else:
    _failed(
        "T3: recurring 🔍 emoji is NOT flagged for tense mismatch (frame=either)",
        f"got {_warnings}",
    )

# T4 — phase order: 🔗 PR Created BEFORE 🚀 Implementation must be flagged.
_recs = [
    _record("🔗 PR Created\nLink: https://github.com/x/y/pull/1", created="2026-05-05T10:00:00Z"),
    _record("🚀 In Progress — Implementation started\nBranch: feature/x", created="2026-05-05T10:01:00Z"),
]
_warnings = check_phase_order(_recs)
if len(_warnings) == 1 and "🚀" in _warnings[0]:
    _passed("T4: 🔗 PR Created posted BEFORE 🚀 Implementation is flagged")
else:
    _failed(
        "T4: 🔗 PR Created posted BEFORE 🚀 Implementation is flagged",
        f"got {_warnings}",
    )

# T5 — standard correct order (🔍 → 🚀 → ✅ → 🔗) is NOT flagged.
_recs = [
    _record("🔍 Discovery — Agent investigation\nScope: x.py", created="2026-05-05T10:00:00Z"),
    _record("🚀 In Progress — Implementation started\nBranch: feature/x", created="2026-05-05T10:05:00Z"),
    _record("✅ Verification Complete\nTests: 7 passing", created="2026-05-05T10:10:00Z"),
    _record("🔗 PR Created\nLink: https://github.com/x/y/pull/1", created="2026-05-05T10:15:00Z"),
]
_warnings = check_phase_order(_recs)
if not _warnings:
    _passed("T5: standard phase order (🔍→🚀→✅→🔗) is NOT flagged")
else:
    _failed(
        "T5: standard phase order (🔍→🚀→✅→🔗) is NOT flagged",
        f"got {_warnings}",
    )

# T6 — column-in-header not in jira_columns must be flagged.
_recs = [
    _record("🔍 Discovery — Agent investigation\n\nScope: x.py"),
]
_warnings = check_column_match(_recs, jira_columns=["Backlog", "In Progress", "Done"])
if len(_warnings) == 1 and "Discovery" in _warnings[0]:
    _passed("T6: header column not in jira_columns is flagged")
else:
    _failed(
        "T6: header column not in jira_columns is flagged",
        f"got {_warnings}",
    )

# T7 — Fix A's adapted form (with parenthetical explanation) is NOT flagged.
_recs = [
    _record("🔍 Backlog — Discovery investigation (board has no Discovery column)\n\nScope: x.py"),
]
_warnings = check_column_match(_recs, jira_columns=["Backlog", "In Progress", "Done"])
if not _warnings:
    _passed("T7: Fix A's adapted form is NOT flagged (parenthetical detected)")
else:
    _failed(
        "T7: Fix A's adapted form is NOT flagged (parenthetical detected)",
        f"got {_warnings}",
    )

# T8 — jira_columns=None disables the check — never reports false positives
# when project context isn't available.
_recs = [
    _record("🔍 Discovery — Agent investigation"),
    _record("🚀 In Progress — Implementation started"),
]
_warnings = check_column_match(_recs, jira_columns=None)
if not _warnings:
    _passed("T8: jira_columns=None silently skips the column-match check")
else:
    _failed(
        "T8: jira_columns=None silently skips the column-match check",
        f"got {_warnings}",
    )

# T9 — leading whitespace tolerated; emoji mid-line ignored. detect_emoji
# only looks at the first line and only at the leading position.
if (
    detect_emoji("  🔍 Leading whitespace OK") == "🔍"
    and detect_emoji("Some prose here, then 🚀 mid-line — ignored") is None
    and detect_emoji("") is None
):
    _passed("T9: detect_emoji handles whitespace + ignores mid-line emojis")
else:
    _failed("T9: detect_emoji handles whitespace + ignores mid-line emojis", "regression")

# T10 — fixture loading handles both shapes.
_payload_list = [
    {"body": "🔍 Discovery — start", "created": "2026-05-05T10:00:00Z"},
    {"body": "🚀 In Progress — start", "created": "2026-05-05T10:05:00Z"},
]
_payload_dict = {"comments": _payload_list}
_recs_list = parse_comment_records(_payload_list)
_recs_dict = parse_comment_records(_payload_dict)
if (
    len(_recs_list) == 2
    and len(_recs_dict) == 2
    and _recs_list[0].emoji == "🔍"
    and _recs_dict[1].emoji == "🚀"
):
    _passed("T10: parse_comment_records accepts both list and {comments:[…]} payloads")
else:
    _failed(
        "T10: parse_comment_records accepts both list and {comments:[…]} payloads",
        f"list={_recs_list}, dict={_recs_dict}",
    )

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
total = PASS_COUNT + FAIL_COUNT
print()
print("======================================")
print(f"comment-ordering tests: {PASS_COUNT}/{total} passed")
print("======================================")
if FAIL_COUNT:
    print()
    print("Failures:")
    for f in FAILURES:
        print(f"  - {f}")
    sys.exit(1)
sys.exit(0)
