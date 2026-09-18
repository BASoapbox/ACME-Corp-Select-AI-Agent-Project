--------------------------------------------------------------------------------
--  FILE:    SA_07_eval_tables.sql
--  RUN AS:  the agent schema (ACME_CORP), or through a proxy into it
--  PURPOSE: Storage for evaluation runs, so results are comparable over time.
--
--  One row per run in ACME_EVAL_RUNS, one row per case in ACME_EVAL_RESULTS.
--  Keeping them in the database (rather than a file) means a regression is a
--  SQL question: which cases passed last week and fail today.
--------------------------------------------------------------------------------

SET SERVEROUTPUT ON
SET DEFINE OFF

DECLARE
    PROCEDURE go(s VARCHAR2) IS BEGIN EXECUTE IMMEDIATE s;
        EXCEPTION WHEN OTHERS THEN
            IF SQLCODE IN (-955, -1430) THEN NULL;   -- already exists
            ELSE DBMS_OUTPUT.PUT_LINE('  skip: '||SUBSTR(SQLERRM,1,90)); END IF;
    END;
BEGIN
    go('CREATE TABLE acme_eval_runs (
          run_id        VARCHAR2(40)  PRIMARY KEY,
          started_at    TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
          finished_at   TIMESTAMP,
          team_name     VARCHAR2(128),
          case_count    NUMBER,
          passed        NUMBER,
          failed        NUMBER,
          known_failed  NUMBER,
          pass_pct      NUMBER(5,1),
          git_ref       VARCHAR2(80),
          notes         VARCHAR2(4000)
        )');

    go('CREATE TABLE acme_eval_results (
          run_id        VARCHAR2(40)  NOT NULL,
          case_id       VARCHAR2(80)  NOT NULL,
          category      VARCHAR2(40),
          question      VARCHAR2(1000),
          answer        CLOB,
          passed        VARCHAR2(1),
          known_failure VARCHAR2(1),
          failures      VARCHAR2(4000),
          elapsed_ms    NUMBER,
          tools_fired   VARCHAR2(400),
          team_exec_id  VARCHAR2(80),
          CONSTRAINT acme_eval_results_pk PRIMARY KEY (run_id, case_id)
        )');

    go('ALTER TABLE acme_eval_results ADD CONSTRAINT acme_eval_results_fk
          FOREIGN KEY (run_id) REFERENCES acme_eval_runs(run_id)');

    DBMS_OUTPUT.PUT_LINE('  eval tables ready');
END;
/

COLUMN table_name FORMAT A24
SELECT table_name FROM user_tables WHERE table_name LIKE 'ACME_EVAL%' ORDER BY 1;
