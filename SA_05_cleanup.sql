-- ^agent_schema. AI AGENT CLEANUP SCRIPT
-- This script removes all components of the ^agent_schema. AI agent setup, including:
-- - AI Profiles
-- - Tools
-- - Agents
-- - Tasks
-- - Teams
-- - Vector Indexes
-- Note: Components are dropped in an order that respects dependencies to avoid errors.

/*
Run these as ^agent_schema. in SQL Developer or Database Actions. 
Each statement is wrapped in its own BEGIN...EXCEPTION WHEN OTHERS THEN NULL; END; 
so they won't stop if an object doesn't exist.
*/

@SA_ENV



-- ── TEAMS (drop first) ────────────────────────────────────────────────────────
BEGIN DBMS_CLOUD_AI_AGENT.DROP_TEAM('ACME_ANALYST_TEAM'); EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- ── ORPHAN TEAM PROFILES (left behind by DROP_TEAM) ──────────────────────────
BEGIN DBMS_CLOUD_AI.DROP_PROFILE('AGENT$ACME_ANALYST_TEAM'); EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- ── TASKS ─────────────────────────────────────────────────────────────────────
BEGIN DBMS_CLOUD_AI_AGENT.DROP_TASK('ACME_ANALYST_TASK'); EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- ── AGENTS ────────────────────────────────────────────────────────────────────
BEGIN DBMS_CLOUD_AI_AGENT.DROP_AGENT('ACME_ANALYST'); EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- ── TOOLS ─────────────────────────────────────────────────────────────────────
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

-- ── AI PROFILES ───────────────────────────────────────────────────────────────
BEGIN DBMS_CLOUD_AI.DROP_PROFILE('ACME_NL2SQL_PROFILE'); EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN DBMS_CLOUD_AI.DROP_PROFILE('ACME_RAG_PROFILE');    EXCEPTION WHEN OTHERS THEN NULL; END;
/

-- ── VECTOR INDEX (drop last) ──────────────────────────────────────────────────
BEGIN DBMS_CLOUD_AI.DROP_VECTOR_INDEX('ACME_VECTOR_INDEX'); EXCEPTION WHEN OTHERS THEN NULL; END;
/


-- After running, verify everything is gone:
SELECT * FROM user_ai_agent_teams;
SELECT * FROM user_ai_agents;
SELECT * FROM user_ai_agent_tasks;
SELECT * FROM user_ai_agent_tools;
SELECT * FROM user_cloud_ai_profiles;