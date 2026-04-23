-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 2
-- Script: 07_create_rule_engine_spec.sql
-- Purpose: RULE_ENGINE_PKG package specification
-- ============================================================================

CREATE OR REPLACE PACKAGE rule_engine_pkg
AS
    c_version CONSTANT VARCHAR2(10) := '2.0.0';

    -- ========================================================================
    -- APPLY_RULES
    -- Phase 2 main entry point. Accepts a SELECT query, runs EXPLAIN PLAN,
    -- evaluates all 7 active optimization rules, persists triggered results
    -- into QUERY_RULE_RESULTS, and returns a structured JSON CLOB report.
    --
    -- Parameters:
    --   p_query     IN  CLOB    — The SQL SELECT query to evaluate
    --   p_query_id  IN  NUMBER  — Optional FK to an existing QUERY_PLAN_LOG.ID.
    --                             When NULL the procedure calls Phase 1
    --                             ANALYZE_QUERY internally to create the log row.
    --   p_report    OUT CLOB    — Comprehensive JSON analysis report
    -- ========================================================================
    PROCEDURE apply_rules (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER  DEFAULT NULL,
        p_report    OUT CLOB
    );

    -- ========================================================================
    -- GET_RULE_RESULTS
    -- Returns all triggered rule results for a given QUERY_PLAN_LOG entry,
    -- ordered HIGH → MEDIUM → LOW then by trigger time.
    --
    -- Parameters:
    --   p_query_id  IN  NUMBER          — QUERY_PLAN_LOG.ID to look up
    --   p_result    OUT SYS_REFCURSOR   — Cursor of rule result rows
    -- ========================================================================
    PROCEDURE get_rule_results (
        p_query_id  IN  NUMBER,
        p_result    OUT SYS_REFCURSOR
    );

END rule_engine_pkg;
/

PROMPT >> Package spec RULE_ENGINE_PKG created successfully.
