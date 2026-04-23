-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 2
-- Script: 04_test_rule_engine.sql
-- Purpose: Functional test suite for RULE_ENGINE_PKG (APPLY_RULES)
-- Prerequisites: install_phase2.sql + test/01_setup_sample_data.sql
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO ON

PROMPT
PROMPT ================================================================
PROMPT  RULE_ENGINE_PKG — Phase 2 Test Suite
PROMPT ================================================================
PROMPT

-- ============================================================================
-- TEST 1: SELECT * — should trigger SELECT_STAR_DETECTED (MEDIUM)
-- ============================================================================
PROMPT >> TEST 1: SELECT * detection
DECLARE
    l_report CLOB;
BEGIN
    rule_engine_pkg.apply_rules(
        p_query    => 'SELECT * FROM employees',
        p_report   => l_report
    );
    DBMS_OUTPUT.PUT_LINE('Status length: ' || DBMS_LOB.GETLENGTH(l_report));
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 500));
END;
/

-- ============================================================================
-- TEST 2: Full Table Scan + Missing Index — should trigger both HIGH rules
-- ============================================================================
PROMPT >> TEST 2: Full table scan on large table (WHERE on unindexed column)
DECLARE
    l_report CLOB;
BEGIN
    rule_engine_pkg.apply_rules(
        p_query    => 'SELECT employee_id, first_name FROM employees WHERE salary > 50000',
        p_report   => l_report
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 1000));
END;
/

-- ============================================================================
-- TEST 3: Function on column — should trigger FUNCTION_ON_INDEXED_COLUMN
-- ============================================================================
PROMPT >> TEST 3: UPPER() on column in WHERE clause
DECLARE
    l_report CLOB;
BEGIN
    rule_engine_pkg.apply_rules(
        p_query    => 'SELECT employee_id FROM employees WHERE UPPER(last_name) = ''SMITH''',
        p_report   => l_report
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 800));
END;
/

-- ============================================================================
-- TEST 4: IN subquery — should trigger SUBQUERY_CANDIDATE_FOR_JOIN
-- ============================================================================
PROMPT >> TEST 4: IN (SELECT ...) subquery pattern
DECLARE
    l_report CLOB;
BEGIN
    rule_engine_pkg.apply_rules(
        p_query    => 'SELECT * FROM orders WHERE customer_id IN (SELECT customer_id FROM customers WHERE country = ''US'')',
        p_report   => l_report
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 800));
END;
/

-- ============================================================================
-- TEST 5: EXISTS subquery — should trigger SUBQUERY_CANDIDATE_FOR_JOIN
-- ============================================================================
PROMPT >> TEST 5: EXISTS (SELECT ...) subquery pattern
DECLARE
    l_report CLOB;
BEGIN
    rule_engine_pkg.apply_rules(
        p_query    => 'SELECT o.order_id FROM orders o WHERE EXISTS (SELECT 1 FROM order_items oi WHERE oi.order_id = o.order_id AND oi.quantity > 10)',
        p_report   => l_report
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 800));
END;
/

-- ============================================================================
-- TEST 6: SELECT DISTINCT — should trigger UNNECESSARY_DISTINCT (LOW)
-- ============================================================================
PROMPT >> TEST 6: SELECT DISTINCT usage
DECLARE
    l_report CLOB;
BEGIN
    rule_engine_pkg.apply_rules(
        p_query    => 'SELECT DISTINCT department_id FROM employees ORDER BY department_id',
        p_report   => l_report
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 600));
END;
/

-- ============================================================================
-- TEST 7: Multiple rules in one query
-- Triggers: SELECT_STAR + FULL_TABLE_SCAN + SELECT_DISTINCT
-- ============================================================================
PROMPT >> TEST 7: Multiple simultaneous rule violations
DECLARE
    l_report CLOB;
BEGIN
    rule_engine_pkg.apply_rules(
        p_query    => 'SELECT DISTINCT * FROM orders WHERE TO_DATE(order_date) = SYSDATE',
        p_report   => l_report
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 1500));
END;
/

-- ============================================================================
-- TEST 8: Clean, indexed query — should trigger zero rules
-- ============================================================================
PROMPT >> TEST 8: Optimized query — expect 0 rules triggered
DECLARE
    l_report CLOB;
BEGIN
    rule_engine_pkg.apply_rules(
        p_query    => 'SELECT o.order_id, o.amount FROM orders o INNER JOIN customers c ON c.customer_id = o.customer_id WHERE o.order_id = 12345',
        p_report   => l_report
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 600));
END;
/

-- ============================================================================
-- TEST 9: NULL input — should return ERROR JSON
-- ============================================================================
PROMPT >> TEST 9: NULL query input — expect error response
DECLARE
    l_report CLOB;
BEGIN
    rule_engine_pkg.apply_rules(
        p_query    => NULL,
        p_report   => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
END;
/

-- ============================================================================
-- TEST 10: Non-SELECT input — should return ERROR JSON
-- ============================================================================
PROMPT >> TEST 10: DML/DDL input — expect error response
DECLARE
    l_report CLOB;
BEGIN
    rule_engine_pkg.apply_rules(
        p_query    => 'DELETE FROM employees WHERE employee_id = 1',
        p_report   => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
END;
/

-- ============================================================================
-- TEST 11: GET_RULE_RESULTS — verify persistence
-- ============================================================================
PROMPT >> TEST 11: GET_RULE_RESULTS cursor for most recent analysis
DECLARE
    l_report    CLOB;
    l_cursor    SYS_REFCURSOR;
    l_log_id    NUMBER;
    l_rule_name VARCHAR2(100);
    l_category  VARCHAR2(50);
    l_severity  VARCHAR2(10);
    l_desc      VARCHAR2(2000);
    l_ctx       VARCHAR2(4000);
    l_idx_rec   CLOB;
    l_frag      CLOB;
    l_ts        TIMESTAMP;
BEGIN
    -- Run analysis to generate results
    rule_engine_pkg.apply_rules(
        p_query  => 'SELECT * FROM orders WHERE TO_DATE(created_at) = SYSDATE',
        p_report => l_report
    );

    -- Fetch latest log ID
    SELECT id INTO l_log_id
    FROM   (SELECT id FROM query_plan_log ORDER BY created_at DESC)
    WHERE  ROWNUM = 1;

    DBMS_OUTPUT.PUT_LINE('Log ID: ' || l_log_id);

    -- Retrieve rule results
    rule_engine_pkg.get_rule_results(l_log_id, l_cursor);
    LOOP
        FETCH l_cursor INTO l_log_id, l_rule_name, l_category, l_severity,
                            l_desc, l_ctx, l_idx_rec, l_frag, l_ts;
        EXIT WHEN l_cursor%NOTFOUND;
        DBMS_OUTPUT.PUT_LINE('[' || l_severity || '] ' || l_rule_name || ' — ' || SUBSTR(l_ctx, 1, 80));
    END LOOP;
    CLOSE l_cursor;
END;
/

-- ============================================================================
-- Summary: count results by severity across all Phase 2 runs
-- ============================================================================
PROMPT >> Summary: Rule results by severity
SELECT
    severity,
    COUNT(*) AS total_triggered,
    COUNT(DISTINCT query_log_id) AS distinct_queries
FROM query_rule_results
GROUP BY severity
ORDER BY CASE severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END;
