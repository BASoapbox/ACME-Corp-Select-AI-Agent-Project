/*
================================================================================
  FILE:    SA_03_quick_updates.sql
  PURPOSE: Standalone scripts for common operational changes to the
           Select AI Agent — run individual sections as needed.
  RUN AS:  ^agent_schema. (unless stated otherwise)
  SCHEMA:  ^agent_schema.
  PROJECT: ACME AI — Select AI Agent (App 103 Page 4)
================================================================================

  SECTIONS:
    1.  Change the LLM model
    2.  Update agent role
    3.  Update task instruction (tool routing)
    4.  Update OML password (when ^agent_schema. password changes)
    5.  Add a new table to the NL2SQL profile
    6.  Update table or column comments
    7.  Rebuild agent stack only (preserves profiles, tools, vector index)
    8.  Refresh vector index (when new PDFs added to Object Storage)
    9.  Check error log (EPE token failures etc.)
    10. Verify current state of all objects
    11. Manual OML token set (fallback if auto-refresh fails)
    12. GL data reload (truncate and reload from SA_00)

  NOTE: Each section is independent — run only what you need.
        All updates take effect on the next RUN_TEAM call.

================================================================================
*/

@SA_ENV

-- Section 4 needs the NEW schema password. Prompted, never stored.
-- Press Enter to skip if you are not running Section 4.
ACCEPT new_pw CHAR PROMPT 'New password for ^agent_schema. (Enter to skip): ' HIDE


-- ============================================================================
-- SECTION 1: CHANGE THE LLM MODEL
-- ============================================================================
-- DBMS_CLOUD_AI.UPDATE_PROFILE does not exist. The supported way to change a
-- profile attribute is DROP + CREATE. Recreating under the same name keeps
-- every tool that references it valid -- tools resolve the profile by name.
--
-- Set chat_model in SA_ENV.sql first; this section rebuilds both profiles
-- from that value, so they cannot drift apart.
--
-- List models actually available in your region before choosing:
--   oci generative-ai model-collection list-models -c <compartment-ocid>
--
-- NOTE: do NOT add a "region" attribute. On 26ai it makes the database build
-- a malformed inference endpoint and every call fails with ORA-20404.
-- ============================================================================

-- 1a. NL2SQL profile
BEGIN DBMS_CLOUD_AI.DROP_PROFILE('^nl2sql_profile.', force => TRUE);
EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN
    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => '^nl2sql_profile.',
        attributes   => '{
            "provider"           : "oci",
            "credential_name"    : "OCI$RESOURCE_PRINCIPAL",
            "oci_compartment_id" : "^compartment_ocid.",
            "model"              : "^chat_model.",
            "comments"           : "true",
            "constraints"        : "true",
            "conversation"       : "true",
            "temperature"        : ^nl2sql_temp.,
            "max_tokens"         : ^max_tokens.,
            "object_list"        : [
                {"owner": "^agent_schema.", "name": "ACME_GL_TRANSACTIONS"},
                {"owner": "^agent_schema.", "name": "ACME_CHART_OF_ACCOUNTS"},
                {"owner": "^agent_schema.", "name": "ACME_DEPARTMENTS"},
                {"owner": "^agent_schema.", "name": "ACME_PERIOD_CLOSE"},
                {"owner": "^agent_schema.", "name": "ACME_CHAT_SESSIONS"},
                {"owner": "^agent_schema.", "name": "ACME_CHAT_MESSAGES"}
            ]
        }'
    );
END;
/

-- 1b. RAG profile
-- The vector index references this profile by name, so recreating it under the
-- same name leaves the index intact. Do not drop the index here.
BEGIN DBMS_CLOUD_AI.DROP_PROFILE('^rag_profile.', force => TRUE);
EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN
    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => '^rag_profile.',
        attributes   => '{
            "provider"           : "oci",
            "credential_name"    : "OCI$RESOURCE_PRINCIPAL",
            "oci_compartment_id" : "^compartment_ocid.",
            "model"              : "^chat_model.",
            "embedding_model"    : "^embed_model.",
            "vector_index_name"  : "^vector_index.",
            "temperature"        : ^rag_temp.,
            "max_tokens"         : ^max_tokens.
        }'
    );
END;
/

-- Verify
SELECT profile_name, attribute_value AS model
FROM   user_cloud_ai_profile_attributes
WHERE  attribute_name = 'model' ORDER BY profile_name;

-- ============================================================================
-- SECTION 2: UPDATE AGENT ROLE
-- ============================================================================
-- DBMS_CLOUD_AI_AGENT.UPDATE_AGENT does not exist -- DROP + CREATE instead.
--
-- The agent cannot be dropped while a team references it, so the whole
-- team -> task -> agent chain comes down and goes back up. Task and team
-- definitions are unchanged; only the role text below differs.
--
-- DROP_TEAM leaves an orphan AGENT$<team> profile behind. It is not
-- documented anywhere, and the next CREATE_TEAM fails if you skip it.
-- ============================================================================

BEGIN DBMS_CLOUD_AI_AGENT.DROP_TEAM('^team_name.');
EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI.DROP_PROFILE('AGENT$^team_name.', force => TRUE);
EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI_AGENT.DROP_TASK('^task_name.');
EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI_AGENT.DROP_AGENT('^agent_name.');
EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- Edit the role text here, then run the whole section.
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_AGENT(
        agent_name => '^agent_name.',
        attributes => '{
            "profile_name"      : "^nl2sql_profile.",
            "enable_human_tool" : "False",
            "role"              : "You are an experienced ACME Corp financial analyst with 6 tools available. Use tools as follows: SQL tool for direct data queries against live GL tables; RAG tool for policy, procedure, and compliance document questions; TREND tool for period-over-period growth rate and direction analysis; FORECAST tool for linear regression projections of future expenses; ANOMALY tool for threshold-based detection of unusual spending periods; PYTHON tool for advanced statistical analysis including mean, standard deviation, moving averages, and peak period identification. Only report data returned by tools. Never invent or estimate figures.",
            "tools"             : ["^sql_tool.","^rag_tool.","ACME_TREND_TOOL","ACME_FORECAST_TOOL","ACME_ANOMALY_TOOL","ACME_PYTHON_TOOL"]
        }'
    );
END;
/
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TASK(
        task_name  => '^task_name.',
        attributes => '{"instruction":"Answer ACME Corp financial questions using only data returned by tools. Route as follows: for direct data lookups (totals, balances, period data, counts) use SQL tool; for policy, procedure or compliance questions use RAG tool; for period-over-period trend or growth rate analysis use TREND tool; for forecasting future periods using linear regression use FORECAST tool; for detecting unusual or anomalous spending use ANOMALY tool; for advanced statistical analysis such as moving averages, standard deviation, peak period identification, or when the user explicitly asks for Python-powered analysis use PYTHON tool. If a tool returns no data say so clearly. Never invent figures."}'
    );
END;
/
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TEAM(
        team_name  => '^team_name.',
        attributes => '{"agents":[{"name":"^agent_name.","task":"^task_name."}],"process":"sequential"}'
    );
END;
/

-- Verify
SELECT attribute_name, SUBSTR(attribute_value,1,120) AS value_preview
FROM   user_ai_agent_attributes
WHERE  agent_name = '^agent_name.' AND attribute_name = 'role';

-- ============================================================================
-- SECTION 3: UPDATE TASK INSTRUCTION (TOOL ROUTING)
-- ============================================================================
-- DBMS_CLOUD_AI_AGENT.UPDATE_TASK does not exist -- DROP + CREATE instead.
--
-- Lighter than Section 2: the agent survives. Only the team (which references
-- the task) and the task itself are rebuilt. Remember the orphan AGENT$ profile.
--
-- The task instruction is the routing brain. Be specific -- vague instructions
-- send everything to the SQL tool.
-- ============================================================================

BEGIN DBMS_CLOUD_AI_AGENT.DROP_TEAM('^team_name.');
EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI.DROP_PROFILE('AGENT$^team_name.', force => TRUE);
EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI_AGENT.DROP_TASK('^task_name.');
EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- Edit the instruction here, then run the whole section.
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TASK(
        task_name  => '^task_name.',
        attributes => '{"instruction":"Answer ACME Corp financial questions using only data returned by tools. Route as follows: for direct data lookups (totals, balances, period data, counts) use SQL tool; for policy, procedure or compliance questions use RAG tool; for period-over-period trend or growth rate analysis use TREND tool; for forecasting future periods using linear regression use FORECAST tool; for detecting unusual or anomalous spending use ANOMALY tool; for advanced statistical analysis such as moving averages, standard deviation, peak period identification, or when the user explicitly asks for Python-powered analysis use PYTHON tool. If a tool returns no data say so clearly. Never invent figures."}'
    );
END;
/
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TEAM(
        team_name  => '^team_name.',
        attributes => '{"agents":[{"name":"^agent_name.","task":"^task_name."}],"process":"sequential"}'
    );
END;
/

-- Verify
SELECT attribute_name, SUBSTR(attribute_value,1,200) AS instruction_preview
FROM   user_ai_agent_task_attributes
WHERE  task_name = '^task_name.' AND attribute_name = 'instruction';

-- ============================================================================
-- SECTION 4: UPDATE OML PASSWORD (when ^agent_schema. password changes)
-- ============================================================================
-- The ^oml_credential. credential stores the ^agent_schema. password for OML token
-- auto-refresh. Run this block whenever the ^agent_schema. DB password is changed.
-- ============================================================================

BEGIN
    BEGIN
        DBMS_CLOUD.DELETE_CREDENTIAL(credential_name => '^oml_credential.');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => '^oml_credential.',
        username        => '^agent_schema.',
        password        => '^new_pw.'
    );
END;
/

-- Test that token refresh works with new password
SELECT acme_python_expense_analysis('Engineering', 30) AS test_result FROM dual;
-- Expected: JSON result without error — confirms new password works

-- ============================================================================
-- SECTION 5: ADD A TABLE TO THE NL2SQL PROFILE
-- ============================================================================
-- DBMS_CLOUD_AI.UPDATE_PROFILE does not exist -- DROP + CREATE instead.
-- There is no append-only option either way: object_list is replaced whole,
-- so list every table you want the SQL tool to see, not just the new one.
--
-- Tools reference the profile by name, so recreating it under the same name
-- leaves ^sql_tool. valid. The agent does not need rebuilding.
--
-- Grants matter as much as this list: NL2SQL ignores privileges received
-- through a role, so each table needs a direct GRANT SELECT to the schema.
-- ============================================================================

BEGIN DBMS_CLOUD_AI.DROP_PROFILE('^nl2sql_profile.', force => TRUE);
EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN
    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => '^nl2sql_profile.',
        attributes   => '{
            "provider"           : "oci",
            "credential_name"    : "OCI$RESOURCE_PRINCIPAL",
            "oci_compartment_id" : "^compartment_ocid.",
            "model"              : "^chat_model.",
            "comments"           : "true",
            "constraints"        : "true",
            "conversation"       : "true",
            "temperature"        : ^nl2sql_temp.,
            "max_tokens"         : ^max_tokens.,
            "object_list"        : [
                {"owner": "^agent_schema.", "name": "ACME_GL_TRANSACTIONS"},
                {"owner": "^agent_schema.", "name": "ACME_CHART_OF_ACCOUNTS"},
                {"owner": "^agent_schema.", "name": "ACME_DEPARTMENTS"},
                {"owner": "^agent_schema.", "name": "ACME_PERIOD_CLOSE"},
                {"owner": "^agent_schema.", "name": "ACME_CHAT_SESSIONS"},
                {"owner": "^agent_schema.", "name": "ACME_CHAT_MESSAGES"}
            ]
        }'
    );
END;
/

-- Verify
SELECT attribute_value AS object_list
FROM   user_cloud_ai_profile_attributes
WHERE  profile_name = '^nl2sql_profile.' AND attribute_name = 'object_list';

-- ============================================================================
-- SECTION 6: UPDATE TABLE OR COLUMN COMMENTS
-- ============================================================================
-- Run individual COMMENT statements as needed — no profile rebuild required.
-- Changes are picked up automatically on the next SQL tool call.

-- Update period_name comment (format-driven — no date ranges)
COMMENT ON COLUMN acme_gl_transactions.period_name IS
    'Accounting period in format MON-YYYY e.g. JAN-2025, FEB-2025, MAR-2025. Always use this exact format in WHERE clauses. Q1=JAN/FEB/MAR, Q2=APR/MAY/JUN, Q3=JUL/AUG/SEP, Q4=OCT/NOV/DEC. Query the actual data to determine which periods exist — do not assume a fixed range.';

-- Update period close table comment (if status values change)
COMMENT ON TABLE acme_period_close IS
    'ACME Corp period close task tracking. Use for queries about month-end close status, tasks, and assignments. Status values: OPEN, IN_PROGRESS, COMPLETE.';

-- Add a comment to a new table
-- COMMENT ON TABLE acme_new_table IS 'Description for the LLM...';

-- Verify comments are in place
SELECT table_name, comments
FROM   user_tab_comments
WHERE  table_name LIKE 'ACME_%'
ORDER  BY table_name;

SELECT table_name, column_name, comments
FROM   user_col_comments
WHERE  table_name = 'ACME_GL_TRANSACTIONS'
AND    comments IS NOT NULL
ORDER  BY column_name;

-- ============================================================================
-- SECTION 7: REBUILD AGENT STACK ONLY
-- ============================================================================
-- Use when you want to change the agent role, task instruction, or tool list
-- without touching profiles, vector index, or custom functions.
-- ============================================================================

BEGIN DBMS_CLOUD_AI_AGENT.DROP_TEAM('ACME_ANALYST_TEAM');               EXCEPTION WHEN OTHERS THEN NULL; END; /
BEGIN DBMS_CLOUD_AI.DROP_PROFILE('AGENT$ACME_ANALYST_TEAM', force=>TRUE); EXCEPTION WHEN OTHERS THEN NULL; END; /
BEGIN DBMS_CLOUD_AI_AGENT.DROP_TASK('ACME_ANALYST_TASK');               EXCEPTION WHEN OTHERS THEN NULL; END; /
BEGIN DBMS_CLOUD_AI_AGENT.DROP_AGENT('ACME_ANALYST');                   EXCEPTION WHEN OTHERS THEN NULL; END; /

BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_AGENT(
        agent_name  => 'ACME_ANALYST',
        attributes  => '{
            "profile_name"      : "ACME_NL2SQL_PROFILE",
            "role"              : "You are an experienced ACME Corp financial analyst with 6 tools available. Use tools as follows: SQL tool for direct data queries against live GL tables; RAG tool for policy, procedure, and compliance document questions; TREND tool for period-over-period growth rate and direction analysis; FORECAST tool for linear regression projections of future expenses; ANOMALY tool for threshold-based detection of unusual spending periods; PYTHON tool for advanced statistical analysis including mean, standard deviation, moving averages, and peak period identification. Only report data returned by tools. Never invent or estimate figures.",
            "enable_human_tool" : "False",
            "tools"             : [
                "ACME_SQL_TOOL",
                "ACME_RAG_TOOL",
                "ACME_TREND_TOOL",
                "ACME_FORECAST_TOOL",
                "ACME_ANOMALY_TOOL",
                "ACME_PYTHON_TOOL"
            ]
        }',
        description => 'ACME Corp AI Financial Analyst — 6 tools including Python ML'
    );
END;
/

BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TASK(
        task_name   => 'ACME_ANALYST_TASK',
        attributes  => '{
            "instruction" : "Answer ACME Corp financial questions using only data returned by tools. Route as follows: for direct data lookups use SQL tool; for policy or compliance questions use RAG tool; for period-over-period trend or growth rate analysis use TREND tool; for forecasting future periods use FORECAST tool; for basic anomaly or outlier detection use ANOMALY tool; for advanced statistical analysis such as moving averages, standard deviation, or peak period identification use PYTHON tool. Never invent figures."
        }',
        description => 'ACME Corp financial analysis with 6-tool ML routing'
    );
END;
/

BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TEAM(
        team_name   => 'ACME_ANALYST_TEAM',
        attributes  => '{
            "agents"  : [{"name": "ACME_ANALYST", "task": "ACME_ANALYST_TASK"}],
            "process" : "sequential"
        }',
        description => 'ACME Corp AI Assistant Team — 6 tools including Python ML'
    );
END;
/

SELECT agent_name,      status FROM user_ai_agents      ORDER BY agent_name;
SELECT task_name,       status FROM user_ai_agent_tasks ORDER BY task_name;
SELECT agent_team_name, status FROM user_ai_agent_teams ORDER BY agent_team_name;

-- ============================================================================
-- SECTION 8: REFRESH VECTOR INDEX
-- ============================================================================
-- Run when new PDFs are added to the ^rag_bucket. Object Storage bucket.
-- Drops and rebuilds ACME_VECTOR_INDEX + ^vector_index.$VECTAB from scratch.
-- The RAG profile does not need to be recreated.
-- ============================================================================

BEGIN
    DBMS_CLOUD_AI.DROP_VECTOR_INDEX(index_name => 'ACME_VECTOR_INDEX', force => TRUE);
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

BEGIN
    DBMS_CLOUD_AI.CREATE_VECTOR_INDEX(
        index_name => 'ACME_VECTOR_INDEX',
        attributes => '{
            "vector_db_provider"             : "oracle",
            "location"                       : "^rag_location_url.",
            "object_storage_credential_name" : "OCI$RESOURCE_PRINCIPAL",
            "profile_name"                   : "ACME_RAG_PROFILE",
            "chunk_size"                     : 1024,
            "chunk_overlap"                  : 128
        }'
    );
END;
/

SELECT index_name, status FROM user_cloud_vector_indexes WHERE index_name = 'ACME_VECTOR_INDEX';
SELECT COUNT(*) AS chunk_count FROM ^vector_index.$VECTAB;

-- ============================================================================
-- SECTION 9: CHECK ERROR LOG
-- ============================================================================
-- ACME_ERROR_LOG captures OML token refresh failures from the Python wrapper.
-- Check this if ACME_PYTHON_TOOL is returning EPE auth errors.
-- ============================================================================

-- Recent errors
SELECT log_id, error_date, error_source, error_msg
FROM   acme_error_log
ORDER  BY error_date DESC
FETCH  FIRST 20 ROWS ONLY;

-- Clear the log (optional — only after reviewing)
-- TRUNCATE TABLE acme_error_log;

-- ============================================================================
-- SECTION 10: VERIFY CURRENT STATE OF ALL OBJECTS
-- ============================================================================

-- Profiles
SELECT profile_name, status FROM user_cloud_ai_profiles ORDER BY profile_name;

-- Vector index
SELECT index_name, status FROM user_cloud_vector_indexes WHERE index_name = 'ACME_VECTOR_INDEX';

-- All 6 tools
SELECT tool_name, status FROM user_ai_agent_tools ORDER BY tool_name;

-- PL/SQL functions
SELECT object_name, object_type, status FROM user_objects
WHERE  object_name IN ('ACME_TREND_ANALYSIS','ACME_EXPENSE_FORECAST',
                       'ACME_ANOMALY_DETECT','ACME_PYTHON_EXPENSE_ANALYSIS')
ORDER  BY object_name;

-- Python script
SELECT name, cdate FROM user_pyq_scripts WHERE name = 'acme_py_expense_stats';

-- OML credential
SELECT credential_name, username, enabled FROM user_credentials
WHERE  credential_name = '^oml_credential.';

-- Agent stack
SELECT agent_name,      status FROM user_ai_agents      ORDER BY agent_name;
SELECT task_name,       status FROM user_ai_agent_tasks ORDER BY task_name;
SELECT agent_team_name, status FROM user_ai_agent_teams ORDER BY agent_team_name;

-- Agent role (current value)
SELECT attribute_name, SUBSTR(attribute_value,1,300) AS value_preview
FROM   user_ai_agent_attributes
WHERE  agent_name = 'ACME_ANALYST'
ORDER  BY attribute_name;

-- Current model in each profile
SELECT profile_name, attribute_name, attribute_value
FROM   user_cloud_ai_profile_attributes
WHERE  profile_name   IN ('ACME_NL2SQL_PROFILE','ACME_RAG_PROFILE')
AND    attribute_name = 'model'
ORDER  BY profile_name;

-- Recent tool invocations
SELECT tool_name, agent_name, start_date,
       SUBSTR(tool_output,1,100) AS output_preview
FROM   user_ai_agent_tool_history
ORDER  BY start_date DESC
FETCH  FIRST 10 ROWS ONLY;

-- ============================================================================
-- SECTION 11: MANUAL OML TOKEN SET (fallback only)
-- ============================================================================
-- The wrapper function auto-refreshes the token on every call (Section 8 of
-- SA_02). This section is a fallback only — use it if:
--   a) You see OML auth errors and want to test the token directly
--   b) ^oml_credential. is not yet set up and you need a quick fix
--
-- STEP A: Get a token from your terminal:
/*
  curl -X POST \
    --header 'Content-Type: application/json' \
    -d '{"grant_type":"password","username":"^agent_schema.","password":"<your-schema-password>"}' \
    "^oml_base_url./omlusers/api/oauth2/v1/token"
*/
--
-- STEP B: Paste the accessToken value below and run as ^agent_schema.. Then run the test query to confirm it works.
-- ============================================================================

EXEC pyqSetAuthToken('<paste-the-accessToken-value-from-STEP-A>');
SELECT pyqIsTokenSet() AS token_is_set FROM dual;

-- ============================================================================
-- SECTION 12: GL DATA RELOAD
-- ============================================================================
-- Truncates ACME_GL_TRANSACTIONS and reloads from scratch.
-- Use when data is inconsistent or you want a clean state.
-- Reference data (COA, departments, period_close) is NOT touched.
-- Run SA_00_DDL_DML.sql Sections 6-10 after this to reload the data.
-- ============================================================================

TRUNCATE TABLE acme_gl_transactions;

-- Verify empty
SELECT COUNT(*) AS row_count FROM acme_gl_transactions;
-- Expected: 0

-- Now run Sections 6-10 of SA_00_DDL_DML.sql to reload

-- ============================================================================
-- END OF FILE: SA_03_quick_updates.sql
-- ============================================================================
