-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 4
-- Script: 09_create_benchmark_table.sql
-- Purpose: QUERY_BENCHMARK table and sequence for storing per-query benchmark results
-- ============================================================================

-- Drop existing objects (clean reinstall)
BEGIN EXECUTE IMMEDIATE 'DROP TABLE query_benchmark PURGE'; EXCEPTION WHEN OTHERS THEN NULL; END;
/
BEGIN EXECUTE IMMEDIATE 'DROP SEQUENCE query_benchmark_seq'; EXCEPTION WHEN OTHERS THEN NULL; END;
/

CREATE SEQUENCE query_benchmark_seq
    START WITH 1
    INCREMENT BY 1
    NOCACHE
    NOCYCLE;

CREATE TABLE query_benchmark (
    benchmark_id      NUMBER          DEFAULT query_benchmark_seq.NEXTVAL
                                      CONSTRAINT pk_query_benchmark PRIMARY KEY,
    query_log_id      NUMBER          CONSTRAINT fk_qb_query_log
                                      REFERENCES query_plan_log(id) ON DELETE SET NULL,
    query_label       VARCHAR2(50)    NOT NULL,
    query_text        CLOB            NOT NULL,
    is_valid          CHAR(1)         DEFAULT 'N' NOT NULL
                                      CONSTRAINT chk_qb_is_valid CHECK (is_valid IN ('Y','N')),
    validation_msg    VARCHAR2(4000),
    result_row_count  NUMBER          DEFAULT 0,
    results_match     VARCHAR2(3)     CONSTRAINT chk_qb_match
                                      CHECK (results_match IN ('YES','NO','N/A')),
    diff_row_count    NUMBER          DEFAULT 0,
    iter_count        NUMBER          DEFAULT 0,
    avg_exec_ms       NUMBER(12,3),
    min_exec_ms       NUMBER(12,3),
    max_exec_ms       NUMBER(12,3),
    created_at        TIMESTAMP       DEFAULT SYSTIMESTAMP NOT NULL
);

COMMENT ON TABLE  query_benchmark              IS 'Phase 4: per-query benchmark rows written by VALIDATION_ENGINE_PKG';
COMMENT ON COLUMN query_benchmark.query_label  IS 'ORIGINAL | OPTIMIZED_1 | OPTIMIZED_2 ...';
COMMENT ON COLUMN query_benchmark.results_match IS 'YES if result set matches original; NO if different; N/A for the original itself';

PROMPT >> Table QUERY_BENCHMARK created successfully.
