-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 1
-- Script: 02_test_analyze_query.sql
-- Purpose: Functional test cases for QUERY_ANALYZER_PKG.ANALYZE_QUERY
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET LINESIZE 300

PROMPT
PROMPT ================================================================
PROMPT  FUNCTIONAL TESTS — QUERY_ANALYZER_PKG.ANALYZE_QUERY
PROMPT ================================================================
PROMPT

-- ============================================================================
-- TEST 1: Simple SELECT — Full Table Scan (no index on user_id)
-- Expected: Full table scan detected, missing index observation
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('');
    DBMS_OUTPUT.PUT_LINE('=== TEST 1: Simple SELECT (Full Table Scan) ===');
    DBMS_OUTPUT.PUT_LINE('Query: SELECT * FROM orders WHERE user_id = 10');
    DBMS_OUTPUT.PUT_LINE('');

    query_analyzer_pkg.analyze_query(
        p_query  => 'SELECT * FROM orders WHERE user_id = 10',
        p_report => l_report
    );

    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST 2: SELECT with Indexed Column
-- Expected: Index scan detected
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST 2: SELECT with Indexed Column ===');
    DBMS_OUTPUT.PUT_LINE('Query: SELECT * FROM customers WHERE city = ''New York''');
    DBMS_OUTPUT.PUT_LINE('');

    query_analyzer_pkg.analyze_query(
        p_query  => 'SELECT * FROM customers WHERE city = ''New York''',
        p_report => l_report
    );

    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST 3: JOIN Query
-- Expected: Join type detected (hash or nested loops)
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST 3: JOIN Query ===');
    DBMS_OUTPUT.PUT_LINE('Query: SELECT o.order_id, c.first_name ... FROM orders o JOIN customers c ...');
    DBMS_OUTPUT.PUT_LINE('');

    query_analyzer_pkg.analyze_query(
        p_query  => 'SELECT o.order_id, c.first_name, c.last_name, o.total_amount
                      FROM orders o
                      JOIN customers c ON o.customer_id = c.customer_id
                      WHERE o.status = ''COMPLETED''',
        p_report => l_report
    );

    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST 4: Subquery
-- Expected: Successful analysis
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST 4: Subquery ===');
    DBMS_OUTPUT.PUT_LINE('Query: SELECT * FROM customers WHERE customer_id IN (SELECT ...)');
    DBMS_OUTPUT.PUT_LINE('');

    query_analyzer_pkg.analyze_query(
        p_query  => 'SELECT * FROM customers
                      WHERE customer_id IN (
                          SELECT customer_id FROM orders
                          WHERE total_amount > 1000
                      )',
        p_report => l_report
    );

    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST 5: Aggregation Query with GROUP BY
-- Expected: Successful analysis
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST 5: Aggregation Query ===');
    DBMS_OUTPUT.PUT_LINE('Query: SELECT category, COUNT(*), AVG(price) FROM products GROUP BY ...');
    DBMS_OUTPUT.PUT_LINE('');

    query_analyzer_pkg.analyze_query(
        p_query  => 'SELECT category, COUNT(*) AS product_count, AVG(price) AS avg_price
                      FROM products
                      GROUP BY category
                      HAVING COUNT(*) > 1
                      ORDER BY avg_price DESC',
        p_report => l_report
    );

    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST 6: Multi-Table JOIN with Aggregation
-- Expected: Complex plan with joins
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST 6: Complex Multi-Table JOIN ===');
    DBMS_OUTPUT.PUT_LINE('Query: SELECT c.city, SUM(oi.line_total) ... 3 tables joined ...');
    DBMS_OUTPUT.PUT_LINE('');

    query_analyzer_pkg.analyze_query(
        p_query  => 'SELECT c.city,
                            COUNT(DISTINCT o.order_id) AS total_orders,
                            SUM(oi.quantity * oi.unit_price) AS total_revenue
                      FROM customers c
                      JOIN orders o      ON c.customer_id = o.customer_id
                      JOIN order_items oi ON o.order_id    = oi.order_id
                      WHERE o.order_date >= SYSDATE - 180
                      GROUP BY c.city
                      ORDER BY total_revenue DESC',
        p_report => l_report
    );

    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

-- ============================================================================
-- TEST 7: CTE (WITH clause) Query
-- Expected: Successful analysis (WITH is accepted)
-- ============================================================================
DECLARE
    l_report CLOB;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== TEST 7: CTE (WITH clause) Query ===');
    DBMS_OUTPUT.PUT_LINE('Query: WITH top_customers AS (...) SELECT ...');
    DBMS_OUTPUT.PUT_LINE('');

    query_analyzer_pkg.analyze_query(
        p_query  => 'WITH top_customers AS (
                          SELECT customer_id, SUM(total_amount) AS total_spent
                          FROM orders
                          GROUP BY customer_id
                          HAVING SUM(total_amount) > 500
                      )
                      SELECT c.first_name, c.last_name, tc.total_spent
                      FROM top_customers tc
                      JOIN customers c ON tc.customer_id = c.customer_id
                      ORDER BY tc.total_spent DESC',
        p_report => l_report
    );

    DBMS_OUTPUT.PUT_LINE(l_report);
    DBMS_OUTPUT.PUT_LINE('');
END;
/

PROMPT
PROMPT ================================================================
PROMPT  All functional tests completed.
PROMPT  Check QUERY_PLAN_LOG for logged entries:
PROMPT    SELECT id, status, execution_time, created_at
PROMPT    FROM   query_plan_log ORDER BY id;
PROMPT ================================================================
PROMPT
