-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 2
-- Script: 05_create_phase2_tables.sql
-- Purpose: Create OPTIMIZATION_RULES and QUERY_RULE_RESULTS tables
-- ============================================================================

-- Drop dependent table first (FK to optimization_rules)
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE query_rule_results PURGE';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE optimization_rules PURGE';
EXCEPTION
    WHEN OTHERS THEN IF SQLCODE != -942 THEN RAISE; END IF;
END;
/

-- ============================================================================
-- OPTIMIZATION_RULES
-- Master catalogue of all rules evaluated by RULE_ENGINE_PKG.
-- Rules can be toggled on/off via is_active without code changes.
-- ============================================================================
CREATE TABLE optimization_rules (
    rule_id         NUMBER          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    rule_name       VARCHAR2(100)   NOT NULL,
    category        VARCHAR2(50)    NOT NULL,   -- SCAN | PERFORMANCE | STRUCTURE | JOIN
    severity        VARCHAR2(10)    NOT NULL,   -- LOW | MEDIUM | HIGH
    description     VARCHAR2(2000),
    recommendation  CLOB,
    is_active       NUMBER(1)       DEFAULT 1   NOT NULL,
    created_at      TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT uq_or_rule_name  UNIQUE  (rule_name),
    CONSTRAINT chk_or_severity  CHECK   (severity   IN ('LOW', 'MEDIUM', 'HIGH')),
    CONSTRAINT chk_or_active    CHECK   (is_active  IN (0, 1))
);

COMMENT ON TABLE  optimization_rules            IS 'Catalogue of SQL optimization rules evaluated by RULE_ENGINE_PKG';
COMMENT ON COLUMN optimization_rules.rule_name  IS 'Unique machine-readable rule identifier';
COMMENT ON COLUMN optimization_rules.category   IS 'Rule family: SCAN, PERFORMANCE, STRUCTURE, JOIN';
COMMENT ON COLUMN optimization_rules.severity   IS 'Severity level: LOW, MEDIUM, HIGH';
COMMENT ON COLUMN optimization_rules.is_active  IS '1 = actively evaluated, 0 = disabled';

-- ============================================================================
-- QUERY_RULE_RESULTS
-- One row per triggered rule per query analysis run.
-- query_log_id links back to QUERY_PLAN_LOG from Phase 1.
-- ============================================================================
CREATE TABLE query_rule_results (
    result_id               NUMBER          GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    query_log_id            NUMBER,                         -- FK to query_plan_log (nullable for standalone calls)
    rule_id                 NUMBER          NOT NULL,
    rule_name               VARCHAR2(100)   NOT NULL,
    severity                VARCHAR2(10)    NOT NULL,
    context_info            VARCHAR2(4000),                 -- Runtime detail (e.g. which table caused FTS)
    index_recommendation    CLOB,                           -- Generated CREATE INDEX DDL
    optimized_fragment      CLOB,                           -- Suggested SQL rewrite snippet
    triggered_at            TIMESTAMP       DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_qrr_rule_id   FOREIGN KEY (rule_id)      REFERENCES optimization_rules (rule_id),
    CONSTRAINT fk_qrr_log_id    FOREIGN KEY (query_log_id) REFERENCES query_plan_log    (id)
);

COMMENT ON TABLE  query_rule_results                        IS 'Records each triggered optimization rule per query analysis';
COMMENT ON COLUMN query_rule_results.query_log_id           IS 'FK to QUERY_PLAN_LOG; NULL for ad-hoc standalone evaluations';
COMMENT ON COLUMN query_rule_results.context_info           IS 'Runtime context detail explaining why the rule fired';
COMMENT ON COLUMN query_rule_results.index_recommendation   IS 'Generated CREATE INDEX statement for missing-index rule';
COMMENT ON COLUMN query_rule_results.optimized_fragment     IS 'Suggested SQL fragment showing a safer rewrite';

CREATE INDEX idx_qrr_query_log_id ON query_rule_results (query_log_id);
CREATE INDEX idx_qrr_rule_id      ON query_rule_results (rule_id);
CREATE INDEX idx_qrr_severity     ON query_rule_results (severity, triggered_at DESC);

PROMPT >> Phase 2 tables OPTIMIZATION_RULES and QUERY_RULE_RESULTS created successfully.
