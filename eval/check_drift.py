#!/usr/bin/env python3
"""Compare the live agent configuration against SA_03_agent_setup.sql.

The eval harness asserts what the agent *answers*. This asserts what the agent
*is*: every attribute the setup script declares must be present and identical in
the database. They are not the same check. An agent can keep passing its evals
while its deployed definition has quietly drifted from the script in the
repository -- which is exactly what happened here on 2026-09-18, when a restore
rewrote four tools without their tool_inputs and every eval still passed.

    python check_drift.py            # exit 1 if the database differs

Attributes present live but absent from the script are reported separately and
do not fail the check: Oracle supplies its own default `instruction` for the
built-in sql and rag tool types.
"""
from __future__ import annotations

import configparser
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run_eval as R  # noqa: E402  (shares connect() and _clob())

SETUP = HERE.parent / "SA_03_agent_setup.sql"

# CREATE_<KIND>(<x>_name => '...', attributes => '...'), with '' as an escaped
# quote inside either literal, and any further arguments ignored.
BLOCK = re.compile(
    r"DBMS_CLOUD_AI_AGENT\.CREATE_(TOOL|AGENT|TASK|TEAM)\s*\(\s*"
    r"\w+\s*=>\s*'((?:[^']|'')*)'\s*,\s*"
    r"attributes\s*=>\s*'((?:[^']|'')*)'",
    re.S,
)

VIEW = {
    "TOOL":  ("user_ai_agent_tool_attributes", "tool_name"),
    "AGENT": ("user_ai_agent_attributes",      "agent_name"),
    "TASK":  ("user_ai_agent_task_attributes", "task_name"),
    "TEAM":  ("user_ai_agent_team_attributes", "agent_team_name"),
}


def live_attributes(cur, kind: str, name: str) -> dict[str, str]:
    view, col = VIEW[kind]
    cur.execute(f"SELECT attribute_name, attribute_value FROM {view} "
                f"WHERE {col} = :n", n=name)
    return {a: R._clob(v) for a, v in cur}


def declared_blocks(sql: str):
    for m in BLOCK.finditer(sql):
        kind = m.group(1)
        name = m.group(2).replace("''", "'")
        attrs = m.group(3).replace("''", "'")
        try:
            yield kind, name, json.loads(attrs)
        except json.JSONDecodeError as ex:
            yield kind, name, ex


def _equal(want, live: str) -> bool:
    """A JSON-valued attribute is compared as JSON, not as formatted text."""
    if isinstance(want, str):
        return live.strip() == want.strip()
    if live.strip() == json.dumps(want, separators=(",", ":")).strip():
        return True
    try:
        return json.loads(live) == want
    except json.JSONDecodeError:
        return False


def main() -> int:
    cfg = configparser.ConfigParser()
    cfg.read(HERE / "eval.ini")
    cur = R.connect(cfg).cursor()

    sql = SETUP.read_text(encoding="utf-8")
    drift: list[str] = []
    extra: list[str] = []
    checked = 0

    for kind, name, want in declared_blocks(sql):
        if isinstance(want, Exception):
            drift.append(f"[{kind}] {name}: attributes are not valid JSON -- {want}")
            continue
        checked += 1
        have = live_attributes(cur, kind, name)
        if not have:
            drift.append(f"[{kind}] {name}: not deployed")
            continue
        for key, value in want.items():
            if key not in have:
                text = value if isinstance(value, str) else json.dumps(value)
                drift.append(f"[{kind}] {name}.{key}: missing from the database\n"
                             f"        script: {text[:100]}")
            elif not _equal(value, have[key]):
                text = value if isinstance(value, str) else json.dumps(value)
                drift.append(f"[{kind}] {name}.{key}: differs\n"
                             f"        script: {text[:80]}\n"
                             f"        live:   {have[key][:80]}")
        for key in have:
            if key not in want:
                extra.append(f"[{kind}] {name}.{key}: set in the database, not in "
                             f"the script ({have[key][:60]}...)")

    print(f"  Checked {checked} object(s) declared in {SETUP.name}\n")
    if extra:
        for line in extra:
            print(f"  note   {line}")
        print()
    if drift:
        for line in drift:
            print(f"  DRIFT  {line}")
        print(f"\n  {len(drift)} difference(s). Re-run SA_03_agent_setup.sql to realign.")
        return 1
    print("  No drift: the deployed agent matches the script.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
