-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 1
-- Script: 02_create_package_spec.sql
-- Purpose: QUERY_ANALYZER_PKG package specification
-- ============================================================================

CREATE OR REPLACE PACKAGE query_analyzer_pkg
AS
    -- ========================================================================
    -- Constants
    -- ========================================================================
    c_version       CONSTANT VARCHAR2(10)  := '1.0.0';
    c_status_ok     CONSTANT VARCHAR2(20)  := 'SUCCESS';
    c_status_err    CONSTANT VARCHAR2(20)  := 'ERROR';

    -- ========================================================================
    -- Custom Record Type — holds parsed execution plan metrics
    -- ========================================================================
    TYPE t_plan_metrics IS RECORD (
        scan_type       VARCHAR2(100),
        cost            NUMBER,
        cardinality     NUMBER,
        index_used      BOOLEAN,
        index_name      VARCHAR2(200),
        join_type       VARCHAR2(100),
        filter_cond     VARCHAR2(4000),
        access_path     VARCHAR2(200),
        observations    VARCHAR2(4000)      -- pipe-delimited observations
    );

    -- ========================================================================
    -- ANALYZE_QUERY
    -- Main entry point. Accepts a SQL query and returns a structured
    -- JSON-like CLOB report with execution plan analysis.
    --
    -- Parameters:
    --   p_query   IN  CLOB   — The SQL query to analyze
    --   p_report  OUT CLOB   — Structured JSON analysis report
    -- ========================================================================
    PROCEDURE analyze_query (
        p_query     IN  CLOB,
        p_report    OUT CLOB
    );

    -- ========================================================================
    -- PARSE_PLAN
    -- Parses raw execution plan text and extracts key performance metrics.
    --
    -- Parameters:
    --   p_plan_text  IN  CLOB   — Raw DBMS_XPLAN output
    --   p_result     OUT CLOB   — Parsed metrics as JSON
    -- ========================================================================
    PROCEDURE parse_plan (
        p_plan_text IN  CLOB,
        p_result    OUT CLOB
    );

    -- ========================================================================
    -- GET_ANALYSIS_HISTORY
    -- Returns recent analysis log entries.
    --
    -- Parameters:
    --   p_limit   IN  NUMBER  — Max rows to return (default 10)
    --   p_result  OUT SYS_REFCURSOR
    -- ========================================================================
    PROCEDURE get_analysis_history (
        p_limit     IN  NUMBER DEFAULT 10,
        p_result    OUT SYS_REFCURSOR
    );

END query_analyzer_pkg;
/

PROMPT >> Package spec QUERY_ANALYZER_PKG created successfully.
