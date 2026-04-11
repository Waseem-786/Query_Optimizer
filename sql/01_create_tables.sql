-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 1
-- Script: 01_create_tables.sql
-- Purpose: Create logging and storage tables
-- ============================================================================

-- Drop table if exists (for clean re-install)
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE query_plan_log PURGE';
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

-- ============================================================================
-- QUERY_PLAN_LOG
-- Stores every query analysis request along with raw plan and parsed results.
-- ============================================================================
CREATE TABLE query_plan_log (
    id              NUMBER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    query_text      CLOB                    NOT NULL,
    plan_output     CLOB,
    analysis_json   CLOB,
    status          VARCHAR2(20)            DEFAULT 'SUCCESS',
    error_message   VARCHAR2(4000),
    execution_time  NUMBER,                 -- milliseconds to generate plan
    created_at      TIMESTAMP               DEFAULT CURRENT_TIMESTAMP
);

-- Index for time-based lookups
CREATE INDEX idx_qpl_created_at ON query_plan_log (created_at DESC);

-- Comments
COMMENT ON TABLE  query_plan_log                IS 'Stores execution plan analysis logs';
COMMENT ON COLUMN query_plan_log.id             IS 'Auto-generated primary key';
COMMENT ON COLUMN query_plan_log.query_text     IS 'Original SQL query submitted for analysis';
COMMENT ON COLUMN query_plan_log.plan_output    IS 'Raw DBMS_XPLAN output text';
COMMENT ON COLUMN query_plan_log.analysis_json  IS 'Parsed analysis result in JSON format';
COMMENT ON COLUMN query_plan_log.status         IS 'SUCCESS or ERROR';
COMMENT ON COLUMN query_plan_log.error_message  IS 'Error details if status = ERROR';
COMMENT ON COLUMN query_plan_log.execution_time IS 'Time taken to generate plan (ms)';
COMMENT ON COLUMN query_plan_log.created_at     IS 'Timestamp of analysis request';

PROMPT >> Table QUERY_PLAN_LOG created successfully.
