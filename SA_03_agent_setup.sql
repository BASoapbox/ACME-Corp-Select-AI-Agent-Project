/*
================================================================================
  FILE:    SA_02_ACME_CORP_setup.sql
  PURPOSE: Complete Select AI Agent setup — profiles, vector index,
           custom tools, Python EPE, and agent stack.
           Does NOT create tables or load data (see SA_00_DDL_DML.sql).
  RUN AS:  ^agent_schema.
  SCHEMA:  ^agent_schema.
  PROJECT: ACME AI — Select AI Agent (App 103 Page 4)
  REGION:  ^region.  |  compartment: see SA_ENV.sql
================================================================================

  PRE-REQUISITES:
    1. SA_01_ADMIN_setup.sql run as ADMIN
    2. SA_00_DDL_DML.sql run as ^agent_schema. (tables + data already exist)

  REPLACE BEFORE RUNNING:
    ^compartment_ocid.  — compartment OCID (see SA_ENV.sql)
    ^oml_base_url.      — ADW OML endpoint e.g.
                               https://xxxx-yourdbname.^oml_root_domain.
    ^schema_pw. — ^agent_schema. database password

  CHANGES FROM PREVIOUS VERSION:
    - Tables and data moved to SA_00_DDL_DML.sql (this file starts at profiles)
    - period_name comment is now format-driven, not range-driven
    - NL2SQL profile object_list includes ACME_CHAT_SESSIONS and ACME_CHAT_MESSAGES
    - Agent role updated to reference all 6 tools explicitly
    - OML token refresh is now automated inside acme_python_expense_analysis()
      (Option 2) — ^oml_credential. credential stores the password; the wrapper
      fetches a fresh token on every call — no manual pyqSetAuthToken needed
    - ACME_ERROR_LOG table used to log token refresh failures silently

  SECTIONS:
    1.  Table and column comments (NL2SQL hallucination guard)
    2.  OML credential setup (one-time — enables auto token refresh)
    3.  Create NL2SQL profile (ACME_NL2SQL_PROFILE)
    4.  Create RAG profile (ACME_RAG_PROFILE)
    5.  Create vector index (ACME_VECTOR_INDEX)
    6.  PL/SQL custom tool functions (TREND, FORECAST, ANOMALY)
    7.  Store Python function in OML4Py repository
    8.  PL/SQL wrapper with auto token refresh (ACME_PYTHON_EXPENSE_ANALYSIS)
    9.  Register all 6 tools
    10. Build agent stack (agent, task, team)
    11. Verify all objects
    12. End-to-end tests

================================================================================
*/

@SA_ENV

WHENEVER SQLERROR CONTINUE

-- The Python tool needs the schema password to refresh its OML token.
-- Prompted here, never stored. Press Enter to skip if you are not using it.
ACCEPT schema_pw CHAR PROMPT 'Password for ^agent_schema. (Enter to skip Python tool): ' HIDE


-- ============================================================================
-- SECTION 1: TABLE AND COLUMN COMMENTS
-- ============================================================================
-- These comments are read by the LLM when "comments":"true" is set in the
-- NL2SQL profile. They are the most effective mechanism to prevent the LLM
-- from inventing column names, table names, or value formats.
--
-- NOTE: period_name comment is format-driven, not range-driven.
-- Do not hardcode date ranges here — they go stale as data is added.
-- ============================================================================

-- Table comments
COMMENT ON TABLE acme_gl_transactions IS
    'ACME Corp General Ledger transactions. Always use this exact table name: ACME_GL_TRANSACTIONS. Contains all financial postings including expenses. Join to ACME_DEPARTMENTS on DEPARTMENT_CODE and ACME_CHART_OF_ACCOUNTS on ACCOUNT_CODE.';

COMMENT ON TABLE acme_departments IS
    'ACME Corp department master. Join to ACME_GL_TRANSACTIONS on DEPARTMENT_CODE to get department names. All valid department codes and names are in this table.';

COMMENT ON TABLE acme_chart_of_accounts IS
    'ACME Corp chart of accounts. Join to ACME_GL_TRANSACTIONS on ACCOUNT_CODE to get account descriptions and types.';

COMMENT ON TABLE acme_period_close IS
    'ACME Corp period close task tracking. Use for queries about month-end close status, tasks, and assignments. Status values: OPEN, IN_PROGRESS, COMPLETE.';

COMMENT ON TABLE acme_chat_sessions IS
    'ACME Corp AI chat session registry. Each row represents one conversation on APEX Page 4. Join to ACME_CHAT_MESSAGES on SESSION_ID to retrieve message history.';

COMMENT ON TABLE acme_chat_messages IS
    'ACME Corp AI chat message history. Each row is one message in a conversation. ROLE is either USER or ASSISTANT. Join to ACME_CHAT_SESSIONS on SESSION_ID.';

-- Column comments for acme_gl_transactions
COMMENT ON COLUMN acme_gl_transactions.period_name IS
    'Accounting period in format MON-YYYY e.g. JAN-2025, FEB-2025, MAR-2025. Always use this exact format in WHERE clauses. Q1=JAN/FEB/MAR, Q2=APR/MAY/JUN, Q3=JUL/AUG/SEP, Q4=OCT/NOV/DEC. Query the actual data to determine which periods exist — do not assume a fixed range.';

COMMENT ON COLUMN acme_gl_transactions.account_type IS
    'Type of transaction. Valid values: ASSET, LIABILITY, EXPENSE, REVENUE, EQUITY. Use EXPENSE to filter for cost and spending queries.';

COMMENT ON COLUMN acme_gl_transactions.department_code IS
    'Department code. Valid values: 100=Corporate, 200=Europe HQ, 410=Finance, 420=Engineering, 430=Sales, 440=Operations. No other departments exist.';

COMMENT ON COLUMN acme_gl_transactions.debit_amount IS
    'Amount debited. For EXPENSE account_type this represents actual spending. Sum this column for total expenses.';

COMMENT ON COLUMN acme_gl_transactions.transaction_date IS
    'Date the transaction was posted. Set to the first day of each accounting period e.g. 01-JAN-2025 for JAN-2025.';

COMMENT ON COLUMN acme_period_close.status IS
    'Task status. Valid values: OPEN (not started), IN_PROGRESS (underway), COMPLETE (finished). Use to filter for outstanding or completed close tasks.';

-- ============================================================================
-- SECTION 2: OML CREDENTIAL SETUP (one-time, enables auto token refresh)
-- ============================================================================
-- Stores the ^agent_schema. password securely so the Python wrapper function can
-- auto-refresh the OML auth token on every call (Option 2 token strategy).
-- This eliminates the need to manually run pyqSetAuthToken every 60 minutes.
--
-- Replace ^schema_pw. with the actual ^agent_schema. DB password.
-- If the password changes, re-run this block to update the credential.
-- ============================================================================

BEGIN
    -- Drop if exists (safe re-run)
    BEGIN
        DBMS_CLOUD.DROP_CREDENTIAL(credential_name => '^oml_credential.');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    DBMS_CLOUD.CREATE_CREDENTIAL(
        credential_name => '^oml_credential.',
        username        => '^agent_schema.',
        password        => '^schema_pw.'
    );
END;
/

-- Verify credential exists
SELECT credential_name, username, enabled
FROM   user_credentials
WHERE  credential_name = '^oml_credential.';
-- Expected: ^oml_credential. | ^agent_schema. | TRUE

-- ============================================================================
-- SECTION 3: CREATE NL2SQL PROFILE (ACME_NL2SQL_PROFILE)
-- ============================================================================
-- Key attributes:
--   oci_compartment_id  REQUIRED — without it SQL tool fails ORA-20052
--   comments: true      LLM reads table/column comments set in Section 1
--   constraints: true   LLM reads FK constraints — reduces hallucination
--   conversation: true  Maintains multi-turn context across agent calls
--   object_list         Includes chat tables so agent can query history
-- ============================================================================

BEGIN
    DBMS_CLOUD_AI.DROP_PROFILE(profile_name => 'ACME_NL2SQL_PROFILE', force => TRUE);
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

BEGIN
    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => 'ACME_NL2SQL_PROFILE',
        attributes   => '{
            "provider"           : "oci",
            "credential_name"    : "OCI$RESOURCE_PRINCIPAL",
            "oci_compartment_id" : "^compartment_ocid.",
            "model"              : "^chat_model.",
            "comments"           : "true",
            "constraints"        : "true",
            "conversation"       : "true",
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

-- Quick test — if this returns a row, NL2SQL profile is working
EXEC DBMS_CLOUD_AI.SET_PROFILE('^nl2sql_profile.');
SELECT AI how many expense transactions are there;

-- ============================================================================
-- SECTION 4: CREATE RAG PROFILE (ACME_RAG_PROFILE)
-- ============================================================================
-- Used by ACME_RAG_TOOL for semantic search over the PDF knowledge base.
-- The vector_index_name must match the index created in Section 5.
-- NOTE: RAG requires action: narrate — action: chat does NOT invoke vector search.
-- ============================================================================

BEGIN
    DBMS_CLOUD_AI.DROP_PROFILE(profile_name => 'ACME_RAG_PROFILE', force => TRUE);
EXCEPTION WHEN OTHERS THEN NULL;
END;
/

BEGIN
    DBMS_CLOUD_AI.CREATE_PROFILE(
        profile_name => 'ACME_RAG_PROFILE',
        attributes   => '{
            "provider"           : "oci",
            "credential_name"    : "OCI$RESOURCE_PRINCIPAL",
            "oci_compartment_id" : "^compartment_ocid.",
            "model"              : "^chat_model.",
            "embedding_model"    : "^embed_model.",
            "vector_index_name"  : "ACME_VECTOR_INDEX",
            "temperature"        : 0.2,
            "max_tokens"         : 3000
        }'
    );
END;
/

-- ============================================================================
-- SECTION 5: CREATE VECTOR INDEX (ACME_VECTOR_INDEX)
-- ============================================================================
-- Chunks and embeds 7 PDFs from Object Storage into ADW using Cohere.
-- Creates ^vector_index.$VECTAB table containing one chunk per source document.
-- IAM policy must allow ADW to read from Object Storage (see SA_01 Section 5).
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
-- Expected: ACME_VECTOR_INDEX | ACTIVE

SELECT COUNT(*) AS chunk_count FROM ^vector_index.$VECTAB;
-- Expected: ~14

-- ============================================================================
-- SECTION 6: PL/SQL CUSTOM TOOL FUNCTIONS
-- ============================================================================

-- ── 6.1 TREND ANALYSIS ───────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION acme_trend_analysis(
    p_department IN VARCHAR2 DEFAULT NULL,
    p_periods    IN NUMBER   DEFAULT 6
) RETURN CLOB IS
    v_result CLOB := '';
    v_sep    VARCHAR2(2) := '';
BEGIN
    v_result := '{"trend_analysis": {"department": "'
                || NVL(p_department,'ALL') || '", "periods": [';

    FOR r IN (
        SELECT t.period_name,
               d.department_name,
               SUM(t.debit_amount)                                        AS total_expense,
               LAG(SUM(t.debit_amount)) OVER (
                   PARTITION BY d.department_name ORDER BY t.period_name) AS prior_expense,
               ROUND(
                   (SUM(t.debit_amount) -
                    LAG(SUM(t.debit_amount)) OVER (
                        PARTITION BY d.department_name ORDER BY t.period_name))
                   / NULLIF(LAG(SUM(t.debit_amount)) OVER (
                        PARTITION BY d.department_name ORDER BY t.period_name),0) * 100
               ,2)                                                         AS growth_pct
        FROM   acme_gl_transactions t
        JOIN   acme_departments d ON d.department_code = t.department_code
        WHERE  t.account_type = 'EXPENSE'
        AND    (p_department IS NULL
                OR UPPER(d.department_name) LIKE UPPER('%'||p_department||'%'))
        GROUP  BY t.period_name, d.department_name
        ORDER  BY d.department_name, t.period_name DESC
        FETCH  FIRST p_periods ROWS ONLY
    ) LOOP
        v_result := v_result || v_sep ||
            '{"period":"'      || r.period_name     || '",'  ||
            '"department":"'   || r.department_name || '",'  ||
            '"expense":'       || ROUND(r.total_expense,2)   || ',' ||
            '"prior_expense":' || NVL(TO_CHAR(ROUND(r.prior_expense,2)),'null') || ',' ||
            '"growth_pct":'    || NVL(TO_CHAR(r.growth_pct),'null') || '}';
        v_sep := ',';
    END LOOP;

    v_result := v_result || ']}}';
    RETURN v_result;
END acme_trend_analysis;
/

-- ── 6.2 EXPENSE FORECAST ─────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION acme_expense_forecast(
    p_department     IN VARCHAR2 DEFAULT NULL,
    p_future_periods IN NUMBER   DEFAULT 3
) RETURN CLOB IS
    v_result     CLOB;
    v_n          NUMBER := 0;
    v_sum_x      NUMBER := 0;
    v_sum_y      NUMBER := 0;
    v_sum_xy     NUMBER := 0;
    v_sum_x2     NUMBER := 0;
    v_slope      NUMBER;
    v_intercept  NUMBER;
    v_sep        VARCHAR2(2) := '';
BEGIN
    SELECT COUNT(*), SUM(rn), SUM(total), SUM(rn*total), SUM(rn*rn)
    INTO   v_n, v_sum_x, v_sum_y, v_sum_xy, v_sum_x2
    FROM (
        SELECT ROW_NUMBER() OVER (ORDER BY period_name) AS rn,
               SUM(debit_amount)                        AS total
        FROM   acme_gl_transactions t
        JOIN   acme_departments d ON d.department_code = t.department_code
        WHERE  t.account_type = 'EXPENSE'
        AND    (p_department IS NULL
                OR UPPER(d.department_name) LIKE UPPER('%'||p_department||'%'))
        GROUP  BY period_name
    );

    IF v_n < 2 THEN
        RETURN '{"error": "Insufficient data. Need at least 2 periods."}';
    END IF;

    v_slope     := (v_n * v_sum_xy - v_sum_x * v_sum_y)
                   / NULLIF((v_n * v_sum_x2 - v_sum_x * v_sum_x), 0);
v_intercept := (v_sum_y - v_slope * v_sum_x) / v_n;

    v_result := '{"forecast": {'                                          ||
                '"department": "'        || NVL(p_department,'ALL') || '",' ||
                '"model": "linear_regression",'                           ||
                '"slope": '              || ROUND(v_slope,2)    || ','   ||
                '"intercept": '          || ROUND(v_intercept,2) || ','  ||
                '"historical_periods": ' || v_n                  || ','  ||
                '"projections": [';

    FOR i IN 1..p_future_periods LOOP
        v_result := v_result || v_sep ||
            '{"period_offset": '    || i || ',' ||
            '"label": "FORECAST+'   || i || '",' ||
            '"predicted_expense": ' || ROUND(v_slope*(v_n+i)+v_intercept,2) || '}';
        v_sep := ',';
    END LOOP;

    v_result := v_result || ']}}';
    RETURN v_result;
END acme_expense_forecast;
/

-- ── 6.3 ANOMALY DETECTION ────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION acme_anomaly_detect(
    p_threshold_pct IN NUMBER DEFAULT 20
) RETURN CLOB IS
    v_result CLOB;
    v_sep    VARCHAR2(2) := '';
    v_count  NUMBER := 0;
BEGIN
    v_result := '{"anomaly_detection": {"threshold_pct": '
                || p_threshold_pct || ',"anomalies": [';

    FOR r IN (
        WITH dept_stats AS (
            SELECT d.department_name, t.period_name,
                   SUM(t.debit_amount)                                AS period_expense,
                   AVG(SUM(t.debit_amount)) OVER (PARTITION BY d.department_name) AS avg_expense,
                   STDDEV(SUM(t.debit_amount)) OVER (PARTITION BY d.department_name) AS stddev_expense
            FROM   acme_gl_transactions t
            JOIN   acme_departments d ON d.department_code = t.department_code
            WHERE  t.account_type = 'EXPENSE'
            GROUP  BY d.department_name, t.period_name
        )
        SELECT department_name, period_name,
               ROUND(period_expense,2) AS expense,
               ROUND(avg_expense,2)    AS avg_expense,
               ROUND(stddev_expense,2) AS stddev_expense,
               ROUND((period_expense-avg_expense)/NULLIF(avg_expense,0)*100,2) AS deviation_pct
        FROM   dept_stats
        WHERE  ABS((period_expense-avg_expense)/NULLIF(avg_expense,0)*100) > p_threshold_pct
        ORDER  BY ABS(deviation_pct) DESC
    ) LOOP
        v_result := v_result || v_sep ||
            '{"department": "'  || r.department_name || '",' ||
            '"period": "'       || r.period_name     || '",' ||
            '"expense": '       || r.expense         || ','  ||
            '"avg_expense": '   || r.avg_expense     || ','  ||
            '"deviation_pct": ' || r.deviation_pct   || ',"flagged": true}';
        v_sep := ',';
        v_count := v_count + 1;
    END LOOP;

    IF v_count = 0 THEN
        v_result := v_result ||
            '{"message": "No anomalies above ' || p_threshold_pct || '% threshold"}';
    END IF;

    v_result := v_result || '], "total_anomalies": ' || v_count || '}}';
    RETURN v_result;
END acme_anomaly_detect;
/

SELECT object_name, status FROM user_objects
WHERE  object_name IN ('ACME_TREND_ANALYSIS','ACME_EXPENSE_FORECAST','ACME_ANOMALY_DETECT')
ORDER  BY object_name;
-- Expected: all 3 VALID

-- ============================================================================
-- SECTION 7: STORE PYTHON FUNCTION IN OML4Py REPOSITORY
-- ============================================================================

BEGIN
    BEGIN sys.pyqScriptDrop('acme_py_expense_stats', TRUE);
    EXCEPTION WHEN OTHERS THEN NULL; END;

    sys.pyqScriptCreate(
        'acme_py_expense_stats',
'def acme_py_expense_stats(**kwargs):
    import pandas as pd
    import numpy as np
    import json

    data_json  = kwargs.get("data_json", "[]")
    threshold  = float(kwargs.get("threshold_pct", 20))
    department = kwargs.get("department", "ALL")

    rows = json.loads(data_json)
    if not rows:
        result = {"error": "No expense data passed to Python function"}
        return pd.DataFrame({"RESULT": [json.dumps(result)]})

    df = pd.DataFrame(rows)
    df["TOTAL_EXPENSE"] = df["TOTAL_EXPENSE"].astype(float)

    summary = []
    for dept in df["DEPARTMENT_NAME"].unique():
        ddf    = df[df["DEPARTMENT_NAME"] == dept].copy().sort_values("PERIOD_NAME")
        vals   = ddf["TOTAL_EXPENSE"].values
        mean   = float(np.mean(vals))
        std    = float(np.std(vals))
        peak_i = int(np.argmax(vals))
        ma3    = [round(float(np.mean(vals[max(0,i-2):i+1])),2) for i in range(len(vals))]

        flags = []
        for _, row in ddf.iterrows():
            dev = abs(float(row["TOTAL_EXPENSE"]) - mean) / mean * 100 if mean else 0
            if dev > threshold:
                flags.append({"period": row["PERIOD_NAME"],
                              "expense": round(float(row["TOTAL_EXPENSE"]), 2),
                              "deviation": round(dev, 2)})

        summary.append({"department": dept,
                        "periods_analyzed": len(vals),
                        "mean_expense": round(mean, 2),
                        "std_dev": round(std, 2),
                        "min_expense": round(float(np.min(vals)), 2),
                        "max_expense": round(float(np.max(vals)), 2),
                        "peak_period": ddf.iloc[peak_i]["PERIOD_NAME"],
                        "moving_avg_3p": ma3,
                        "flagged_periods": flags,
                        "anomaly_threshold": threshold})

    result = {"python_expense_analysis": {"department_filter": department,
                                          "departments": summary}}
    return pd.DataFrame({"RESULT": [json.dumps(result)]})',
        FALSE, TRUE
    );
END;
/

SELECT name FROM user_pyq_scripts WHERE name = 'acme_py_expense_stats';
-- Expected: one row

-- ============================================================================
-- SECTION 8: PL/SQL WRAPPER WITH AUTO TOKEN REFRESH
-- ============================================================================
-- Token strategy: Option 2 — the wrapper fetches a fresh OML token on every
-- call using DBMS_CLOUD.SEND_REQUEST + the ^oml_credential. credential created
-- in Section 2. This eliminates manual pyqSetAuthToken() entirely.
--
-- Flow:
--   1. Retrieve stored password from ^oml_credential.
--   2. POST to OML token endpoint → extract accessToken
--   3. Call pyqSetAuthToken(v_token)
--   4. Query GL data → JSON string
--   5. Call pyqEval → Python → numpy stats
--
-- If token refresh fails: the error is logged to ACME_ERROR_LOG and the
-- function continues with whatever token is currently set. If no token is
-- set, pyqEval will return a clear EPE auth error.
--
-- Replace ^oml_base_url. with your ADW OML endpoint.
-- ============================================================================

-- Fetch a secret from OCI Vault using the database's own Resource Principal.
-- This removes the need to hardcode a password in PL/SQL: DBMS_CLOUD credentials
-- cannot be read back (by design), but the Vault REST API can be called directly.
-- Requires: allow any-user to read secret-bundles in compartment <c>
--           where request.principal.type = 'autonomousdatabase'
CREATE OR REPLACE FUNCTION acme_get_secret(p_secret_ocid IN VARCHAR2)
RETURN VARCHAR2 IS
    v_resp DBMS_CLOUD_TYPES.resp;
    v_b64  VARCHAR2(32767);
BEGIN
    v_resp := DBMS_CLOUD.SEND_REQUEST(
        credential_name => 'OCI$RESOURCE_PRINCIPAL',
        uri             => 'https://secrets.vaults.^region..oci.oraclecloud.com'
                        || '/20190301/secretbundles/' || p_secret_ocid,
        method          => 'GET');
    v_b64 := JSON_VALUE(DBMS_CLOUD.GET_RESPONSE_TEXT(v_resp),
                        '$.secretBundleContent.content');
    IF v_b64 IS NULL THEN RETURN NULL; END IF;
    RETURN UTL_RAW.CAST_TO_VARCHAR2(
               UTL_ENCODE.BASE64_DECODE(UTL_RAW.CAST_TO_RAW(v_b64)));
END acme_get_secret;
/

-- Error logging must be autonomous: a function called from a SQL statement
-- cannot perform DML directly (ORA-14551). Route it through this procedure.
CREATE OR REPLACE PROCEDURE acme_log_error(
    p_source IN VARCHAR2,
    p_msg    IN VARCHAR2,
    p_detail IN VARCHAR2 DEFAULT NULL
) IS
    PRAGMA AUTONOMOUS_TRANSACTION;
BEGIN
    INSERT INTO ^error_log_table.(error_source, error_msg, error_detail)
    VALUES(p_source, p_msg, p_detail);
    COMMIT;
END acme_log_error;
/

CREATE OR REPLACE FUNCTION acme_python_expense_analysis(
    p_department    IN VARCHAR2 DEFAULT NULL,
    p_threshold_pct IN NUMBER   DEFAULT 20
) RETURN CLOB IS
    v_result    CLOB;
    v_data      VARCHAR2(32767);
    v_par_lst   VARCHAR2(32767);
    v_token     VARCHAR2(32767);
    v_resp      CLOB;
    v_http_resp DBMS_CLOUD_TYPES.resp;
    v_pwd       VARCHAR2(500);
    v_errmsg    VARCHAR2(4000);
BEGIN
    -- Step 1: refresh the OML token -------------------------------------------
    BEGIN
        -- Oracle does not expose a stored DBMS_CLOUD credential's password back
        -- out through any view -- by design. This matches Oracle's own OML4Py
        -- token-refresh reference pattern, which supplies the password here.
        -- Fetched from OCI Vault at run time -- never stored in this script.
        v_pwd := acme_get_secret('^vault_secret_ocid.');

        v_http_resp := DBMS_CLOUD.SEND_REQUEST(
            credential_name => 'OCI$RESOURCE_PRINCIPAL',
            uri             => '^oml_base_url./omlusers/api/oauth2/v1/token',
            method          => 'POST',
            headers         => '{"Content-Type":"application/json"}',
            body            => UTL_RAW.CAST_TO_RAW(
                                   '{"grant_type":"password",'  ||
                                   '"username":"^agent_schema.",' ||
                                   '"password":"' || v_pwd || '"}'
                               )
        );

        -- SEND_REQUEST returns DBMS_CLOUD_TYPES.resp, not a string, and the
        -- body is NOT a .text attribute on it.
        v_resp  := DBMS_CLOUD.GET_RESPONSE_TEXT(v_http_resp);
        v_token := JSON_VALUE(v_resp, '$.accessToken');

        IF v_token IS NOT NULL THEN
            pyqSetAuthToken(v_token);
        ELSE
            v_errmsg := SUBSTR(v_resp, 1, 4000);
            acme_log_error('ACME_PYTHON_EXPENSE_ANALYSIS', 'OML token refresh returned null token', v_errmsg);
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            -- SQLERRM is PL/SQL-only; inside a static INSERT the SQL engine
            -- reads it as a column name (ORA-00984). Assign it first.
            v_errmsg := SQLERRM;
            acme_log_error('ACME_PYTHON_EXPENSE_ANALYSIS - token refresh', v_errmsg);
    END;

    -- Step 2: gather the data in PL/SQL ---------------------------------------
    SELECT CAST(JSON_ARRAYAGG(
               JSON_OBJECT('DEPARTMENT_NAME' VALUE d.department_name,
                           'PERIOD_NAME'     VALUE t.period_name,
                           'TOTAL_EXPENSE'   VALUE SUM(t.debit_amount))
               ORDER BY d.department_name, t.period_name) AS VARCHAR2(32767))
    INTO   v_data
    FROM   acme_gl_transactions t
    JOIN   acme_departments d ON d.department_code = t.department_code
    WHERE  t.account_type = 'EXPENSE'
    AND    (p_department IS NULL
            OR UPPER(d.department_name) LIKE UPPER('%'||p_department||'%'))
    GROUP  BY d.department_name, t.period_name;

    -- Step 3: hand it to Python ------------------------------------------------
    -- data_json MUST be a quoted string. Unquoted, pyqEval deserialises it and
    -- Python receives a list, so json.loads() fails.
    v_par_lst := '{"oml_service_level":"LOW"'            ||
                 ',"threshold_pct":' || p_threshold_pct  ||
                 ',"department":"'   || NVL(p_department,'ALL') || '"' ||
                 ',"data_json":"'    || REPLACE(v_data, '"', '\"') || '"' ||
                 '}';

    SELECT TO_CLOB(result) INTO v_result
    FROM   TABLE(pyqEval(par_lst  => v_par_lst,
                         out_fmt  => '{"RESULT": "VARCHAR2(32767)"}',
                         scr_name => 'acme_py_expense_stats'));
    RETURN v_result;

EXCEPTION
    WHEN OTHERS THEN
        RETURN '{"error": "Python EPE failed: '
               || REPLACE(SQLERRM, '"', '''') || '"}';
END acme_python_expense_analysis;
/

SELECT object_name, object_type, status FROM user_objects
WHERE  object_name = 'ACME_PYTHON_EXPENSE_ANALYSIS';
-- Expected: VALID

-- Standalone test (no manual pyqSetAuthToken needed — wrapper handles it)
SELECT acme_python_expense_analysis('Engineering', 30) AS result FROM dual;
-- Expected: JSON with mean=$63,055.56, std_dev=$42,667.61, peak=AUG-2025

-- ============================================================================
-- SECTION 9: REGISTER ALL 6 TOOLS
-- ============================================================================

BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('ACME_SQL_TOOL');      EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('ACME_RAG_TOOL');      EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('ACME_TREND_TOOL');    EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('ACME_FORECAST_TOOL'); EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('ACME_ANOMALY_TOOL');  EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI_AGENT.DROP_TOOL('ACME_PYTHON_TOOL');   EXCEPTION WHEN OTHERS THEN NULL; END;
/
-- 9.1 SQL Tool — profile_name inside tool_params; action:runsql required
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
        tool_name  => 'ACME_SQL_TOOL',
        attributes => '{
            "tool_type"   : "SQL",
            "tool_params" : {
                "profile_name" : "ACME_NL2SQL_PROFILE",
                "action"       : "runsql"
            }
        }'
    );
END;
/

-- 9.2 RAG Tool
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
        tool_name  => 'ACME_RAG_TOOL',
        attributes => '{
            "tool_type"   : "RAG",
            "tool_params" : {
                "profile_name" : "ACME_RAG_PROFILE"
            }
        }'
    );
END;
/

-- 9.3 Trend Tool
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
        tool_name   => 'ACME_TREND_TOOL',
        attributes  => '{
            "function"    : "ACME_TREND_ANALYSIS",
            "instruction" : "Use this tool to analyze expense trends over time for ACME Corp departments. Returns period-over-period expense changes and growth rates from the GL transactions table.",
            "tool_inputs" : [
                {"name":"P_DEPARTMENT","description":"Department name e.g. Finance, Engineering, Sales. Leave empty for all."},
                {"name":"P_PERIODS",   "description":"Number of historical periods to include. Default is 6."}
            ]
        }'
    );
END;
/

-- 9.4 Forecast Tool
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
        tool_name   => 'ACME_FORECAST_TOOL',
        attributes  => '{
            "function"    : "ACME_EXPENSE_FORECAST",
            "instruction" : "Use this tool to forecast future expenses for ACME Corp departments using linear regression on historical GL data. Returns predicted expense values for future accounting periods.",
            "tool_inputs" : [
                {"name":"P_DEPARTMENT",     "description":"Department name to forecast. Leave empty for all departments combined."},
                {"name":"P_FUTURE_PERIODS", "description":"Number of future periods to project. Default is 3."}
            ]
        }'
    );
END;
/

-- 9.5 Anomaly Tool
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
        tool_name   => 'ACME_ANOMALY_TOOL',
        attributes  => '{
            "function"    : "ACME_ANOMALY_DETECT",
            "instruction" : "Use this tool to detect unusual or anomalous spending patterns in ACME Corp GL transactions. Flags departments and periods where spending deviates significantly from their historical average.",
            "tool_inputs" : [
                {"name":"P_THRESHOLD_PCT","description":"Percentage deviation from average to flag as anomaly. Default 20. Use 10 for sensitive, 30 for less sensitive."}
            ]
        }'
    );
END;
/

-- 9.6 Python Tool
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TOOL(
        tool_name   => 'ACME_PYTHON_TOOL',
        attributes  => '{
            "function"    : "ACME_PYTHON_EXPENSE_ANALYSIS",
            "instruction" : "Use this tool for advanced statistical expense analysis powered by Python running inside the database via OML4Py Embedded Python Execution. Computes mean, standard deviation, min, max, peak spending period, and 3-period moving averages per department. Also flags periods that deviate significantly from the department average. Use when the user asks for statistical analysis, moving averages, standard deviation, or Python-powered analysis.",
            "tool_inputs" : [
                {"name":"P_DEPARTMENT",    "description":"Department name to analyze. Leave empty for all departments."},
                {"name":"P_THRESHOLD_PCT", "description":"Percentage deviation from mean to flag a period as unusual. Default is 20."}
            ]
        }'
    );
END;
/

SELECT tool_name, status FROM user_ai_agent_tools ORDER BY tool_name;
-- Expected: all 6 ENABLED

-- ============================================================================
-- SECTION 10: BUILD AGENT STACK
-- ============================================================================
-- Cleanup order: TEAM → orphan AGENT$ profile → TASK → AGENT
-- All tools, profiles, and vector index survive this sequence unchanged.

BEGIN DBMS_CLOUD_AI_AGENT.DROP_TEAM('ACME_ANALYST_TEAM');               EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI.DROP_PROFILE('AGENT$ACME_ANALYST_TEAM', force=>TRUE); EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI_AGENT.DROP_TASK('ACME_ANALYST_TASK');               EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI_AGENT.DROP_AGENT('ACME_ANALYST');                   EXCEPTION WHEN OTHERS THEN NULL; END;
/
-- 10.1 Agent — tools array must be explicitly listed
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

-- 10.2 Task
BEGIN
    DBMS_CLOUD_AI_AGENT.CREATE_TASK(
        task_name   => 'ACME_ANALYST_TASK',
        attributes  => '{
            "instruction" : "Answer ACME Corp financial questions using only data returned by tools. Route as follows: for direct data lookups (totals, balances, period data, counts) use SQL tool; for policy, procedure or compliance questions use RAG tool; for period-over-period trend or growth rate analysis use TREND tool; for forecasting future periods using linear regression use FORECAST tool; for detecting unusual or anomalous spending use ANOMALY tool; for advanced statistical analysis such as moving averages, standard deviation, peak period identification, or when the user explicitly asks for Python-powered analysis use PYTHON tool. If a tool returns no data say so clearly. Never invent figures."
        }',
        description => 'ACME Corp financial analysis with 6-tool ML routing'
    );
END;
/

-- 10.3 Team
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

-- ============================================================================
-- SECTION 11: VERIFY ALL OBJECTS
-- ============================================================================

-- 11.1 Profiles
SELECT profile_name, status FROM user_cloud_ai_profiles ORDER BY profile_name;

-- 11.2 Vector index
SELECT index_name, status FROM user_cloud_vector_indexes WHERE index_name = 'ACME_VECTOR_INDEX';

-- 11.3 All 6 tools
SELECT tool_name, status FROM user_ai_agent_tools ORDER BY tool_name;

-- 11.4 PL/SQL functions
SELECT object_name, status FROM user_objects
WHERE  object_name IN ('ACME_TREND_ANALYSIS','ACME_EXPENSE_FORECAST',
                       'ACME_ANOMALY_DETECT','ACME_PYTHON_EXPENSE_ANALYSIS')
ORDER  BY object_name;

-- 11.5 Python script
SELECT name FROM user_pyq_scripts WHERE name = 'acme_py_expense_stats';

-- 11.6 Agent stack
SELECT agent_name,      status FROM user_ai_agents      ORDER BY agent_name;
SELECT task_name,       status FROM user_ai_agent_tasks ORDER BY task_name;
SELECT agent_team_name, status FROM user_ai_agent_teams ORDER BY agent_team_name;

-- 11.7 OML credential
SELECT credential_name, username, enabled FROM user_credentials
WHERE  credential_name = '^oml_credential.';

-- ============================================================================
-- SECTION 12: END-TO-END TESTS
-- ============================================================================
-- conversation_id is required in params — omitting causes ORA-01400.

-- 12.1 SQL
DECLARE
    l_conv VARCHAR2(36);
    l_resp CLOB;
BEGIN
    l_conv := DBMS_CLOUD_AI.CREATE_CONVERSATION();
    l_resp := DBMS_CLOUD_AI_AGENT.RUN_TEAM(
        team_name   => 'ACME_ANALYST_TEAM',
        user_prompt => 'What were Engineering expenses in August 2025?',
        params      => '{"conversation_id":"' || l_conv || '"}'
    );
    DBMS_OUTPUT.PUT_LINE(l_resp);
END;
/

-- 12.2 RAG
DECLARE
    l_conv VARCHAR2(36);
    l_resp CLOB;
BEGIN
    l_conv := DBMS_CLOUD_AI.CREATE_CONVERSATION();
    l_resp := DBMS_CLOUD_AI_AGENT.RUN_TEAM(
        team_name   => 'ACME_ANALYST_TEAM',
        user_prompt => 'What is the ACME Corp reconciliation policy?',
        params      => '{"conversation_id":"' || l_conv || '"}'
    );
    DBMS_OUTPUT.PUT_LINE(l_resp);
END;
/

-- 12.3 Trend
DECLARE
    l_conv VARCHAR2(36);
    l_resp CLOB;
BEGIN
    l_conv := DBMS_CLOUD_AI.CREATE_CONVERSATION();
    l_resp := DBMS_CLOUD_AI_AGENT.RUN_TEAM(
        team_name   => 'ACME_ANALYST_TEAM',
        user_prompt => 'Show me the expense trend for Engineering department',
        params      => '{"conversation_id":"' || l_conv || '"}'
    );
    DBMS_OUTPUT.PUT_LINE(l_resp);
END;
/

-- 12.4 Forecast
DECLARE
    l_conv VARCHAR2(36);
    l_resp CLOB;
BEGIN
    l_conv := DBMS_CLOUD_AI.CREATE_CONVERSATION();
    l_resp := DBMS_CLOUD_AI_AGENT.RUN_TEAM(
        team_name   => 'ACME_ANALYST_TEAM',
        user_prompt => 'Forecast Sales department expenses for the next 3 periods',
        params      => '{"conversation_id":"' || l_conv || '"}'
    );
    DBMS_OUTPUT.PUT_LINE(l_resp);
END;
/

-- 12.5 Anomaly
DECLARE
    l_conv VARCHAR2(36);
    l_resp CLOB;
BEGIN
    l_conv := DBMS_CLOUD_AI.CREATE_CONVERSATION();
    l_resp := DBMS_CLOUD_AI_AGENT.RUN_TEAM(
        team_name   => 'ACME_ANALYST_TEAM',
        user_prompt => 'Are there any unusual spending patterns in our GL data?',
        params      => '{"conversation_id":"' || l_conv || '"}'
    );
    DBMS_OUTPUT.PUT_LINE(l_resp);
END;
/

-- 12.6 Python (no manual token needed — auto-refreshed by wrapper)
DECLARE
    l_conv VARCHAR2(36);
    l_resp CLOB;
BEGIN
    l_conv := DBMS_CLOUD_AI.CREATE_CONVERSATION();
    l_resp := DBMS_CLOUD_AI_AGENT.RUN_TEAM(
        team_name   => 'ACME_ANALYST_TEAM',
        user_prompt => 'Give me a Python statistical analysis of Engineering expenses including moving averages',
        params      => '{"conversation_id":"' || l_conv || '"}'
    );
    DBMS_OUTPUT.PUT_LINE(l_resp);
END;
/

-- 12.7 Confirm all 6 tools were invoked
SELECT tool_name, agent_name, start_date,
       SUBSTR(tool_output,1,120) AS output_preview
FROM   user_ai_agent_tool_history
ORDER  BY start_date DESC
FETCH  FIRST 12 ROWS ONLY;

-- ============================================================================
-- END OF FILE: SA_02_ACME_CORP_setup.sql
-- ============================================================================
