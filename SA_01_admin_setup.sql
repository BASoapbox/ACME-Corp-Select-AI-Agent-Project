/*
================================================================================
  FILE:    SA_01_ADMIN_setup.sql
  PURPOSE: All ADMIN-level grants and configuration for the
           ACME Corp Select AI Agent (ACME_ANALYST_TEAM)
  RUN AS:  ADMIN on the ADW instance
  SCHEMA:  ADMIN
  PROJECT: ACME AI — Select AI Agent (App 103 Page 4)
  REGION:  set in SA_ENV.sql
================================================================================

  SCOPE — THIS FILE ONLY:
    This file covers everything ADMIN must run for the Select AI Agent,
    including NL2SQL, RAG, and all 4 custom ML tools (including Python EPE).
    It does NOT cover OCI GenAI Agent (Pages 2 & 3) — that is a separate setup.

  EXECUTION ORDER:
    1. Run this file as ADMIN            ← you are here
    2. Run SA_03_agent_setup.sql as ^agent_schema.

  SAFE TO RE-RUN: Yes — all operations are idempotent.

  REPLACE:
    No replacements needed in this file. All values are environment-specific
    only in SA_03_agent_setup.sql where ^compartment_ocid. appears.

  SECTIONS:
    1.  Enable Resource Principal for ^agent_schema.
    2.  Grant package execute privileges (DBMS_CLOUD_AI, DBMS_CLOUD_AI_AGENT)
    3.  Grant OML4Py privileges (required for Python EPE custom tool)
    4.  EPE-specific network ACL (pyqAppendHostAce — NOT DBMS_NETWORK_ACL_ADMIN)
    5.  IAM policy reference (OCI Console — cannot be done from SQL)
    6.  Verify all grants

================================================================================
*/

@SA_ENV

WHENEVER SQLERROR CONTINUE


-- ============================================================================
-- SECTION 1: ENABLE RESOURCE PRINCIPAL FOR ^agent_schema.
-- ============================================================================
-- Resource Principal allows the ADW instance to authenticate to OCI services
-- (OCI GenAI, Object Storage) using its own OCI identity — no API keys needed.
-- This is the foundation of the zero-credential security model.
--
-- After running this:
--   - EXECUTE on ADMIN.OCI$RESOURCE_PRINCIPAL is granted to ^agent_schema.
--   - The ADW instance can call OCI GenAI (LLM + embeddings) and Object Storage
--   - APEX never stores any OCI credentials
--
-- IMPORTANT: The IAM policy must also be configured (see Section 5).
-- ============================================================================

BEGIN
    DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL(
        username     => '^agent_schema.',
        grant_option => FALSE
    );
END;
/

-- Verify Resource Principal was activated for ^agent_schema.
-- Resource Principal is OWNED BY ADMIN and GRANTED to the schema.
-- Querying dba_credentials WHERE owner = <schema> returns 0 rows even on
-- success -- a false negative. Check the grant instead.
SELECT grantee, owner AS granted_by, table_name, privilege
FROM   dba_tab_privs
WHERE  grantee    = '^agent_schema.'
AND    table_name = 'OCI$RESOURCE_PRINCIPAL';
-- Expected: 1 row -- ^agent_schema. | ADMIN | OCI$RESOURCE_PRINCIPAL | EXECUTE

-- ============================================================================
-- SECTION 2: GRANT PACKAGE EXECUTE PRIVILEGES
-- ============================================================================
-- Grants ^agent_schema. access to all DBMS_CLOUD* packages needed for the
-- Select AI Agent stack:
--
--   DBMS_CLOUD_AI        — Select AI profiles, vector indexes, NL2SQL, RAG
--   DBMS_CLOUD_AI_AGENT  — Agent framework: CREATE_TOOL, CREATE_AGENT,
--                          CREATE_TASK, CREATE_TEAM, RUN_TEAM
--   DBMS_CLOUD           — HTTP/REST calls, credential management
--   DBMS_CLOUD_ADMIN     — Admin-level operations from ^agent_schema. context
-- ============================================================================

GRANT EXECUTE ON DBMS_CLOUD          TO ^agent_schema.;
GRANT EXECUTE ON DBMS_CLOUD_AI       TO ^agent_schema.;
GRANT EXECUTE ON DBMS_CLOUD_AI_AGENT TO ^agent_schema.;
GRANT EXECUTE ON DBMS_CLOUD_ADMIN    TO ^agent_schema.;

-- Standard schema object creation privileges
-- (may already be in place via DWROLE — safe to re-run)
GRANT CREATE PROCEDURE TO ^agent_schema.;
GRANT CREATE TABLE     TO ^agent_schema.;
GRANT CREATE SEQUENCE  TO ^agent_schema.;

-- ============================================================================
-- SECTION 3: OML4Py PRIVILEGES (required for ACME_PYTHON_TOOL)
-- ============================================================================
-- Three grants are required to use pyqEval (Embedded Python Execution) in ADW.
-- Missing ANY ONE of these causes a different error:
--
--   PYQADMIN         — allows ^agent_schema. to create Python scripts in the OML4Py
--                      script repository via sys.pyqScriptCreate / pyqScriptDrop
--                      Without this: ORA-20101 or privilege error on pyqScriptCreate
--
--   OML_DEVELOPER    — registers ^agent_schema. as an OML REST API user
--                      Without this: pyqEval returns HTTP 404 (script not found)
--                      even though the script exists in user_pyq_scripts
--
-- NOTE: pyqSetAuthToken() must also be run as ^agent_schema. after these grants.
--       See SA_03_agent_setup.sql Section 8 for the token setup procedure.
-- ============================================================================

GRANT PYQADMIN      TO ^agent_schema.;
GRANT OML_DEVELOPER TO ^agent_schema.;

-- ============================================================================
-- SECTION 4: EPE-SPECIFIC NETWORK ACL (pyqAppendHostAce)
-- ============================================================================
-- CRITICAL: DBMS_NETWORK_ACL_ADMIN.APPEND_HOST_ACE has NO effect on EPE in ADW.
-- ADW Embedded Python Execution uses a separate OML REST API for script
-- resolution. The correct procedure is pyqAppendHostAce — a PYQSYS-managed
-- ACL mechanism entirely separate from the standard Oracle network ACL system.
--
-- This must be run AFTER granting PYQADMIN and OML_DEVELOPER.
-- The host is the root domain of your ADW OML endpoint.
-- Format: adb.<region>.oraclecloudapps.com
--
-- Without this grant: ORA-20101: Host Access Control List (ACL) not configured
-- ============================================================================

EXEC pyqAppendHostAce('^agent_schema.', '^oml_root_domain.');

-- Verify the EPE ACL was added
SELECT pyqGetHostAce('^agent_schema.') AS epe_acl_entry FROM dual;
-- Expected: returns the ACE entry for ^agent_schema.

-- ============================================================================
-- SECTION 5: IAM POLICY REFERENCE
-- ============================================================================
-- These policies must be created in OCI Console — they cannot be set from SQL.
-- Policy name: <your-policy-name>
-- Compartment: the compartment holding your ADB  |  Region: ^region.
--
-- All 4 statements must be present. Missing any one causes ORA-20052 errors
-- or "No permissions found" errors in the OCI Console policy editor.
--
-- IMPORTANT: The resource type for Select AI (GenAI inference) is
-- generative-ai-family — NOT genai-agent-family (that is for OCI GenAI Agents).
-- ============================================================================

-- Statement 1 — ADW can call OCI GenAI LLM (Llama 3.3) for NL2SQL + agent
--   allow any-user to manage generative-ai-family in compartment <your-compartment>
--   where request.principal.type = 'autonomousdatabase'

-- Statement 2 — ADW can read PDFs from Object Storage to build ACME_VECTOR_INDEX
--   allow any-user to manage object-family in compartment <your-compartment>
--   where request.principal.type = 'autonomousdatabase'

-- Statement 3 — OCI GenAI Agent (App 103 Pages 2&3 — separate from this file)
--   allow any-user to manage genai-agent-family in compartment <your-compartment>
--   where request.principal.type = 'autonomousdatabase'

-- Statement 4 — OCI GenAI Agent can read Object Storage (App 103 Pages 2&3)
--   allow any-user to manage object-family in compartment <your-compartment>
--   where request.principal.type = 'genaiagent'

-- ============================================================================
-- SECTION 6: VERIFY ALL GRANTS
-- ============================================================================

-- 6.1 Resource Principal (granted, not owned -- see Section 1)
SELECT grantee, owner AS granted_by, table_name, privilege
FROM   dba_tab_privs
WHERE  grantee    = '^agent_schema.'
AND    table_name = 'OCI$RESOURCE_PRINCIPAL';
-- Expected: 1 row -- ^agent_schema. | ADMIN | OCI$RESOURCE_PRINCIPAL | EXECUTE

-- 6.2 Package execute grants
SELECT grantee,
       table_name  AS package_name,
       privilege
FROM   dba_tab_privs
WHERE  grantee    = '^agent_schema.'
AND    table_name LIKE 'DBMS_CLOUD%'
ORDER  BY table_name;
-- Expected: 4 rows with EXECUTE on each package

-- 6.3 OML4Py roles
SELECT grantee,
       granted_role,
       admin_option
FROM   dba_role_privs
WHERE  grantee      = '^agent_schema.'
AND    granted_role IN ('PYQADMIN', 'OML_DEVELOPER')
ORDER  BY granted_role;
-- Expected: 2 rows — OML_DEVELOPER and PYQADMIN

-- 6.4 EPE ACL
SELECT pyqGetHostAce('^agent_schema.') AS epe_acl FROM dual;
-- Expected: ACE entry for ^oml_root_domain.

-- ============================================================================
-- END OF FILE: SA_01_ADMIN_setup.sql
-- Next step: Run SA_03_agent_setup.sql as ^agent_schema.
-- ============================================================================
