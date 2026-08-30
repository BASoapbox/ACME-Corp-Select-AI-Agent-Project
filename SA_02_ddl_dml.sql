/*
================================================================================
  FILE:    SA_00_DDL_DML.sql
  PURPOSE: Creates and populates all ACME Corp tables required by the
           Select AI Agent. Run this file FIRST before SA_02.
  RUN AS:  ^agent_schema.
  SCHEMA:  ^agent_schema.
  PROJECT: ACME AI — Select AI Agent (App 103 Page 4)
================================================================================

  WHAT THIS FILE CREATES:
    ┌─ Core data tables ──────────────────────────────────────────────────┐
    │  ACME_GL_TRANSACTIONS    — General Ledger postings                  │
    │  ACME_CHART_OF_ACCOUNTS  — Account codes and types                  │
    │  ACME_DEPARTMENTS        — Department master                        │
    │  ACME_PERIOD_CLOSE       — Period close task tracking               │
    └────────────────────────────────────────────────────────────────────┘
    ┌─ Agent support tables ──────────────────────────────────────────────┐
    │  ACME_CHAT_SESSIONS      — Chat session registry (APEX Page 4)      │
    │  ACME_CHAT_MESSAGES      — Chat message history per session         │
    │  ACME_ERROR_LOG          — Runtime error logging (EPE token etc.)   │
    └────────────────────────────────────────────────────────────────────┘

  REFERENCE DATA LOADED:
    - 13 chart of accounts entries
    - 6 departments
    - 9 periods × 5 departments of GL data (97 rows)
    - 3 deliberate anomalies for ML tool testing
    - Period close tasks for JAN through SEP 2025 (all 9 periods)

  GL ANOMALIES (deliberate — for ML tool demos):
    Finance     MAY-2025: $279,000  (annual audit + ERP consulting)
    Engineering AUG-2025: $176,000  (cloud migration project)
    Sales       JUN-2025: $144,200  (annual conference + H1 incentives)

  VERIFIED GL STATISTICS (numpy population std dev):
    Engineering: mean=$63,055.56  std_dev=$42,667.61  peak=AUG-2025
    Finance:     mean=$165,444.44 std_dev=$41,199.01  peak=MAY-2025
    Sales:       mean=$76,111.11  std_dev=$24,569.51  peak=JUN-2025

  SAFE TO RE-RUN: No — DROP existing tables first if re-running.
    Run this to clean up: DROP TABLE acme_gl_transactions PURGE;
                          DROP TABLE acme_chart_of_accounts PURGE;
                          DROP TABLE acme_departments PURGE;
                          DROP TABLE acme_period_close PURGE;
                          DROP TABLE acme_chat_sessions PURGE;
                          DROP TABLE acme_chat_messages PURGE;
                          DROP TABLE acme_error_log PURGE;

  SECTIONS:
    1.  Create core data tables
    2.  Create agent support tables
    3.  Chart of accounts reference data
    4.  Department reference data
    5.  Period close tasks (all 9 periods)
    6.  GL transactions — Finance (410)
    7.  GL transactions — Engineering (420)
    8.  GL transactions — Operations (440)
    9.  GL transactions — Sales (430)
    10. GL transactions — Corporate (100)
    11. Verify row counts

================================================================================
*/

@SA_ENV



-- ============================================================================
-- SECTION 0: DROP EXISTING OBJECTS  (makes this script safe to re-run)
-- ============================================================================
-- Without this, re-running raises ORA-00955 on every CREATE TABLE and the
-- header's "SAFE TO RE-RUN" claim is false. CASCADE CONSTRAINTS handles the
-- ACME_CHAT_MESSAGES -> ACME_CHAT_SESSIONS foreign key regardless of order.

BEGIN
    BEGIN EXECUTE IMMEDIATE 'DROP TABLE acme_chat_messages CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN EXECUTE IMMEDIATE 'DROP TABLE acme_chat_sessions CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN EXECUTE IMMEDIATE 'DROP TABLE acme_gl_transactions CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN EXECUTE IMMEDIATE 'DROP TABLE acme_period_close CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN EXECUTE IMMEDIATE 'DROP TABLE acme_chart_of_accounts CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN EXECUTE IMMEDIATE 'DROP TABLE acme_departments CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN NULL; END;
    BEGIN EXECUTE IMMEDIATE 'DROP TABLE acme_error_log CASCADE CONSTRAINTS PURGE';
    EXCEPTION WHEN OTHERS THEN NULL; END;
END;
/

-- ============================================================================
-- SECTION 1: CORE DATA TABLES
-- ============================================================================

-- 1.1 GL Transactions — main financial ledger
-- NOTE: TRANSACTION_DATE is NOT NULL. Always include it in INSERT statements.
CREATE TABLE acme_gl_transactions (
    transaction_id    NUMBER          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    transaction_date  DATE            NOT NULL,
    period_name       VARCHAR2(20),
    company_code      VARCHAR2(10),
    department_code   VARCHAR2(10),
    account_code      VARCHAR2(20),
    account_type      VARCHAR2(20),
    description       VARCHAR2(200),
    debit_amount      NUMBER(15,2),
    credit_amount     NUMBER(15,2),
    currency_code     VARCHAR2(3),
    status            VARCHAR2(20),
    created_by        VARCHAR2(50),
    created_date      DATE
);

-- 1.2 Chart of Accounts
CREATE TABLE acme_chart_of_accounts (
    account_code  VARCHAR2(20)  PRIMARY KEY,
    account_name  VARCHAR2(100) NOT NULL,
    account_type  VARCHAR2(20)  NOT NULL,
    parent_code   VARCHAR2(20),
    is_active     VARCHAR2(1)   DEFAULT 'Y'
);

-- 1.3 Departments
CREATE TABLE acme_departments (
    department_code  VARCHAR2(10)  PRIMARY KEY,
    department_name  VARCHAR2(100) NOT NULL,
    manager_name     VARCHAR2(100),
    cost_center      VARCHAR2(20),
    is_active        VARCHAR2(1)   DEFAULT 'Y'
);

-- 1.4 Period Close Tasks
CREATE TABLE acme_period_close (
    task_id        NUMBER        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    period_name    VARCHAR2(10)  NOT NULL,
    task_name      VARCHAR2(200) NOT NULL,
    assigned_to    VARCHAR2(100),
    due_date       DATE,
    status         VARCHAR2(20)  DEFAULT 'OPEN',
    completed_date DATE,
    notes          VARCHAR2(500)
);

-- ============================================================================
-- SECTION 2: AGENT SUPPORT TABLES
-- ============================================================================

-- 2.1 Chat Sessions — one row per APEX Page 4 conversation
CREATE TABLE acme_chat_sessions (
    session_id    VARCHAR2(36)   PRIMARY KEY,
    apex_user     VARCHAR2(100),
    started_at    TIMESTAMP      DEFAULT SYSTIMESTAMP,
    last_activity TIMESTAMP      DEFAULT SYSTIMESTAMP,
    session_notes VARCHAR2(500)
);

-- 2.2 Chat Messages — full conversation history per session
CREATE TABLE acme_chat_messages (
    message_id    NUMBER         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    session_id    VARCHAR2(36)   NOT NULL,
    message_seq   NUMBER         NOT NULL,
    role          VARCHAR2(10)   NOT NULL,  -- USER or ASSISTANT
    message_text  CLOB,
    tool_used     VARCHAR2(100),
    created_at    TIMESTAMP      DEFAULT SYSTIMESTAMP,
    CONSTRAINT fk_chat_session FOREIGN KEY (session_id)
        REFERENCES acme_chat_sessions(session_id)
);

-- 2.3 Error Log — captures EPE token failures, tool errors, etc.
CREATE TABLE acme_error_log (
    log_id        NUMBER         GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    error_date    DATE           DEFAULT SYSDATE,
    error_source  VARCHAR2(100),
    error_msg     VARCHAR2(4000),
    error_detail  CLOB
);

-- ============================================================================
-- SECTION 3: CHART OF ACCOUNTS
-- ============================================================================

INSERT INTO acme_chart_of_accounts VALUES ('6000','Salaries and Wages',      'EXPENSE',NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('6100','Software Licenses',        'EXPENSE',NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('6200','Cloud Infrastructure',     'EXPENSE',NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('6300','Travel and Entertainment', 'EXPENSE',NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('6400','Professional Services',    'EXPENSE',NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('6500','Office Supplies',          'EXPENSE',NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('6600','Training and Development', 'EXPENSE',NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('7000','Product Revenue',          'REVENUE',NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('7100','Service Revenue',          'REVENUE',NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('1000','Cash and Equivalents',     'ASSET',  NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('1100','Accounts Receivable',      'ASSET',  NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('2000','Accounts Payable',         'LIABILITY',NULL,'Y');
INSERT INTO acme_chart_of_accounts VALUES ('3000','Retained Earnings',        'EQUITY', NULL,'Y');
COMMIT;

-- ============================================================================
-- SECTION 4: DEPARTMENTS
-- ============================================================================

INSERT INTO acme_departments VALUES ('100','Corporate',   'CEO Office',  'CC-100','Y');
INSERT INTO acme_departments VALUES ('200','Europe HQ',   'Regional VP', 'CC-200','Y');
INSERT INTO acme_departments VALUES ('410','Finance',     'CFO',         'CC-410','Y');
INSERT INTO acme_departments VALUES ('420','Engineering', 'CTO',         'CC-420','Y');
INSERT INTO acme_departments VALUES ('430','Sales',       'VP Sales',    'CC-430','Y');
INSERT INTO acme_departments VALUES ('440','Operations',  'COO',         'CC-440','Y');
COMMIT;

-- ============================================================================
-- SECTION 5: PERIOD CLOSE TASKS — ALL 9 PERIODS (JAN-SEP 2025)
-- ============================================================================
-- Standard 7-task checklist applied to every period.
-- Status reflects a realistic progression:
--   Q1 (JAN-MAR): fully COMPLETE
--   Q2 (APR-JUN): mostly COMPLETE, some items still closing
--   Q3 (JUL-AUG): IN_PROGRESS / OPEN
--   SEP-2025:     all OPEN (most recent period)
-- ============================================================================

-- JAN-2025 (fully closed)
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JAN-2025','Reconcile all GL accounts','Finance Team',DATE '2025-02-07','COMPLETE',DATE '2025-02-06');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JAN-2025','Review intercompany balances','Controller',DATE '2025-02-05','COMPLETE',DATE '2025-02-04');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JAN-2025','Obtain Level 2 approvals for items >$10K','CFO',DATE '2025-02-06','COMPLETE',DATE '2025-02-06');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JAN-2025','Prepare management P&L report','FP&A Team',DATE '2025-02-08','COMPLETE',DATE '2025-02-08');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JAN-2025','SOX control sign-off','Compliance',DATE '2025-02-09','COMPLETE',DATE '2025-02-09');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JAN-2025','Archive reconciliation documentation','Finance Team',DATE '2025-02-10','COMPLETE',DATE '2025-02-10');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JAN-2025','Lock period in ERP system','System Admin',DATE '2025-02-11','COMPLETE',DATE '2025-02-11');

-- FEB-2025 (fully closed)
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('FEB-2025','Reconcile all GL accounts','Finance Team',DATE '2025-03-07','COMPLETE',DATE '2025-03-06');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('FEB-2025','Review intercompany balances','Controller',DATE '2025-03-05','COMPLETE',DATE '2025-03-04');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('FEB-2025','Obtain Level 2 approvals for items >$10K','CFO',DATE '2025-03-06','COMPLETE',DATE '2025-03-06');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('FEB-2025','Prepare management P&L report','FP&A Team',DATE '2025-03-08','COMPLETE',DATE '2025-03-07');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('FEB-2025','SOX control sign-off','Compliance',DATE '2025-03-09','COMPLETE',DATE '2025-03-09');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('FEB-2025','Archive reconciliation documentation','Finance Team',DATE '2025-03-10','COMPLETE',DATE '2025-03-10');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('FEB-2025','Lock period in ERP system','System Admin',DATE '2025-03-11','COMPLETE',DATE '2025-03-11');

-- MAR-2025 (fully closed)
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAR-2025','Reconcile all GL accounts','Finance Team',DATE '2025-04-07','COMPLETE',DATE '2025-04-06');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAR-2025','Review intercompany balances','Controller',DATE '2025-04-05','COMPLETE',DATE '2025-04-04');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAR-2025','Obtain Level 2 approvals for items >$10K','CFO',DATE '2025-04-06','COMPLETE',DATE '2025-04-06');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAR-2025','Prepare management P&L report','FP&A Team',DATE '2025-04-08','COMPLETE',DATE '2025-04-08');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAR-2025','SOX control sign-off','Compliance',DATE '2025-04-09','COMPLETE',DATE '2025-04-09');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAR-2025','Archive reconciliation documentation','Finance Team',DATE '2025-04-10','COMPLETE',DATE '2025-04-10');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAR-2025','Lock period in ERP system','System Admin',DATE '2025-04-11','COMPLETE',DATE '2025-04-11');

-- APR-2025 (fully closed)
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('APR-2025','Reconcile all GL accounts','Finance Team',DATE '2025-05-07','COMPLETE',DATE '2025-05-06');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('APR-2025','Review intercompany balances','Controller',DATE '2025-05-05','COMPLETE',DATE '2025-05-05');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('APR-2025','Obtain Level 2 approvals for items >$10K','CFO',DATE '2025-05-06','COMPLETE',DATE '2025-05-06');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('APR-2025','Prepare management P&L report','FP&A Team',DATE '2025-05-08','COMPLETE',DATE '2025-05-08');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('APR-2025','SOX control sign-off','Compliance',DATE '2025-05-09','COMPLETE',DATE '2025-05-09');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('APR-2025','Archive reconciliation documentation','Finance Team',DATE '2025-05-10','COMPLETE',DATE '2025-05-10');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('APR-2025','Lock period in ERP system','System Admin',DATE '2025-05-11','COMPLETE',DATE '2025-05-11');

-- MAY-2025 (fully closed — note: audit month, more scrutiny on approvals)
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAY-2025','Reconcile all GL accounts','Finance Team',DATE '2025-06-07','COMPLETE',DATE '2025-06-06');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAY-2025','Review intercompany balances','Controller',DATE '2025-06-05','COMPLETE',DATE '2025-06-05');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAY-2025','Obtain Level 2 approvals for items >$10K','CFO',DATE '2025-06-06','COMPLETE',DATE '2025-06-07');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAY-2025','Prepare management P&L report','FP&A Team',DATE '2025-06-08','COMPLETE',DATE '2025-06-08');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAY-2025','SOX control sign-off','Compliance',DATE '2025-06-09','COMPLETE',DATE '2025-06-10');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAY-2025','Archive reconciliation documentation','Finance Team',DATE '2025-06-10','COMPLETE',DATE '2025-06-10');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('MAY-2025','Lock period in ERP system','System Admin',DATE '2025-06-11','COMPLETE',DATE '2025-06-11');

-- JUN-2025 (fully closed)
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUN-2025','Reconcile all GL accounts','Finance Team',DATE '2025-07-07','COMPLETE',DATE '2025-07-07');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUN-2025','Review intercompany balances','Controller',DATE '2025-07-05','COMPLETE',DATE '2025-07-05');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUN-2025','Obtain Level 2 approvals for items >$10K','CFO',DATE '2025-07-06','COMPLETE',DATE '2025-07-06');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUN-2025','Prepare management P&L report','FP&A Team',DATE '2025-07-08','COMPLETE',DATE '2025-07-08');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUN-2025','SOX control sign-off','Compliance',DATE '2025-07-09','COMPLETE',DATE '2025-07-09');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUN-2025','Archive reconciliation documentation','Finance Team',DATE '2025-07-10','COMPLETE',DATE '2025-07-10');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUN-2025','Lock period in ERP system','System Admin',DATE '2025-07-11','COMPLETE',DATE '2025-07-11');

-- JUL-2025 (mostly complete, ERP lock pending)
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUL-2025','Reconcile all GL accounts','Finance Team',DATE '2025-08-07','COMPLETE',DATE '2025-08-07');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUL-2025','Review intercompany balances','Controller',DATE '2025-08-05','COMPLETE',DATE '2025-08-05');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUL-2025','Obtain Level 2 approvals for items >$10K','CFO',DATE '2025-08-06','COMPLETE',DATE '2025-08-06');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUL-2025','Prepare management P&L report','FP&A Team',DATE '2025-08-08','COMPLETE',DATE '2025-08-08');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('JUL-2025','SOX control sign-off','Compliance',DATE '2025-08-09','COMPLETE',DATE '2025-08-09');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('JUL-2025','Archive reconciliation documentation','Finance Team',DATE '2025-08-10','IN_PROGRESS');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('JUL-2025','Lock period in ERP system','System Admin',DATE '2025-08-11','OPEN');

-- AUG-2025 (in progress — cloud migration month, extra scrutiny)
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('AUG-2025','Reconcile all GL accounts','Finance Team',DATE '2025-09-07','COMPLETE',DATE '2025-09-08');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status,completed_date)
VALUES('AUG-2025','Review intercompany balances','Controller',DATE '2025-09-05','COMPLETE',DATE '2025-09-05');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('AUG-2025','Obtain Level 2 approvals for items >$10K','CFO',DATE '2025-09-06','IN_PROGRESS');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('AUG-2025','Prepare management P&L report','FP&A Team',DATE '2025-09-08','IN_PROGRESS');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('AUG-2025','SOX control sign-off','Compliance',DATE '2025-09-09','OPEN');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('AUG-2025','Archive reconciliation documentation','Finance Team',DATE '2025-09-10','OPEN');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('AUG-2025','Lock period in ERP system','System Admin',DATE '2025-09-11','OPEN');

-- SEP-2025 (all open — most recent period)
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('SEP-2025','Reconcile all GL accounts','Finance Team',DATE '2025-10-07','OPEN');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('SEP-2025','Review intercompany balances','Controller',DATE '2025-10-05','OPEN');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('SEP-2025','Obtain Level 2 approvals for items >$10K','CFO',DATE '2025-10-06','OPEN');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('SEP-2025','Prepare management P&L report','FP&A Team',DATE '2025-10-08','OPEN');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('SEP-2025','SOX control sign-off','Compliance',DATE '2025-10-09','OPEN');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('SEP-2025','Archive reconciliation documentation','Finance Team',DATE '2025-10-10','OPEN');
INSERT INTO acme_period_close(period_name,task_name,assigned_to,due_date,status)
VALUES('SEP-2025','Lock period in ERP system','System Admin',DATE '2025-10-11','OPEN');
COMMIT;

-- ============================================================================
-- SECTION 6: GL TRANSACTIONS — FINANCE (410)
-- ============================================================================
-- Normal spend: ~$143K-$165K per period (salaries + professional services)
-- MAY-2025 ANOMALY: $279,000 (annual audit $85K + ERP consulting $62K)

INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-01-01','JAN-2025','410','6000','EXPENSE','Finance salaries Jan',120000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-01-01','JAN-2025','410','6400','EXPENSE','Audit services Jan',28000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-02-01','FEB-2025','410','6000','EXPENSE','Finance salaries Feb',120000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-02-01','FEB-2025','410','6400','EXPENSE','Consulting Feb',45000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','410','6000','EXPENSE','Finance salaries Mar',120000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','410','6300','EXPENSE','Finance travel Mar',8000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','410','6600','EXPENSE','Finance training Mar',7000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','410','6000','EXPENSE','Finance salaries Apr',120000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','410','6400','EXPENSE','Professional services Apr',18000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','410','6300','EXPENSE','Finance travel Apr',5000,'USD','POSTED','^agent_schema.');
-- MAY-2025 ANOMALY
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','410','6000','EXPENSE','Finance salaries May',120000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','410','6400','EXPENSE','Annual external audit',85000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','410','6400','EXPENSE','ERP consulting engagement',62000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','410','6600','EXPENSE','Finance team training May',12000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','410','6000','EXPENSE','Finance salaries Jun',120000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','410','6400','EXPENSE','Professional services Jun',22000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','410','6300','EXPENSE','Finance travel Jun',6000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','410','6000','EXPENSE','Finance salaries Jul',122000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','410','6400','EXPENSE','Professional services Jul',20000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','410','6300','EXPENSE','Finance travel Jul',7000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','410','6000','EXPENSE','Finance salaries Aug',125000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','410','6400','EXPENSE','Q3 compliance review',25000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','410','6600','EXPENSE','Leadership training Aug',15000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','410','6000','EXPENSE','Finance salaries Sep',125000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','410','6400','EXPENSE','Professional services Sep',24000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','410','6300','EXPENSE','Finance travel Sep',8000,'USD','POSTED','^agent_schema.');
COMMIT;

-- ============================================================================
-- SECTION 7: GL TRANSACTIONS — ENGINEERING (420)
-- ============================================================================
-- Steady growth ~$22K to ~$68K per period
-- AUG-2025 ANOMALY: $176,000 (cloud migration $95K + consulting $40K)

INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-01-01','JAN-2025','420','6000','EXPENSE','Engineering salaries Jan',22000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-02-01','FEB-2025','420','6000','EXPENSE','Engineering salaries Feb',22000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-02-01','FEB-2025','420','6100','EXPENSE','Software licenses Feb',8000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','420','6000','EXPENSE','Engineering salaries Mar',22000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','420','6200','EXPENSE','Cloud infra Mar',15000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','420','6000','EXPENSE','Engineering salaries Apr',26000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','420','6100','EXPENSE','Software licenses Apr',9000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','420','6200','EXPENSE','Cloud infrastructure Apr',18000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','420','6000','EXPENSE','Engineering salaries May',28000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','420','6100','EXPENSE','Software licenses May',9500,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','420','6200','EXPENSE','Cloud infrastructure May',20000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','420','6000','EXPENSE','Engineering salaries Jun',28000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','420','6100','EXPENSE','Software licenses Jun',10000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','420','6200','EXPENSE','Cloud infrastructure Jun',22000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','420','6000','EXPENSE','Engineering salaries Jul',30000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','420','6100','EXPENSE','Software licenses Jul',10500,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','420','6200','EXPENSE','Cloud infrastructure Jul',23000,'USD','POSTED','^agent_schema.');
-- AUG-2025 ANOMALY
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','420','6000','EXPENSE','Engineering salaries Aug',30000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','420','6200','EXPENSE','Cloud migration project',95000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','420','6400','EXPENSE','Cloud architecture consulting',40000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','420','6100','EXPENSE','Software licenses Aug',11000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','420','6000','EXPENSE','Engineering salaries Sep',32000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','420','6100','EXPENSE','Software licenses Sep',11500,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','420','6200','EXPENSE','Cloud infrastructure Sep',25000,'USD','POSTED','^agent_schema.');
COMMIT;

-- ============================================================================
-- SECTION 8: GL TRANSACTIONS — OPERATIONS (440)
-- ============================================================================
-- Flat spending ~$1,800-$2,300 per period — stable baseline

INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-01-01','JAN-2025','440','6500','EXPENSE','Office supplies Jan',1200,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-02-01','FEB-2025','440','6500','EXPENSE','Office supplies Feb',1100,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','440','6500','EXPENSE','Office supplies Mar',1200,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','440','6500','EXPENSE','Office supplies Apr',1300,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','440','6300','EXPENSE','Operations travel Apr',800,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','440','6500','EXPENSE','Office supplies May',1150,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','440','6300','EXPENSE','Operations travel May',750,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','440','6500','EXPENSE','Office supplies Jun',1400,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','440','6300','EXPENSE','Operations travel Jun',900,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','440','6500','EXPENSE','Office supplies Jul',1100,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','440','6300','EXPENSE','Operations travel Jul',700,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','440','6500','EXPENSE','Office supplies Aug',1250,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','440','6300','EXPENSE','Operations travel Aug',850,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','440','6500','EXPENSE','Office supplies Sep',1300,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','440','6300','EXPENSE','Operations travel Sep',900,'USD','POSTED','^agent_schema.');
COMMIT;

-- ============================================================================
-- SECTION 9: GL TRANSACTIONS — SALES (430)
-- ============================================================================
-- Clear upward trend ~$60K to ~$76K per period
-- JUN-2025 ANOMALY: $144,200 (conference $55K + H1 incentives $38K)

INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-01-01','JAN-2025','430','6000','EXPENSE','Sales salaries Jan',45000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-01-01','JAN-2025','430','6300','EXPENSE','Sales travel Jan',12000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-01-01','JAN-2025','430','6500','EXPENSE','Sales materials Jan',3000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-02-01','FEB-2025','430','6000','EXPENSE','Sales salaries Feb',45000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-02-01','FEB-2025','430','6300','EXPENSE','Sales travel Feb',14000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-02-01','FEB-2025','430','6500','EXPENSE','Sales materials Feb',3200,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','430','6000','EXPENSE','Sales salaries Mar',45000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','430','6300','EXPENSE','Sales travel Mar',15000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','430','6500','EXPENSE','Sales materials Mar',3500,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','430','6000','EXPENSE','Sales salaries Apr',47000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','430','6300','EXPENSE','Sales travel Apr',16000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','430','6500','EXPENSE','Sales materials Apr',3800,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','430','6000','EXPENSE','Sales salaries May',47000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','430','6300','EXPENSE','Sales travel May',17000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','430','6500','EXPENSE','Sales materials May',4000,'USD','POSTED','^agent_schema.');
-- JUN-2025 ANOMALY
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','430','6000','EXPENSE','Sales salaries Jun',47000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','430','6300','EXPENSE','Annual sales conference',55000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','430','6000','EXPENSE','H1 performance incentives',38000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','430','6500','EXPENSE','Sales materials Jun',4200,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','430','6000','EXPENSE','Sales salaries Jul',49000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','430','6300','EXPENSE','Sales travel Jul',18000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','430','6500','EXPENSE','Sales materials Jul',4500,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','430','6000','EXPENSE','Sales salaries Aug',49000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','430','6300','EXPENSE','Sales travel Aug',19000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','430','6500','EXPENSE','Sales materials Aug',4800,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','430','6000','EXPENSE','Sales salaries Sep',51000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','430','6300','EXPENSE','Sales travel Sep',20000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','430','6500','EXPENSE','Sales materials Sep',5000,'USD','POSTED','^agent_schema.');
COMMIT;

-- ============================================================================
-- SECTION 10: GL TRANSACTIONS — CORPORATE (100)
-- ============================================================================
-- Stable baseline ~$113K-$121K per period — no anomalies

INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-01-01','JAN-2025','100','6000','EXPENSE','Corporate salaries Jan',90000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-01-01','JAN-2025','100','6400','EXPENSE','Legal services Jan',15000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-01-01','JAN-2025','100','6300','EXPENSE','Executive travel Jan',8000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-02-01','FEB-2025','100','6000','EXPENSE','Corporate salaries Feb',90000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-02-01','FEB-2025','100','6400','EXPENSE','Legal services Feb',16000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-02-01','FEB-2025','100','6300','EXPENSE','Executive travel Feb',9000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','100','6000','EXPENSE','Corporate salaries Mar',90000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','100','6400','EXPENSE','Legal services Mar',14000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-03-01','MAR-2025','100','6300','EXPENSE','Executive travel Mar',10000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','100','6000','EXPENSE','Corporate salaries Apr',92000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','100','6400','EXPENSE','Legal services Apr',15000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-04-01','APR-2025','100','6300','EXPENSE','Executive travel Apr',9500,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','100','6000','EXPENSE','Corporate salaries May',92000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','100','6400','EXPENSE','Legal services May',15500,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-05-01','MAY-2025','100','6300','EXPENSE','Executive travel May',9000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','100','6000','EXPENSE','Corporate salaries Jun',92000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','100','6400','EXPENSE','Legal services Jun',16000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-06-01','JUN-2025','100','6300','EXPENSE','Executive travel Jun',11000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','100','6000','EXPENSE','Corporate salaries Jul',94000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','100','6400','EXPENSE','Legal services Jul',15000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-07-01','JUL-2025','100','6300','EXPENSE','Executive travel Jul',10000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','100','6000','EXPENSE','Corporate salaries Aug',94000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','100','6400','EXPENSE','Legal services Aug',17000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-08-01','AUG-2025','100','6300','EXPENSE','Executive travel Aug',10500,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','100','6000','EXPENSE','Corporate salaries Sep',94000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','100','6400','EXPENSE','Legal services Sep',16000,'USD','POSTED','^agent_schema.');
INSERT INTO acme_gl_transactions(transaction_date,period_name,department_code,account_code,account_type,description,debit_amount,currency_code,status,created_by)VALUES(DATE '2025-09-01','SEP-2025','100','6300','EXPENSE','Executive travel Sep',11000,'USD','POSTED','^agent_schema.');
COMMIT;

-- ============================================================================
-- SECTION 11: VERIFY ROW COUNTS
-- ============================================================================

SELECT 'acme_gl_transactions'   AS table_name, COUNT(*) AS row_count FROM acme_gl_transactions
UNION ALL
SELECT 'acme_chart_of_accounts',                COUNT(*) FROM acme_chart_of_accounts
UNION ALL
SELECT 'acme_departments',                      COUNT(*) FROM acme_departments
UNION ALL
SELECT 'acme_period_close',                     COUNT(*) FROM acme_period_close
UNION ALL
SELECT 'acme_chat_sessions',                    COUNT(*) FROM acme_chat_sessions
UNION ALL
SELECT 'acme_chat_messages',                    COUNT(*) FROM acme_chat_messages
UNION ALL
SELECT 'acme_error_log',                        COUNT(*) FROM acme_error_log
ORDER BY 1;
-- Expected:
--   acme_chart_of_accounts : 13
--   acme_chat_messages     :  0
--   acme_chat_sessions     :  0
--   acme_departments       :  6
--   acme_error_log         :  0
--   acme_gl_transactions   : 97
--   acme_period_close      : 63  (9 periods × 7 tasks)

-- GL row count by department
SELECT d.department_name,
       COUNT(*)           AS gl_rows,
       COUNT(DISTINCT t.period_name) AS periods
FROM   acme_gl_transactions t
JOIN   acme_departments d ON d.department_code = t.department_code
WHERE  t.account_type = 'EXPENSE'
GROUP  BY d.department_name
ORDER  BY d.department_name;

-- Period close task status summary
SELECT period_name, status, COUNT(*) AS tasks
FROM   acme_period_close
GROUP  BY period_name, status
ORDER  BY period_name, status;

-- ============================================================================
-- END OF FILE: SA_00_DDL_DML.sql
-- Next: Run SA_02_ACME_CORP_setup.sql (skipping its Sections 1-3)
-- ============================================================================
