#!/usr/bin/env python3
"""
Evaluation harness for the ACME Select AI Agent.

Runs a fixed set of cases against a deployed agent team, scores each one, and
records the run in the database so results are comparable over time.

What makes the scoring more than string matching:

  * Ground truth is computed at run time. A case can carry `verify_sql`; the
    harness runs it and requires the answer to contain that value, so expected
    figures cannot go stale when the data changes.
  * Tool attribution is exact. RUN_TEAM returns a team_exec_id and
    USER_AI_AGENT_TOOL_HISTORY records it, so "the SQL tool answered this" is
    checked rather than assumed.
  * Refusals are first-class. Asking about a department with no rows must
    produce a refusal and no figure at all.
  * Known defects are declared, so a documented failure never masks a new one.

Exit codes:  0 clean   1 new failure (regression)   2 could not run

Usage:
    python run_eval.py [--config eval.ini] [--cases cases.yaml]
                       [--only sql,rag] [--case <id>] [--no-store] [--quiet]
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import re
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("PyYAML is required: pip install pyyaml")

try:
    import oracledb
except ImportError:
    sys.exit("python-oracledb is required: pip install oracledb")

HERE = Path(__file__).parent


# ─────────────────────────────────────────────────────────────────────────────
# Connection
# ─────────────────────────────────────────────────────────────────────────────

def _password(cfg, db_user: str) -> str:
    """
    Resolve the login password. Order: this user's OCI Vault secret, then
    OCI_DB_PASSWORD_<USER>, then OCI_DB_PASSWORD. Never read from the ini file
    — the ini is committed as a template and must stay free of secrets.
    """
    ocid = cfg.get("secrets", db_user.upper(), fallback="").strip()
    if ocid:
        try:
            import base64
            import oci
            oci_cfg = oci.config.from_file(
                os.path.expanduser(cfg.get("oci", "config_file", fallback="~/.oci/config")),
                cfg.get("oci", "config_profile", fallback="DEFAULT"))
            bundle = oci.secrets.SecretsClient(oci_cfg).get_secret_bundle(
                ocid, stage="CURRENT").data
            return base64.b64decode(bundle.secret_bundle_content.content).decode().strip()
        except Exception as ex:                       # non-fatal: fall through
            print(f"  Vault lookup for {db_user} failed ({type(ex).__name__}) — "
                  f"falling back to the environment")

    for key in (f"OCI_DB_PASSWORD_{db_user.upper()}", "OCI_DB_PASSWORD"):
        if os.environ.get(key, "").strip():
            return os.environ[key].strip()
    sys.exit(f"No password for {db_user}: set [secrets] {db_user.upper()} "
             f"to a Vault secret OCID, or export OCI_DB_PASSWORD_{db_user.upper()}")


def connect(cfg):
    db_user = cfg.get("database", "db_user")
    schema  = cfg.get("database", "target_schema", fallback="").strip()
    wallet  = os.path.expanduser(cfg.get("database", "wallet_dir"))
    lib_dir = os.path.expanduser(cfg.get("database", "lib_dir", fallback="")).strip()

    os.environ["TNS_ADMIN"] = wallet
    if lib_dir:
        try:
            oracledb.init_oracle_client(lib_dir=lib_dir)
        except Exception as ex:
            if "already been called" not in str(ex).lower():
                sys.exit(f"Oracle client init failed: {ex}")

    user = f"{db_user}[{schema}]" if schema else db_user
    return oracledb.connect(user=user, password=_password(cfg, db_user),
                            dsn=cfg.get("database", "dsn"), wallet_location=wallet)


# ─────────────────────────────────────────────────────────────────────────────
# Running one case
# ─────────────────────────────────────────────────────────────────────────────

def _clob(v):
    return v.read() if hasattr(v, "read") else (v or "")


def ask(conn, team: str, question: str):
    """Run one prompt. Returns (answer, team_exec_id, elapsed_ms)."""
    cur = conn.cursor()
    ans = cur.var(oracledb.DB_TYPE_CLOB)
    eid = cur.var(oracledb.DB_TYPE_VARCHAR, 200)
    t0 = time.time()
    # A conversation id must come from CREATE_CONVERSATION; SYS_GUID() is
    # rejected with ORA-20050. The prompt parameter is user_prompt, not query.
    cur.execute("""
        DECLARE
            v_conv VARCHAR2(200);
        BEGIN
            v_conv := DBMS_CLOUD_AI.CREATE_CONVERSATION();
            :ans := DBMS_CLOUD_AI_AGENT.RUN_TEAM(
                        team_name    => :team,
                        user_prompt  => :q,
                        params       => '{"conversation_id":"' || v_conv || '"}',
                        team_exec_id => :eid);
        END;""", ans=ans, team=team, q=question, eid=eid)
    return _clob(ans.getvalue()).strip(), eid.getvalue(), int((time.time() - t0) * 1000)


def tools_fired(conn, team_exec_id: str) -> list[str]:
    """Exactly the tools this execution invoked — no time-window heuristic."""
    cur = conn.cursor()
    cur.execute("SELECT tool_name FROM user_ai_agent_tool_history "
                "WHERE team_exec_id = :e ORDER BY task_order", e=team_exec_id)
    return [r[0] for r in cur.fetchall()]


def ground_truth(conn, sql: str) -> str:
    cur = conn.cursor()
    cur.execute(sql.strip().rstrip(";"))
    row = cur.fetchone()
    return "" if not row or row[0] is None else str(row[0]).strip()


# ─────────────────────────────────────────────────────────────────────────────
# Scoring
# ─────────────────────────────────────────────────────────────────────────────

# An explicit zero counts as a refusal: "Europe HQ spent $0" came from running
# the query and getting nothing, which is the behaviour being tested. What must
# never appear is an invented non-zero figure.
REFUSAL = re.compile(
    r"\bno (?:data|records?|transactions?|information|expenses?|spend(?:ing)?|"
    r"results?|activity)\b|\bnot found\b|\bdoes not (?:exist|have)\b|"
    r"\bthere (?:is|are) no\b|\bunable to\b|\bcannot find\b|"
    r"\bnot available\b|\bzero\b|\$\s?0(?:\.00)?\b|\bis 0\b", re.I)


def _number_variants(value: str) -> list[str]:
    """176000 should also match 176,000 / $176,000 / 176000.00 in prose."""
    v = value.strip().replace(",", "")
    out = {value.strip(), v}
    try:
        f = float(v)
    except ValueError:
        return [x for x in out if x]
    if f.is_integer():
        out.add(f"{int(f):,}")
        out.add(str(int(f)))
    else:
        out.add(f"{f:,.2f}")
        out.add(f"{f:.2f}")
    return [x for x in out if x]


def score(case: dict, answer: str, fired: list[str], elapsed_ms: int,
          truth: str | None) -> list[str]:
    """Return a list of failure reasons; empty means the case passed."""
    fails: list[str] = []
    low = answer.lower()

    if truth is not None:
        if not any(v.lower() in low for v in _number_variants(truth)):
            fails.append(f"expected value {truth!r} absent from the answer")

    for s in case.get("must_include", []):
        if s.lower() not in low:
            fails.append(f"missing {s!r}")

    if case.get("must_match") and not re.search(case["must_match"], answer):
        fails.append(f"no match for /{case['must_match']}/")

    if case.get("must_not_match") and re.search(case["must_not_match"], answer):
        fails.append(f"matched forbidden /{case['must_not_match']}/")

    if case.get("expect_refusal") and not REFUSAL.search(answer):
        fails.append("expected a refusal, got an answer")

    expect = [t.upper() for t in case.get("expect_tools", [])]
    fired_u = [t.upper() for t in fired]
    for t in expect:
        if t not in fired_u:
            fails.append(f"{t} did not fire (fired: {', '.join(fired_u) or 'none'})")
    for t in [t.upper() for t in case.get("forbid_tools", [])]:
        if t in fired_u:
            fails.append(f"{t} fired and should not have")

    budget = case.get("max_seconds")
    if budget and elapsed_ms > budget * 1000:
        fails.append(f"took {elapsed_ms/1000:.1f}s, budget {budget}s")

    return fails


# ─────────────────────────────────────────────────────────────────────────────
# Persistence
# ─────────────────────────────────────────────────────────────────────────────

def _git_ref() -> str:
    try:
        return subprocess.run(["git", "rev-parse", "--short", "HEAD"], cwd=HERE,
                              capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:
        return ""


def store(conn, run_id, team, results, started, notes):
    cur = conn.cursor()
    passed = sum(1 for r in results if r["passed"])
    known  = sum(1 for r in results if r["known_failure"] and not r["passed"])
    failed = sum(1 for r in results if not r["passed"] and not r["known_failure"])
    cur.execute("""
        INSERT INTO acme_eval_runs
          (run_id, started_at, finished_at, team_name, case_count, passed, failed,
           known_failed, pass_pct, git_ref, notes)
        VALUES (:1, :2, SYSTIMESTAMP, :3, :4, :5, :6, :7, :8, :9, :10)""",
        [run_id, started, team, len(results), passed, failed, known,
         round(100.0 * passed / len(results), 1) if results else 0, _git_ref(), notes])
    cur.executemany("""
        INSERT INTO acme_eval_results
          (run_id, case_id, category, question, answer, passed, known_failure,
           failures, elapsed_ms, tools_fired, team_exec_id, attempts, pass_count)
        VALUES (:1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11, :12, :13)""",
        [[run_id, r["id"], r["category"], r["question"][:1000], r["answer"],
          "Y" if r["passed"] else "N", "Y" if r["known_failure"] else "N",
          "; ".join(r["failures"])[:4000], r["elapsed_ms"],
          ", ".join(r["tools"])[:400], r["team_exec_id"],
          r.get("attempts", 1), r.get("pass_count", 1 if r["passed"] else 0)]
         for r in results])
    conn.commit()


def previous_failures(conn, run_id) -> tuple[set[str], bool]:
    """
    Case ids that failed in the most recent earlier run, and whether such a run
    exists. Without the second value a first run looks like every case just
    regressed.
    """
    cur = conn.cursor()
    cur.execute("""SELECT run_id FROM (SELECT run_id FROM acme_eval_runs
                   WHERE run_id <> :1 ORDER BY started_at DESC) WHERE ROWNUM = 1""",
                [run_id])
    row = cur.fetchone()
    if not row:
        return set(), False
    cur.execute("SELECT case_id FROM acme_eval_results "
                "WHERE run_id = :1 AND passed = 'N'", [row[0]])
    return {r[0] for r in cur.fetchall()}, True


# ─────────────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--config", default=str(HERE / "eval.ini"))
    ap.add_argument("--cases", default=str(HERE / "cases.yaml"))
    ap.add_argument("--only", help="comma-separated categories")
    ap.add_argument("--case", help="run a single case id")
    ap.add_argument("--no-store", action="store_true", help="do not write to the database")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    if not Path(args.config).exists():
        print(f"Config not found: {args.config}\nCopy eval.ini.template to eval.ini "
              f"and fill it in.", file=sys.stderr)
        return 2

    cfg = configparser.ConfigParser()
    cfg.read(args.config)
    spec = yaml.safe_load(Path(args.cases).read_text(encoding="utf-8"))
    defaults = spec.get("defaults", {}) or {}
    cases = spec["cases"]

    if args.only:
        wanted = {c.strip().lower() for c in args.only.split(",")}
        cases = [c for c in cases if c.get("category", "").lower() in wanted]
    if args.case:
        cases = [c for c in cases if c["id"] == args.case]
    if not cases:
        print("No cases selected", file=sys.stderr)
        return 2

    team = cfg.get("agent", "team_name")
    conn = connect(cfg)
    run_id = uuid.uuid4().hex[:16]
    started = datetime.now(timezone.utc).replace(tzinfo=None)

    print(f"\n  Eval run {run_id} — team {team} — {len(cases)} cases\n")
    results = []
    for case in cases:
        merged = {**defaults, **case}
        # A flaky case is a fact about the system, not a coin toss to re-flip
        # until it agrees with you. `repeat` samples it N times and `min_passes`
        # says how many must hold; the recorded pass rate is the finding.
        attempts = max(1, int(merged.get("repeat", 1)))
        need = int(merged.get("min_passes", attempts))
        tries = []
        for _ in range(attempts):
            try:
                answer, eid, ms = ask(conn, team, merged["question"])
                fired = tools_fired(conn, eid) if eid else []
                truth = (ground_truth(conn, merged["verify_sql"])
                         if merged.get("verify_sql") else None)
                fails = score(merged, answer, fired, ms, truth)
            except Exception as ex:
                answer, eid, ms, fired, truth = f"ERROR: {ex}", None, 0, [], None
                fails = [f"execution failed: {str(ex).splitlines()[0][:120]}"]
            tries.append({"answer": answer, "eid": eid, "ms": ms,
                          "tools": fired, "fails": fails, "truth": truth})

        good = [t for t in tries if not t["fails"]]
        passed = len(good) >= need
        shown = (good[0] if good else
                 sorted(tries, key=lambda t: len(t["fails"]))[0])
        fails = [] if passed else shown["fails"]
        if attempts > 1 and not passed:
            fails = [f"{len(good)}/{attempts} attempts passed, needed {need}"] + fails

        rec = {"id": merged["id"], "category": merged.get("category", ""),
               "question": merged["question"], "answer": shown["answer"],
               "passed": passed, "known_failure": bool(merged.get("known_failure")),
               "failures": fails, "elapsed_ms": max(t["ms"] for t in tries),
               "tools": shown["tools"], "team_exec_id": shown["eid"],
               "truth": shown["truth"], "attempts": attempts, "pass_count": len(good)}
        results.append(rec)

        mark = "PASS" if passed else ("KNOWN" if rec["known_failure"] else "FAIL")
        rate = f" {len(good)}/{attempts}" if attempts > 1 else ""
        print(f"  [{mark:5}] {merged['id']:34}{rate:5} "
              f"{rec['elapsed_ms']/1000:5.1f}s  {', '.join(shown['tools']) or '-'}")
        if fails and not args.quiet:
            for f in fails:
                print(f"           → {f}")
            print(f"           answer: {shown['answer'][:150].replace(chr(10), ' ')}")

    passed = sum(1 for r in results if r["passed"])
    known  = sum(1 for r in results if r["known_failure"] and not r["passed"])
    new    = [r for r in results if not r["passed"] and not r["known_failure"]]

    print(f"\n  {passed}/{len(results)} passed"
          f"   ({known} known failure{'s' if known != 1 else ''}, {len(new)} unexpected)")

    if not args.no_store:
        try:
            store(conn, run_id, team, results, started, notes="")
            prev, had_baseline = previous_failures(conn, run_id)
            if not had_baseline:
                print("  first run — no baseline to compare against")
            else:
                regressions = [r["id"] for r in new if r["id"] not in prev]
                fixed = [p for p in prev
                         if any(r["id"] == p and r["passed"] for r in results)]
                if fixed:
                    print(f"  fixed since last run: {', '.join(sorted(fixed))}")
                if regressions:
                    print(f"  NEW since last run:   {', '.join(regressions)}")
            print(f"  stored as run {run_id}")
        except Exception as ex:
            print(f"  could not store results: {ex}")

    out = HERE / "results" / f"{run_id}.json"
    out.parent.mkdir(exist_ok=True)
    out.write_text(json.dumps({"run_id": run_id, "team": team,
                               "started": started.isoformat(), "results": results},
                              indent=2, default=str), encoding="utf-8")
    print(f"  wrote {out.relative_to(HERE.parent)}\n")
    return 1 if new else 0


if __name__ == "__main__":
    sys.exit(main())
