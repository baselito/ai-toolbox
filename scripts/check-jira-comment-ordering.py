#!/usr/bin/env python3
# check-jira-comment-ordering.py
#
# Audit a Jira ticket's comments for phase-emoji vs comment-content mismatches.
# Emits warnings to stderr; never blocks. Designed to surface the friction
# patterns observed during TASK-738 work:
#
#   1. A starting-emoji (🔍/📖/💡/📋/🚀) on a body describing FINISHED work
#      — typical of streamlined-path runs that didn't switch to past-tense
#      templates (Fix B).
#   2. A phase comment (🔍 Discovery, 📋 Planning, etc) landing in a column
#      whose name doesn't match the phase — typical of boards missing the
#      canonical column for that phase (Fix A).
#   3. Phase comments out of expected order (e.g. 🔗 PR Created posted
#      BEFORE 🚀 In Progress) — usually a workflow ordering bug.
#
# Usage:
#   python3 scripts/check-jira-comment-ordering.py <TICKET-KEY>
#
# Exit code is always 0 — this is an audit tool, not a gate. Findings go to
# stderr so they appear in CI logs and orchestrator context without breaking
# any pipeline that consumes the script's stdout.
#
# Tests: scripts/test-jira-comment-ordering.py — runs the same logic against
# fixture data instead of live acli, so the audit can be exercised offline.

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Any

# Phase emojis and their expected temporal frame.
#   - "starting"  → comment body should describe work ABOUT to begin
#   - "completed" → comment body should describe work that JUST FINISHED
#   - "either"    → emoji is reused across starting and completion contexts
#                   (🔍 Discovery + 🔍 Code Review, 💡 Brainstorming) — no
#                   tense check is performed for these.
EMOJI_FRAME: dict[str, str] = {
    "🔍": "either",
    "📖": "starting",
    "💡": "either",
    "📋": "starting",
    "🚀": "starting",
    "✅": "completed",
    "🔗": "completed",
}

# Lowercase phrases that signal the comment body describes COMPLETED work.
# Tuned to the templates documented in commands/flow.md — keep this short
# and high-precision rather than try to NLP-classify arbitrary text.
COMPLETED_PHRASES = re.compile(
    r"\b("
    r"complete(?:d)?"
    r"|finished"
    r"|done"
    r"|merged"
    r"|tests?\s+pass(?:ed|ing)?"
    r"|implementation\s+complete"
    r"|grade\s+[a-f]\b"
    r"|investigation\s+complete"
    r"|approach\s+chosen"
    r"|plan\s+finalised"
    r"|ready\s+for\s+pr"
    r")\b",
    re.IGNORECASE,
)

# Lowercase phrases that signal the comment body describes STARTING work.
STARTING_PHRASES = re.compile(
    r"\b("
    r"starting"
    r"|investigating"
    r"|begin(?:ning)?"
    r"|will\s+(?:add|create|implement|build)"
    r"|tdd\s+plan"
    r"|about\s+to"
    r"|tests?\s+first"
    r"|what'?s?\s+being\s+built"
    r")\b",
    re.IGNORECASE,
)

# Expected phase order for a full /flow run. Used by the ordering check.
# Entries are (emoji, phase-label) — the same emoji can appear twice (Discovery
# at index 0 AND Code Review at index 5) so we walk by emoji + sequence rather
# than emoji alone.
EXPECTED_ORDER: list[tuple[str, str]] = [
    ("🔍", "Discovery"),
    ("📖", "Assessment"),
    ("💡", "Brainstorming"),
    ("📋", "Planning"),
    ("🚀", "Implementation"),
    ("🔍", "Code Review"),
    ("✅", "Verification"),
    ("🔗", "PR Created"),
]


@dataclass
class CommentRecord:
    """One Jira comment, narrowed to the fields the audit cares about."""

    body: str
    created: str  # ISO timestamp string from acli; sortable lexicographically
    emoji: str | None  # First phase-emoji on the first line of body, or None


# Compiled at import time so we don't rebuild the alternation per call.
_LEADING_EMOJI = re.compile(
    r"^\s*(" + "|".join(re.escape(e) for e in EMOJI_FRAME.keys()) + r")"
)


def detect_emoji(body: str) -> str | None:
    """Return the leading phase-emoji from the comment body, or None.

    Many tools wrap comments in markdown / quote prefixes — we only consider
    the FIRST line so we don't pick up an emoji that appears mid-quote.
    """
    if not body:
        return None
    first_line = body.split("\n", 1)[0]
    m = _LEADING_EMOJI.match(first_line)
    return m.group(1) if m else None


def fetch_comments_via_acli(ticket: str) -> list[CommentRecord]:
    """Query acli for the ticket's comments. Returns chronologically sorted records.

    Errors out clearly if acli isn't installed or the ticket doesn't exist —
    callers can fall back to fixture data via parse_comment_records() in tests.
    """
    cmd = ["acli", "jira", "workitem", "comment", "list", "--key", ticket, "--json"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(
            f"acli failed for {ticket}: {proc.stderr.strip() or proc.stdout.strip()}"
        )
    return parse_comment_records(json.loads(proc.stdout))


def parse_comment_records(payload: Any) -> list[CommentRecord]:
    """Build CommentRecord list from acli JSON. Tolerates two shapes:
    - top-level list of comments
    - {"comments": [...]} wrapper
    """
    raw: list[dict[str, Any]]
    if isinstance(payload, list):
        raw = payload
    elif isinstance(payload, dict) and isinstance(payload.get("comments"), list):
        raw = payload["comments"]
    else:
        raise ValueError(
            "Unexpected comment payload shape — expected list or {'comments': [...]}"
        )
    records = [
        CommentRecord(
            body=c.get("body", "") or "",
            created=c.get("created", "") or "",
            emoji=detect_emoji(c.get("body", "") or ""),
        )
        for c in raw
    ]
    # Sort by `created` so audit warnings reflect actual ticket chronology
    # even if acli returns the list in reverse order.
    records.sort(key=lambda r: r.created)
    return records


# ---------------------------------------------------------------------------
# Audit checks — each returns a list of human-readable warning strings.
# Empty list = nothing to flag for that check.
# ---------------------------------------------------------------------------


def check_emoji_tense_mismatch(records: list[CommentRecord]) -> list[str]:
    """Flag bodies whose tense disagrees with the leading emoji."""
    warnings: list[str] = []
    for idx, rec in enumerate(records, start=1):
        if rec.emoji is None:
            continue
        frame = EMOJI_FRAME.get(rec.emoji, "either")
        if frame == "either":
            continue
        body_completed = bool(COMPLETED_PHRASES.search(rec.body))
        body_starting = bool(STARTING_PHRASES.search(rec.body))
        if frame == "starting" and body_completed and not body_starting:
            warnings.append(
                f"Comment #{idx} ({rec.created}): leading emoji {rec.emoji} indicates "
                f"work-starting, but body uses completion language. "
                f"Consider switching to the streamlined `✅ ...` template — see "
                f"commands/flow.md → 'Streamlined Path Comment Templates'."
            )
        elif frame == "completed" and body_starting and not body_completed:
            warnings.append(
                f"Comment #{idx} ({rec.created}): leading emoji {rec.emoji} indicates "
                f"completion, but body uses work-starting language. "
                f"Either the body or the emoji is wrong — review the comment."
            )
    return warnings


def check_phase_order(records: list[CommentRecord]) -> list[str]:
    """Flag emoji sequences that are out of the documented phase order.

    We tolerate missing phases (not every workflow has all 8) but flag clear
    out-of-sequence cases like 🔗 PR Created posted before 🚀 In Progress.
    """
    warnings: list[str] = []

    # Map each emoji to the EARLIEST index in EXPECTED_ORDER it can appear at.
    # We use earliest-index because some emojis recur (🔍, ✅): the first
    # occurrence anchors the position.
    earliest_idx: dict[str, int] = {}
    for i, (emoji, _label) in enumerate(EXPECTED_ORDER):
        earliest_idx.setdefault(emoji, i)

    last_seen_idx = -1
    for n, rec in enumerate(records, start=1):
        if rec.emoji is None:
            continue
        if rec.emoji not in earliest_idx:
            continue
        idx = earliest_idx[rec.emoji]
        # Reused emojis (🔍, ✅) can legitimately come AFTER their earliest
        # position too — only flag when an emoji appears strictly EARLIER
        # than a previously-seen one whose earliest_idx is higher.
        if idx < last_seen_idx and rec.emoji not in {"🔍", "✅", "💡"}:
            warnings.append(
                f"Comment #{n} ({rec.created}): {rec.emoji} appears AFTER a "
                f"later-phase comment. Workflow phases may be out of order — "
                f"check the run was completed in sequence."
            )
        last_seen_idx = max(last_seen_idx, idx)
    return warnings


def check_column_match(
    records: list[CommentRecord], jira_columns: list[str] | None
) -> list[str]:
    """Flag phase comments that mention a column NOT present in jira_columns.

    Heuristic only — we read the comment header for a column-like first word
    after the emoji and check membership. If `jira_columns` is None the check
    is skipped (no project context available).
    """
    if not jira_columns:
        return []
    canonical_lower = {c.lower() for c in jira_columns}
    # Header pattern: "<emoji> <column> — <verb> ..."
    header_pat = re.compile(r"^\s*[^\s]+\s+([A-Za-z][A-Za-z ]*?)\s+—")
    warnings: list[str] = []
    for n, rec in enumerate(records, start=1):
        if rec.emoji is None:
            continue
        first_line = rec.body.split("\n", 1)[0]
        m = header_pat.match(first_line)
        if not m:
            continue
        column_in_header = m.group(1).strip()
        if column_in_header.lower() in canonical_lower:
            continue
        # Column in header is not in jira_columns AND no parenthetical
        # explanation already calls this out. The Fix A adapted form contains
        # "(board has no <X> column)" — skip warnings when that pattern is
        # already present, because the comment is already documenting the gap.
        if re.search(r"\(board has no [^)]+ column\)", first_line):
            continue
        warnings.append(
            f"Comment #{n} ({rec.created}): header mentions column "
            f"'{column_in_header}' which is not in PROJECT.md `jira_columns`. "
            f"Either rewrite per Fix A's adapted form, or check that "
            f"jira_columns is up to date."
        )
    return warnings


# ---------------------------------------------------------------------------
# CLI entrypoint
# ---------------------------------------------------------------------------


def main() -> int:
    """Parse arguments, fetch comments, run all checks, print warnings."""
    parser = argparse.ArgumentParser(
        description=(
            "Audit a Jira ticket's comments for phase-emoji / content / column "
            "mismatches. Warnings only — never blocks."
        )
    )
    parser.add_argument("ticket", help="Jira ticket key (e.g. DEV-1234)")
    parser.add_argument(
        "--jira-columns",
        help=(
            "Comma-separated list of board columns. If omitted, the column-match "
            "check is skipped. Pass jira_columns from .claude/PROJECT.md."
        ),
        default=None,
    )
    parser.add_argument(
        "--fixture",
        help=(
            "Path to a JSON fixture file (the same shape acli emits). When set, "
            "skips the live acli call. Used by the test harness."
        ),
        default=None,
    )
    args = parser.parse_args()

    if args.fixture:
        with open(args.fixture, encoding="utf-8") as f:
            records = parse_comment_records(json.load(f))
    else:
        try:
            records = fetch_comments_via_acli(args.ticket)
        except RuntimeError as exc:
            print(f"WARNING: could not fetch comments — {exc}", file=sys.stderr)
            # Still exit 0; missing data is not a script failure.
            return 0

    jira_columns = (
        [c.strip() for c in args.jira_columns.split(",") if c.strip()]
        if args.jira_columns
        else None
    )

    all_warnings: list[str] = []
    all_warnings.extend(check_emoji_tense_mismatch(records))
    all_warnings.extend(check_phase_order(records))
    all_warnings.extend(check_column_match(records, jira_columns))

    if all_warnings:
        print(
            f"\nAudit warnings for {args.ticket} ({len(all_warnings)} finding(s)):\n",
            file=sys.stderr,
        )
        for w in all_warnings:
            print(f"  ⚠️  {w}", file=sys.stderr)
        print("", file=sys.stderr)
    # Exit 0 always — this is advisory tooling.
    return 0


if __name__ == "__main__":
    sys.exit(main())
