-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 2 Installation
-- Script: install_phase2.sql
-- Purpose: Master installer for Phase 2 database objects
-- Prerequisites: Phase 1 must already be installed (run install.sql first).
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO ON
SET DEFINE OFF

PROMPT
PROMPT ================================================================
PROMPT  AI-Powered SQL Query Optimizer — Phase 2 Installation
PROMPT  Version: 2.0.0
PROMPT ================================================================
PROMPT

-- Step 1: Create Phase 2 tables
PROMPT >> Step 1/4: Creating Phase 2 tables...
@@../sql/05_create_phase2_tables.sql

-- Step 2: Seed optimization rules catalogue
PROMPT >> Step 2/4: Seeding optimization rules...
@@../sql/06_seed_optimization_rules.sql

-- Step 3: Create RULE_ENGINE_PKG specification
PROMPT >> Step 3/4: Creating RULE_ENGINE_PKG specification...
@@../sql/07_create_rule_engine_spec.sql

-- Step 4: Create RULE_ENGINE_PKG body
PROMPT >> Step 4/4: Creating RULE_ENGINE_PKG body...
@@../sql/08_create_rule_engine_body.sql

PROMPT
PROMPT ================================================================
PROMPT  Phase 2 Installation Complete!
PROMPT
PROMPT  Objects created:
PROMPT    - Table:    OPTIMIZATION_RULES  (14 rules seeded:
PROMPT                  7 core + 3 deep-analysis + 4 precision)
PROMPT    - Table:    QUERY_RULE_RESULTS
PROMPT    - Package:  RULE_ENGINE_PKG
PROMPT
PROMPT  Quick verification:
PROMPT    SELECT object_name, object_type, status
PROMPT    FROM   user_objects
PROMPT    WHERE  object_name IN
PROMPT           ('OPTIMIZATION_RULES','QUERY_RULE_RESULTS','RULE_ENGINE_PKG')
PROMPT    ORDER BY object_type;
PROMPT
PROMPT  Quick test:
PROMPT    DECLARE l_report CLOB; BEGIN
PROMPT      rule_engine_pkg.apply_rules('SELECT * FROM employees', NULL, l_report);
PROMPT      DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 2000));
PROMPT    END;
PROMPT    /
PROMPT ================================================================
PROMPT

-- Show compilation status
SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('OPTIMIZATION_RULES', 'QUERY_RULE_RESULTS', 'RULE_ENGINE_PKG')
ORDER BY object_type, object_name;

-- Show seeded rules
SELECT rule_name, category, severity
FROM   optimization_rules
ORDER BY CASE severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END, rule_name;
