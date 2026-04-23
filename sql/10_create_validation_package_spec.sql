-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 4
-- Script: 10_create_validation_package_spec.sql
-- Purpose: VALIDATION_ENGINE_PKG package specification
-- ============================================================================

CREATE OR REPLACE PACKAGE validation_engine_pkg
AS
    c_version CONSTANT VARCHAR2(10) := '4.0.0';

    -- Associative array: caller populates index 1..N with optimized queries
    TYPE query_list_t IS TABLE OF CLOB INDEX BY PLS_INTEGER;

    -- ========================================================================
    -- VALIDATE_AND_BENCHMARK
    -- Phase 4 main entry point.
    --
    -- For each candidate query the procedure:
    --   1. Enforces SELECT-only policy
    --   2. Verifies result-set correctness vs the original using MINUS
    --   3. Times N execution iterations using a COUNT(*) wrapper
    --   4. Persists every result row to QUERY_BENCHMARK
    --   5. Returns a JSON CLOB report with the winning recommendation
    --
    -- Parameters:
    --   p_original_query    IN  CLOB          — The baseline SELECT query
    --   p_optimized_queries IN  query_list_t  — 1-indexed list of optimized queries
    --   p_iterations        IN  NUMBER        — Benchmark repetitions (clamped 1–5; default 3)
    --   p_query_log_id      IN  NUMBER        — Optional FK to an existing QUERY_PLAN_LOG.ID
    --   p_result            OUT CLOB          — JSON benchmark report
    -- ========================================================================
    PROCEDURE validate_and_benchmark (
        p_original_query    IN  CLOB,
        p_optimized_queries IN  query_list_t,
        p_iterations        IN  NUMBER  DEFAULT 3,
        p_query_log_id      IN  NUMBER  DEFAULT NULL,
        p_result            OUT CLOB
    );

    -- ========================================================================
    -- GET_BENCHMARK_RESULTS
    -- Returns all benchmark rows for a given QUERY_PLAN_LOG entry,
    -- ordered by validity then average execution time ascending.
    --
    -- Parameters:
    --   p_query_log_id  IN  NUMBER          — QUERY_PLAN_LOG.ID to look up
    --   p_result        OUT SYS_REFCURSOR   — Cursor of benchmark rows
    -- ========================================================================
    PROCEDURE get_benchmark_results (
        p_query_log_id  IN  NUMBER,
        p_result        OUT SYS_REFCURSOR
    );

END validation_engine_pkg;
/

PROMPT >> Package spec VALIDATION_ENGINE_PKG created successfully.
