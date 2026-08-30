--------------------------------------------------------------------------------
--  FILE:    SA_00_CREATE_SCHEMA.sql
--  RUN AS:  ADMIN
--  PURPOSE: Create the ACME_CORP schema.
--
--  MUST RUN BEFORE SA_01_admin_setup.sql. SA_01 opens with
--  DBMS_CLOUD_ADMIN.ENABLE_RESOURCE_PRINCIPAL(username => 'ACME_CORP') and
--  then issues GRANTs to ACME_CORP -- every statement in it assumes the user
--  already exists. On a fresh database SA_01 fails at line 1 with ORA-01918.
--
--  The password is prompted for at run time. It is never stored in this file,
--  never echoed to the terminal (HIDE), and never written to a spool file.
--  Record it somewhere safe -- it is needed later for the OML credential used
--  by the Python (OML4Py) custom tool.
--------------------------------------------------------------------------------

@SA_ENV

SET VERIFY OFF
SET SERVEROUTPUT ON

PROMPT
PROMPT ============================================================
PROMPT  Creating schema ^agent_schema.
PROMPT ============================================================
PROMPT
PROMPT  Password rules (Autonomous Database):
PROMPT    - 12 to 30 characters
PROMPT    - at least one uppercase, one lowercase, one digit
PROMPT    - no double quote ("), and cannot contain the username
PROMPT

ACCEPT new_schema CHAR DEFAULT '^agent_schema.' PROMPT 'Schema to create [^agent_schema.]: '
-- Password source. If vault_secret_ocid is set in SA_ENV.sql the database
-- reads the password straight from OCI Vault using its own Resource Principal,
-- so it is never typed, echoed, or stored. Leave it blank to be prompted.
--
-- Vault-first is the better order: create the secret, then let every consumer
-- read it. Typing the password here AND storing it in Vault separately gives
-- you two copies that can silently drift apart.
--
-- Requires: allow any-user to read secret-bundles in compartment <c>
--           where request.principal.type = 'autonomousdatabase'
ACCEPT acme_pw CHAR PROMPT 'Password for ^new_schema. (Enter to read from Vault): ' HIDE

-- ============================================================================
-- SECTION 1: CREATE USER  (idempotent -- safe to re-run)
-- ============================================================================
DECLARE
    v_exists NUMBER;
    v_pwd    VARCHAR2(4000) := '^acme_pw';
    v_resp   DBMS_CLOUD_TYPES.resp;
    v_b64    VARCHAR2(32767);
BEGIN
    -- No password typed -> fetch it from OCI Vault.
    IF v_pwd IS NULL OR LENGTH(v_pwd) = 0 THEN
        IF '^vault_secret_ocid.' LIKE 'ocid1.vaultsecret%' THEN
            v_resp := DBMS_CLOUD.SEND_REQUEST(
                credential_name => 'OCI$RESOURCE_PRINCIPAL',
                uri  => 'https://secrets.vaults.^region..oci.oraclecloud.com'
                     || '/20190301/secretbundles/^vault_secret_ocid.',
                method => 'GET');
            v_b64 := JSON_VALUE(DBMS_CLOUD.GET_RESPONSE_TEXT(v_resp),
                                '$.secretBundleContent.content');
            v_pwd := UTL_RAW.CAST_TO_VARCHAR2(
                         UTL_ENCODE.BASE64_DECODE(UTL_RAW.CAST_TO_RAW(v_b64)));
            DBMS_OUTPUT.PUT_LINE('Password read from OCI Vault.');
        ELSE
            RAISE_APPLICATION_ERROR(-20001,
                'No password entered and vault_secret_ocid is not set in SA_ENV.sql');
        END IF;
    END IF;

    SELECT COUNT(*) INTO v_exists
    FROM   dba_users
    WHERE  username = '^new_schema.';

    IF v_exists > 0 THEN
        DBMS_OUTPUT.PUT_LINE('^new_schema. already exists -- skipping CREATE USER.');
        DBMS_OUTPUT.PUT_LINE('To reset the password instead, use:');
        DBMS_OUTPUT.PUT_LINE('  ALTER USER ^new_schema. IDENTIFIED BY "<new-password>";');
    ELSE
        EXECUTE IMMEDIATE
            'CREATE USER ^new_schema. IDENTIFIED BY "' || v_pwd || '" '
         || 'DEFAULT TABLESPACE DATA '
         || 'TEMPORARY TABLESPACE TEMP '
         || 'QUOTA UNLIMITED ON DATA';
        DBMS_OUTPUT.PUT_LINE('^new_schema. created.');
    END IF;
END;
/

-- ============================================================================
-- SECTION 2: BASE PRIVILEGES
-- ============================================================================
-- Object-creation privileges the ACME scripts need. SA_01 re-grants a few of
-- these (CREATE TABLE / SEQUENCE / PROCEDURE); re-granting is harmless.
-- DWROLE is the Autonomous Database standard developer role.

GRANT CREATE SESSION   TO ^new_schema.;
GRANT CREATE TABLE     TO ^new_schema.;
GRANT CREATE VIEW      TO ^new_schema.;
GRANT CREATE SEQUENCE  TO ^new_schema.;
GRANT CREATE PROCEDURE TO ^new_schema.;
GRANT CREATE TYPE      TO ^new_schema.;
GRANT CREATE SYNONYM   TO ^new_schema.;
GRANT DWROLE           TO ^new_schema.;

-- ============================================================================
-- SECTION 3: VERIFY
-- ============================================================================
PROMPT
PROMPT --- Schema
SELECT username,
       account_status,
       default_tablespace,
       temporary_tablespace
FROM   dba_users
WHERE  username = '^new_schema.';

PROMPT
PROMPT --- System privileges granted
SELECT privilege
FROM   dba_sys_privs
WHERE  grantee = '^new_schema.'
ORDER  BY privilege;

PROMPT
PROMPT --- Roles granted
SELECT granted_role
FROM   dba_role_privs
WHERE  grantee = '^new_schema.'
ORDER  BY granted_role;

PROMPT
PROMPT ============================================================
PROMPT  Done. Next: SA_01_admin_setup.sql (also as ADMIN)
PROMPT ============================================================
PROMPT

UNDEFINE acme_pw
