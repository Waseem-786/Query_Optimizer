-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 1
-- Script: 03_test_error_handling.sql
-- Purpose: Error handling test cases for QUERY_ANALYZER_PKG.ANALYZE_QUERY
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 300

PROMPT
PROMPT ================================================================
PROMPT  ERROR HANDLING TESTS — QUERY_ANALYZER_PKG.ANALYZE_QUERY
PROMPT ================================================================
PROMPT

-- ============================================================================
-- TEST E1: NULL input
-- Expected: ERROR — "Query input is NULL or empty"
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST E1: NULL Input ===');
    query_analyzer_pkg.analyze_query(
        p_query  => NULL,
        p_report => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST E2: Empty string
-- Expected: ERROR — "Query input is NULL or empty"
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST E2: Empty String ===');
    query_analyzer_pkg.analyze_query(
        p_query  => '',
        p_report => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST E3: INSERT statement (DML rejected)
-- Expected: ERROR — "Only SELECT queries are supported"
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST E3: INSERT Statement ===');
    query_analyzer_pkg.analyze_query(
        p_query  => 'INSERT INTO customers (first_name, last_name, email) VALUES (''Test'', ''User'', ''test@test.com'')',
        p_report => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST E4: UPDATE statement (DML rejected)
-- Expected: ERROR — "Only SELECT queries are supported"
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST E4: UPDATE Statement ===');
    query_analyzer_pkg.analyze_query(
        p_query  => 'UPDATE customers SET city = ''London'' WHERE customer_id = 1',
        p_report => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST E5: DELETE statement (DML rejected)
-- Expected: ERROR — "Only SELECT queries are supported"
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST E5: DELETE Statement ===');
    query_analyzer_pkg.analyze_query(
        p_query  => 'DELETE FROM customers WHERE customer_id = 999',
        p_report => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST E6: DROP TABLE (DDL rejected)
-- Expected: ERROR — "DML/DDL statements are not allowed"
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST E6: DROP TABLE Statement ===');
    query_analyzer_pkg.analyze_query(
        p_query  => 'DROP TABLE customers',
        p_report => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST E7: Invalid SQL syntax
-- Expected: ERROR — "Failed to generate execution plan"
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST E7: Invalid SQL Syntax ===');
    query_analyzer_pkg.analyze_query(
        p_query  => 'SELEC * FORM nonexistent_table',
        p_report => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST E8: Non-existent table
-- Expected: ERROR — "Failed to generate execution plan"
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST E8: Non-existent Table ===');
    query_analyzer_pkg.analyze_query(
        p_query  => 'SELECT * FROM this_table_does_not_exist WHERE id = 1',
        p_report => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST E9: GRANT statement (privilege command rejected)
-- Expected: ERROR — "DML/DDL statements are not allowed"
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST E9: GRANT Statement ===');
    query_analyzer_pkg.analyze_query(
        p_query  => 'GRANT SELECT ON customers TO public',
        p_report => l_report
    );
    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

PROMPT
PROMPT ================================================================
PROMPT  All error handling tests completed.
PROMPT  Verify all tests returned "status": "ERROR"
PROMPT ================================================================
PROMPT
