# ACME Corp — Select AI Agent on Oracle Autonomous Database

A complete, runnable Select AI Agent built with `DBMS_CLOUD_AI` and
`DBMS_CLOUD_AI_AGENT`: natural-language SQL over live tables, RAG over policy
documents, and four custom tools — three PL/SQL, one Python running inside the
database through OML4Py Embedded Python Execution.

Everything here is SQL. No application layer is required to build or test the
agent, though there is a note below on putting a chat UI in front of it.

---

## What gets built

```
                    ACME_ANALYST_TEAM  (team)
                            │
                    ACME_ANALYST  (agent)
                            │
   ┌────────────┬───────────┼───────────┬──────────────┬─────────────┐
   │            │           │           │              │             │
ACME_SQL_TOOL  ACME_RAG   TREND     FORECAST       ANOMALY       PYTHON
   │            _TOOL      _TOOL      _TOOL          _TOOL        _TOOL
   ▼            ▼          ▼          ▼              ▼             ▼
 GL tables   vector     LAG()     linear reg.   STDDEV()      numpy via
             index                                            pyqEval
```

Six tools. The agent chooses between them from the task instruction — there is no
routing code.

---


## Documentation

- **[Implementation Guide](docs/Select_AI_Agent_Implementation_Guide.docx)** — full walkthrough with diagrams, the custom-tool and OCI Vault sections, and an appendix of sample agent questions with expected answers
- **[CHECKLIST.md](CHECKLIST.md)** — prerequisites, each with a way to prove it worked

## Before you start

**Read [CHECKLIST.md](CHECKLIST.md).** It covers the prerequisites, and most of
what goes wrong in this stack is a prerequisite problem wearing a misleading error
message.

Two that catch nearly everyone:

- **IAM policy for the *database*, not for you.** The database calls Generative AI
  as its own Resource Principal. Tenancy-administrator rights do not cover it.
- **Model availability is regional.** A model that works in one region may not
  exist in another. Verify before configuring.

---

## Setup

```bash
cp SA_ENV.sql.template SA_ENV.sql
```

Edit `SA_ENV.sql` — region, compartment OCID, models, bucket. It is the only file
you change; every script reads from it. It is gitignored, and it holds no
passwords: scripts that need one prompt at run time with `ACCEPT ... HIDE`.

Values that can be derived are derived, so they cannot drift apart:

```sql
DEFINE region           = "us-ashburn-1"
DEFINE oml_root_domain  = "adb.&region..oraclecloudapps.com"
DEFINE rag_location_url = "https://objectstorage.&region..oraclecloud.com/n/&os_namespace./b/&rag_bucket./o/&rag_prefix./"
```

Change the region once and the OML endpoint and RAG URL follow.

---

## Run order

| Script | Run as | What it does |
|---|---|---|
| `SA_00_create_schema.sql` | **ADMIN** | Creates the schema. Prompts for a password |
| `SA_01_admin_setup.sql` | **ADMIN** | Resource Principal, `DBMS_CLOUD*` grants, OML roles, EPE network ACL |
| `SA_02_ddl_dml.sql` | schema | Seven tables, reference data, GL history with deliberate anomalies |
| `SA_03_agent_setup.sql` | schema | Comments, profiles, vector index, six tools, agent, task, team |
| `SA_04_operations.sql` | schema | Operational snippets — change model, rebuild index, rotate credential |
| `SA_05_cleanup.sql` | schema | Tear it all down |

```bash
sql -name <admin-connection> @SA_00_create_schema.sql
sql -name <admin-connection> @SA_01_admin_setup.sql
sql -name <schema-connection> @SA_02_ddl_dml.sql
sql -name <schema-connection> @SA_03_agent_setup.sql
```

Each step verifies before the next builds on it. Run them in order and read the
output — the agent stack is opaque enough that when something breaks you want to
already know which layers are solid.

`SA_04` is a menu, not a script — run individual sections as needed.

---

## Knowledge base

`rag-kb/` holds seven short synthetic finance documents — reconciliation policy,
SOX reference, period-close checklist, chart of accounts, and a mock report.
Upload them before running `SA_03`; see section 6 of the checklist.

They are deliberately small. Substitute your own to see RAG do real work.

---

## Testing it

```sql
DECLARE
    l_conversation_id VARCHAR2(36);
    l_response        CLOB;
BEGIN
    l_conversation_id := DBMS_CLOUD_AI.CREATE_CONVERSATION();
    l_response := DBMS_CLOUD_AI_AGENT.RUN_TEAM(
        team_name   => 'ACME_ANALYST_TEAM',
        user_prompt => 'What were Engineering expenses in August 2025?',
        params      => '{"conversation_id":"' || l_conversation_id || '"}'
    );
    DBMS_OUTPUT.PUT_LINE(l_response);
END;
/
```

Note `DBMS_CLOUD_AI.CREATE_CONVERSATION` — that is `DBMS_CLOUD_AI`, not
`DBMS_CLOUD_AI_AGENT`. Reuse the same id across turns to keep context.

Questions that exercise each tool:

| Ask | Should call |
|---|---|
| *What were Engineering expenses in August 2025?* | SQL |
| *What does the reconciliation policy require?* | RAG |
| *Show the expense trend for Engineering* | TREND |
| *Forecast Sales expenses for the next 3 periods* | FORECAST |
| *Any unusual spending in our GL data?* | ANOMALY |
| *Give me moving averages and standard deviation* | PYTHON |

**Confirm the tool actually fired** rather than trusting a plausible answer:

```sql
SELECT tool_name, agent_name, start_date, SUBSTR(tool_output,1,200)
FROM   user_ai_agent_tool_history
ORDER  BY start_date DESC FETCH FIRST 10 ROWS ONLY;
```

### Testing it repeatably

Spot checks stop scaling once you start changing instructions and models.
`eval/` holds a small evaluation harness: a fixed set of cases, a scorer, and a
record of every run in the database.

```bash
cd eval
cp eval.ini.template eval.ini      # no passwords in this file
python run_eval.py
```

```
[PASS ] sql-engineering-aug2025              5.6s  ACME_SQL_TOOL
[PASS ] refusal-empty-department             6.2s  ACME_SQL_TOOL
[KNOWN] route-anomaly-then-policy           10.9s  ACME_SQL_TOOL, ACME_RAG_TOOL, …
         → ACME_FORECAST_TOOL fired and should not have

15/16 passed   (1 known failure, 0 unexpected)
```

It asserts more than the wording of an answer. Expected figures are computed by
SQL at run time, so they cannot go stale. Tool attribution is exact, using the
`team_exec_id` that `RUN_TEAM` returns. A question about a department with no
rows must be refused rather than answered. Known defects are declared, so one
you have accepted cannot hide one you have not. See `eval/README.md`.

---

## When something fails

Work bottom-up. Each layer's errors impersonate a different layer's problems.

1. **`USER_ERRORS`** — is the object valid? A PL/SQL object with a compile error is
   still created, just `INVALID`, and many drivers report that as success. An
   invalid function surfaces at the agent layer as "procedure not found", which
   reads like a missing grant.
2. **Direct call** — `SELECT your_function(...) FROM dual` bypasses the agent and
   rules out registration, routing, and the reasoning loop.
3. **`USER_AI_AGENT_TOOL_HISTORY`** — what the agent actually sent, and what came
   back. Right tool, right parameters, wrong answer is a task-instruction problem,
   which is a different fix entirely.

---

## A chat interface

The scripts build and test the agent without any UI. If you want one, Oracle's
[Ask Oracle Select AI Chatbot](https://github.com/oracle-devrel/oracle-autonomous-database-samples/tree/main/apex/Ask-Oracle-Select-AI-Chatbot)
is an APEX application that works against Select AI profiles and agent teams. It
needs `grant execute on dbms_cloud_ai_agent` to the app's parsing schema.

---

## License

No license is granted yet — add one before relying on this in your own work.
