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
| `repeat` / `min_passes` | sample the case N times; require M to hold |

Four of these are the point of the harness.

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

**A flaky case is a measurement, not a coin toss.** Re-running until a case
agrees with you is how a suite stops meaning anything. `repeat` samples a case
and `min_passes` sets the bar, so the recorded number is the real reliability:

```yaml
- id: route-anomaly-then-policy
  expect_tools: [ACME_ANOMALY_TOOL, ACME_RAG_TOOL]
  repeat: 5
  min_passes: 4
```

```
[KNOWN] route-anomaly-then-policy   4/5   14.9s  ACME_SQL_TOOL, ACME_RAG_TOOL, …
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
already accepted cannot hide one you have not.

One case carries it today. `route-anomaly-not-forecast` asks whether AUG-2025
spending was anomalous — a period already in the ledger, so never a forecast
question — and the forecast tool fires anyway, 0/5.

The attempt to fix it is the reason the flag exists. Three rewrites were tried,
in place with `DBMS_CLOUD_AI_AGENT.SET_ATTRIBUTE`, and the harness caught each
one making something else worse:

| Change | Effect |
|---|---|
| Task instruction: explicit "anomalous ⇒ ANOMALY, never FORECAST" | routing 0/3 → 4/5 |
| Forecast tool: added "never use for a period that already exists" | **plain lookups broke** — `sql-sales-jun2025` 5/5 → 0/5, answered with a forecast |
| Forecast tool reworded positively, exclusions moved to the task | lookups recovered, routing fell to 2/5 |
| Routing rules restated in the agent role as well | worst of all — lookups 0/5 |

Naming "past periods" inside the forecast tool's own instruction, even to forbid
them, made that tool match past-period questions. All of it was reverted.

The revert itself then turned out to be incomplete, which is worth more than the
defect. Restoring the tools rewrote each one from its `instruction` alone, so all
four custom tools came back **without their `tool_inputs`** — the per-parameter
descriptions. Every eval still passed, because no case asserts what the agent
*is*. `check_drift.py` exists because of that, and is the check that found it.

So the 0/5 above was never a measurement of the shipped agent. The deployment was
realigned with `realign.py` on 2026-09-28 and the case re-measured: **still 0/5**.
The defect is real, and is not an artefact of the drift.

This section used to say the defect was cosmetic: *"the anomaly tool does fire
and the answer stays grounded."* **That was wrong**, and the way it was wrong is
the most useful thing in this file — see the next section.

### What tool checks could not see

Until 2026-10-13 both routing cases asserted only *which tools fired*. A
confirmation run before publishing turned up an answer saying AUG-2025 spending
was *"forecasted to be $34,880.56, which is not flagged as anomalous"* — the
ledger holds $176,000, about 179% above average. Reading every answer by hand
across that day's runs:

**26 of 45 answers to this question were wrong (58%).** They give the forecast
as the period's spending, deny the anomaly, dodge it ("for anomalous spending,
policy requires…"), or say there is no data for a period with $176,000 in it.
Many fired exactly the tools the case expected, and passed.

Two things hid it for two weeks:

- **No case looked at the answer.** The routing cases now do — a correct answer
  states that the spending is anomalous, never denies it, never says there is no
  data, and brings no forecast or predicted figure into a question about a period
  already in the ledger. The patterns are in `cases.yaml`, and tested in
  `test_routing_answers.py` against real answers in both directions.
- **Only one answer per case was kept**, and for a passing case it was the first
  *passing* attempt. Every attempt's answer is now in `results/<run_id>.json`
  under `tries`, and a sampled case prints a tally of why its attempts failed.

The deployment had not changed — `check_drift.py` was clean throughout — so this
is either a change on the model side or something that was always there and
never read. With one stored answer per case from September, there is no way to
tell which.

The answer checks were themselves wrong twice on the way, both times by passing
wrong answers: the word "anomalous" in a dodge satisfied the first version, and
"the predicted expense for AUG-2025 is $34,880.56" slipped past the second. The
final version agrees with a hand reading of all 30 answers it was checked
against. One rule in it is a judgement call, made on purpose: an answer with the
right verdict that then reports a "discrepancy" against the forecast is failed,
because a forecast has no place in that answer at all.

### What the same realign did to the numbers

Restoring `tool_inputs` visibly widened the fan-out — the two-tool routing case
now also reaches the SQL and forecast tools. The first four runs after it read
3/5, 4/5, 3/5, 5/5 and looked like a clear regression. The next two runs of ten
read 10/10 and 9/10. Same configuration, same questions, twenty minutes apart;
wall time for the case swung from 16s to 48s alongside it, which points at load
on the model endpoint rather than at anything in the agent.

**One run of five is not a measurement.** The gate on that case is now 6 of 10
rather than 4 of 5, because at the observed rate a 4-of-5 gate fails often enough
on a healthy agent to teach you to re-run until it passes — which is the habit
this harness exists to prevent.

Those 34/40 were tool checks only. Which answers behind them were right was never
recorded, so read them as "the right tools fired 85% of the time," not "the
agent answered correctly 85% of the time."

---

## Checking the deployed agent against the script

The harness asserts what the agent *answers*. That is not the same as asserting
what the agent *is*, and an agent can keep passing its evals while its deployed
definition has drifted from the script in this repository.

```bash
python check_drift.py     # exit 1 if the database differs from SA_03
```

It reads every `CREATE_TOOL` / `CREATE_AGENT` / `CREATE_TASK` / `CREATE_TEAM`
block in `SA_03_agent_setup.sql` and compares each declared attribute with
`user_ai_agent_*_attributes`. Attributes present in the database but absent from
the script are reported as notes rather than drift — Oracle supplies its own
default `instruction` for the built-in `sql` and `rag` tool types, and derives
the task's `tools` list from the agent.

Run it before an eval run you intend to trust, and after any change made with
`SET_ATTRIBUTE` rather than by re-running the script.

`realign.py` closes what it finds, for tools, by recreating each drifted tool
from the attributes the script declares:

```bash
python realign.py            # show what would change, change nothing
python realign.py --apply    # drop and recreate the drifted tools
```

A tool is dropped before it is recreated, so do not run it against an agent that
is serving traffic. Drifted agents, tasks and teams are reported and left alone —
recreating those re-forms the team's wiring, which is worth doing by hand.

---

## The scorer is code too

```bash
python test_refusal.py           # no database needed
python test_routing_answers.py   # no database needed
```

The refusal pattern has been wrong four times, and every time in the same
direction: it failed the agent for an answer that was correct. `$0` is a grounded
answer when the query returned nothing. "had **no recorded** expenses" is a
refusal that a pattern anchored on `no expenses` does not match.

A scorer that is wrong does not report itself as broken — it accuses the thing it
is measuring, and the accusation looks like a finding. `test_refusal.py` pins both
directions: real refusals the agent has produced must read as refusals, and
invented figures must not. Add a line to it *before* changing the pattern.

`test_routing_answers.py` does the same for the routing answer checks, and reads
their patterns straight from `cases.yaml` so the two cannot disagree. Those
checks failed in the opposite direction — passing wrong answers — which is the
quieter failure: nothing goes red.

---

## Options

```bash
python run_eval.py --only sql,rag     # one or more categories
python run_eval.py --case refusal-empty-department
python run_eval.py --no-store         # do not write to the database
python check_drift.py                 # deployed agent vs. SA_03
python realign.py --apply             # redeploy drifted tools from SA_03
python test_refusal.py                # unit-test the scorer, no database
python test_routing_answers.py        # unit-test the routing answer checks
```

Results are also written to `results/<run_id>.json`, which is gitignored —
answers contain live data.

## Requirements

`oracledb` (thick mode, so an Instant Client is needed), `pyyaml`, and
optionally `oci` for reading the login password from Vault.
