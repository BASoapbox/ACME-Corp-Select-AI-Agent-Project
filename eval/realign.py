#!/usr/bin/env python3
"""Redeploy drifted tools from SA_03_agent_setup.sql.

check_drift.py reports a difference between the deployed agent and the setup
script. This closes it, for tools only, by recreating each drifted tool from the
attributes the script declares -- nothing is composed here, and a tool the
script does not declare is never touched.

    python realign.py            # show what would change, change nothing
    python realign.py --apply    # drop and recreate the drifted tools

A tool is dropped before it is recreated, because CREATE_TOOL will not overwrite
one that exists. The agent keeps referring to the tool by name, so the reference
survives the drop -- but between the two statements the tool is genuinely absent,
so do not run this against an agent that is serving traffic.

Only tools are handled. An agent, task, or team that has drifted is reported and
left alone: recreating those re-forms the team's wiring, which is worth doing by
hand with the script in front of you.
"""
from __future__ import annotations

import argparse
import configparser
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import run_eval as R        # noqa: E402  (connect)
import check_drift as D     # noqa: E402  (the parse and compare already written)


def drifted_tools(cur) -> list[tuple[str, dict]]:
    """Tool names whose declared attributes are not all present and equal."""
    sql = D.SETUP.read_text(encoding="utf-8")
    out = []
    for kind, name, want in D.declared_blocks(sql):
        if isinstance(want, Exception):
            print(f"  skipped {name}: attributes are not valid JSON -- {want}")
            continue
        have = D.live_attributes(cur, kind, name)
        differs = [k for k, v in want.items()
                   if k not in have or not D._equal(v, have[k])]
        if not differs:
            continue
        if kind != "TOOL":
            print(f"  NOT HANDLED [{kind}] {name}: {', '.join(differs)} "
                  f"-- rerun SA_03 by hand for this one")
            continue
        out.append((name, want))
        print(f"  [{kind}] {name}: will recreate for {', '.join(differs)}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true",
                    help="perform the change; without it nothing is written")
    args = ap.parse_args()

    cfg = configparser.ConfigParser()
    cfg.read(HERE / "eval.ini")
    conn = R.connect(cfg)
    cur = conn.cursor()

    print(f"  Reading {D.SETUP.name}\n")
    todo = drifted_tools(cur)
    if not todo:
        print("\n  Nothing to realign.")
        return 0

    if not args.apply:
        print(f"\n  {len(todo)} tool(s) would be recreated. Re-run with --apply.")
        return 0

    print()
    for name, want in todo:
        attrs = json.dumps(want)
        cur.execute("BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL(:n); "
                    "EXCEPTION WHEN OTHERS THEN NULL; END;", n=name)
        cur.execute("BEGIN DBMS_CLOUD_AI_AGENT.CREATE_TOOL("
                    "tool_name => :n, attributes => :a); END;", n=name, a=attrs)
        cur.execute("SELECT attribute_name FROM user_ai_agent_tool_attributes "
                    "WHERE tool_name = :n ORDER BY 1", n=name)
        print(f"  {name}: recreated with {', '.join(a for a, in cur)}")
    conn.commit()

    print("\n  Done. Run check_drift.py to confirm, then re-run the evals.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
