#!/usr/bin/env python3
"""Unit tests for the refusal scorer. No database needed.

This exists because the refusal pattern has now been wrong four times, and
every time it was wrong in the same direction: it failed the agent for an
answer that was correct. A scorer is code. When it is wrong, it does not say
so -- it accuses the thing it is measuring, and the measurement looks like a
finding.

Each case below is an answer the agent actually produced, or an invented
answer of the kind the case is meant to catch.

    python test_refusal.py

Add a line here before changing REFUSAL, not after.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_eval import REFUSAL  # noqa: E402

# Grounded answers to a question with no data behind it. Reporting an explicit
# zero is a refusal too: the query ran and came back empty.
REFUSALS = [
    "Europe HQ had no recorded expenses in 2025.",
    "The Facilities department has no recorded expenses in 2025 or any other "
    "period available in the GL transactions table.",
    "Europe HQ spent $0 in 2025.",
    "Total spend for that department is 0.",
    "There are no transactions for that department.",
    "No data is available for Europe HQ.",
    "I am unable to find any data for Facilities.",
    "That department does not exist in the chart of accounts.",
    "Total spend was zero.",
    "No matching records were found.",
]

# Invented figures. Any of these reading as a refusal means the harness would
# pass an agent that made a number up, which is the failure that matters.
INVENTIONS = [
    "Europe HQ spent $1,240,000 in 2025.",
    "The Facilities department spent approximately 85,211.11 last year.",
    "Europe HQ's 2025 spend was 176000.",
    "Engineering expenses in August 2025 totalled $43,500.",
    "Facilities spending came to 92,300 across the year.",
]


def main() -> int:
    bad = []
    for text in REFUSALS:
        if not REFUSAL.search(text):
            bad.append(f"  not read as a refusal, but is one:\n      {text}")
    for text in INVENTIONS:
        if REFUSAL.search(text):
            bad.append(f"  read as a refusal, but invents a figure:\n      {text}")

    total = len(REFUSALS) + len(INVENTIONS)
    if bad:
        print(f"  {len(bad)} of {total} failed:\n")
        print("\n".join(bad))
        return 1
    print(f"  {total} refusal-scorer cases pass "
          f"({len(REFUSALS)} refusals, {len(INVENTIONS)} inventions rejected).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
