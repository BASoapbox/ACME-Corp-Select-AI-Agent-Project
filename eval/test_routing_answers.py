#!/usr/bin/env python3
"""Unit tests for the answer checks on the two routing cases. No database needed.

Those cases used to assert only which tools fired. On 2026-10-13 that turned out
to pass wrong answers: one quoted the forecast tool's $34,880.56 as Engineering's
AUG-2025 spending and still fired both tools the case expected. So the cases now
check the answer too -- and since the refusal pattern has been wrong four times,
always by failing a correct answer, these patterns get fixtures before they get
trusted.

The patterns are read from cases.yaml rather than copied here, so the test and
the harness cannot disagree.

    python test_routing_answers.py

Every fixture is a real answer the agent produced, cut at about 150 characters
where it was printed that way. Add a line here before changing the patterns.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
CASES = ("route-anomaly-not-forecast", "route-anomaly-then-policy")

# Correct: says the spending is anomalous, from the anomaly tool's result.
# Loose wording is fine -- "predicted to be anomalous" cites the real 179.12%.
CORRECT = [
    "Engineering spending in AUG-2025 is predicted to be anomalous with a deviation "
    "of 179.12%. Level 2 managerial approval is required for anomalous spend",
    "The Engineering spending in AUG-2025 is flagged as anomalous according to the "
    "ANOMALY tool, with an expense of $176,000, and requires Level 2 manageri",
    "The Engineering spending in AUG-2025 is anomalous and requires Level 2 "
    "managerial approval according to ACME Corp's Financial Reconciliation Policy.",
    "Yes, Engineering spending in AUG-2025 was anomalous, and it requires Level 2 "
    "managerial approval as per ACME Corp's financial reconciliation policy.",
    "Yes, Engineering spending in AUG-2025 is anomalous, and Level 2 managerial "
    "approval is required if it exceeds $10,000.",
    "The Engineering department's spending in AUG-2025 is anomalous, deviating "
    "179.12% from the average. According to ACME Corp policy, transactions exceed",
    "Engineering spending in AUG-2025 is flagged as anomalous. According to ACME "
    "Corp policy, transactions exceeding $10,000 require Level 2 managerial app",
    "Engineering spending in AUG-2025 is anomalous ($176,000). Policy requires "
    "Level 2 managerial approval for transactions exceeding $10,000.",
    "Engineering spending in AUG-2025 is predicted to be anomalous and requires "
    "Level 2 managerial approval if it involves transactions over $10,000.",
    "The Engineering department's spending in AUG-2025 is anomalous and requires "
    "Level 2 managerial approval.",
]

# Wrong: each of these was produced by the agent and each would have passed a
# tools-only check.
WRONG = [
    # the forecast presented as actual spending
    "Engineering spending in AUG-2025 is predicted to be anomalous with a "
    "forecasted expense of $34,880.56. According to ACME Corp policy, this will requir",
    "The forecasted Engineering spending in AUG-2025 is $34,880.56. If considered "
    "anomalous, it requires Level 2 managerial approval according to ACME Corp",
    "The forecasted Engineering spending for AUG-2025 is $34,880.56. According to "
    "company policy, if the actual spending is anomalous and exceeds $10,000,",
    # the anomaly denied
    "The Engineering spending in AUG-2025 is forecasted to be $34880.56, which is "
    "not flagged as anomalous based on our analysis. Level 2 managerial approv",
    "No, Engineering spending in AUG-2025 is not anomalous. Policy requires Level 2 "
    "approval above $10,000.",
    "The forecasted Engineering spending in AUG-2025 is $42,930.56, which is not "
    "anomalous based on the forecast alone. According to company policy, this amount",
    # the same mistake without the word "forecast" -- passed the first version
    "Engineering spending in AUG-2025 is predicted to be $34,880.56 and is flagged "
    "as anomalous. Policy requires managerial approval for significant transactions",
    # a dodge: quotes the policy, never says whether AUG-2025 is anomalous --
    # passed the first version because the word "anomalous" appears in it
    "For anomalous Engineering department spending exceeding $10,000, Level 2 "
    "managerial approval is required by policy.",
    # a "predicted" figure stated as the period's expense -- passed the second
    # version, which only caught "predicted to be $"
    "Yes, Engineering spending in AUG-2025 is predicted to be anomalous, and "
    "according to ACME Corp policy, it requires Level 2 managerial approval if "
    "transactions exceed $10,000. The predicted expense for AUG-2025 is $34,880.56.",
    # right verdict, real figure, then an invented "discrepancy" with the forecast.
    # A judgement call: failed on purpose, because a forecast has no place in an
    # answer about a period that is already in the ledger. If that rule is ever
    # relaxed, move this line to CORRECT and say so in cases.yaml.
    "Engineering spending in AUG-2025 is considered anomalous according to the "
    "ANOMALY tool, with a significant deviation from the average. For such "
    "anomalous spending, Level 2 managerial approval is required if the "
    "transaction exceeds $10,000. However, there's a discrepancy between the "
    "forecasted amount ($34880.56) and the amount used in anomaly detection ($176000).",
    "The Engineering department's predicted spending in AUG-2025 is anomalous, and "
    "according to ACME Corp policy, it requires Level 2 managerial approval if it "
    "exceeds $10,000. The forecasted expense for AUG-2025 is $34,880.56, which is "
    "below the $10,000 threshold.",
    # a false refusal: the ledger holds $176,000 for that period
    "There is no data for Engineering department spending in AUG-2025. According "
    "to ACME Corp policy, if anomalous spending exceeds $10,000, it requires Le",
]


def _passes(case: dict, text: str) -> bool:
    if case.get("must_match") and not re.search(case["must_match"], text):
        return False
    if case.get("must_not_match") and re.search(case["must_not_match"], text):
        return False
    return True


def main() -> int:
    spec = yaml.safe_load((HERE / "cases.yaml").read_text(encoding="utf-8"))
    by_id = {c["id"]: c for c in spec["cases"]}
    bad = []
    for cid in CASES:
        case = by_id[cid]
        if not (case.get("must_match") and case.get("must_not_match")):
            bad.append(f"  {cid}: has no answer checks at all")
            continue
        for text in CORRECT:
            if not _passes(case, text):
                bad.append(f"  {cid}: failed a correct answer:\n      {text}")
        for text in WRONG:
            if _passes(case, text):
                bad.append(f"  {cid}: passed a wrong answer:\n      {text}")

    total = len(CASES) * (len(CORRECT) + len(WRONG))
    if bad:
        print(f"  {len(bad)} of {total} failed:\n")
        print("\n".join(bad))
        return 1
    print(f"  {total} routing-answer checks pass across {len(CASES)} cases "
          f"({len(CORRECT)} correct answers kept, {len(WRONG)} wrong ones caught).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
