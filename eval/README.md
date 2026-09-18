# Evaluation harness — ACME Select AI Agent

A regression test suite for a system that answers differently every time.

Normal code returns the same output for the same input, so a unit test asserts
equality. An agent does not, so this asserts the things that must hold:
the figure came from the ledger, the right tool did the work, an unanswerable
question was refused, and it happened inside a time budget.

```bash
cp eval.ini.template eval.ini      # fill in; no passwords go in this file
python run_eval.py
```

Exit code is `0` when clean and `1` when a case fails that was not already
failing — so it can gate a pipeline.

---

## What a case can assert

| | |
|---|---|
| `verify_sql` | SQL returning the ground truth. The answer must contain that value. |
| `must_include` / `must_match` | strings or a regex that must appear |
| `must_not_match` | regex that must not appear |
| `expect_refusal` | the answer must decline rather than produce a figure |
| `expect_tools` / `forbid_tools` | which tools must and must not have run |
| `max_seconds` | wall-clock budget |
| `known_failure` | a documented defect, counted separately |

Three of these are the point of the harness.

**Ground truth is computed, not hard-coded.** A case carries the SQL that
produces the expected answer, and the harness runs it at evaluation time:

```yaml
- id: sql-engineering-aug2025
  question: What were total Engineering expenses in August 2025?
  verify_sql: |
    SELECT TO_CHAR(SUM(t.debit_amount))
    FROM   acme_gl_transactions t
    JOIN   acme_departments d ON d.department_code = t.department_code
    WHERE  d.department_name = 'Engineering' AND t.period_name = 'AUG-2025'
  expect_tools: [ACME_SQL_TOOL]
```

Load a new month and the expected figure moves with it. A suite of hard-coded
numbers starts failing for the wrong reason, and the usual fix — updating the
expected value to whatever came back — quietly deletes the test.

**Tool attribution is exact.** `RUN_TEAM` has an overload returning a
`team_exec_id`, and `USER_AI_AGENT_TOOL_HISTORY` records it:

```sql
SELECT tool_name FROM user_ai_agent_tool_history
WHERE  team_exec_id = :e ORDER BY task_order;
```

So `expect_tools` is checked rather than assumed. Without it, an agent that
answers from model knowledge and calls nothing still passes a text assertion —
which is the failure worth catching, because the answer looks fine.

**Refusals are cases.** `ACME_DEPARTMENTS` contains a department with no
transactions. Asked about it, the agent must say there is no data and must not
quote a figure:

```yaml
- id: refusal-empty-department
  question: How much did Europe HQ spend in 2025?
  expect_refusal: true
  must_not_match: '\$?\d[\d,]{3,}'
```

---

## Runs are stored

`SA_07_eval_tables.sql` creates `ACME_EVAL_RUNS` and `ACME_EVAL_RESULTS`, so
"did this get better" is a SQL question:

```sql
SELECT r.started_at, r.pass_pct, r.passed, r.failed, r.known_failed
FROM   acme_eval_runs r ORDER BY r.started_at DESC FETCH FIRST 10 ROWS ONLY;

-- what broke between the last two runs
SELECT case_id, failures FROM acme_eval_results
WHERE  run_id = :latest AND passed = 'N'
AND    case_id NOT IN (SELECT case_id FROM acme_eval_results
                       WHERE run_id = :previous AND passed = 'N');
```

The harness prints that comparison itself: which cases are newly failing, and
which were fixed since the last run.

---

## Declared defects

`known_failure: true` marks a case that is currently broken and understood. It
is reported separately and does not set the exit code, so a defect you have
already accepted cannot hide one you have not. One case carries it today:
a question needing the anomaly tool followed by the policy documents reaches
the forecast tool instead, because the task instruction lists forecasting and
anomaly detection in adjacent sentences.

---

## Options

```bash
python run_eval.py --only sql,rag     # one or more categories
python run_eval.py --case refusal-empty-department
python run_eval.py --no-store         # do not write to the database
```

Results are also written to `results/<run_id>.json`, which is gitignored —
answers contain live data.

## Requirements

`oracledb` (thick mode, so an Instant Client is needed), `pyyaml`, and
optionally `oci` for reading the login password from Vault.
