-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 4
-- Script: 05_test_validation_engine.sql
-- Purpose: Test suite for VALIDATION_ENGINE_PKG — 8 functional tests
-- Prerequisites: Phase 1 + 2 + 4 installed; sample data loaded via
--               test/01_setup_sample_data.sql
-- Expected:
--   TEST 1 — decision = ORIGINAL_FASTEST or OPTIMIZED_SELECTED, no errors
--   TEST 2 — decision = OPTIMIZED_SELECTED (explicit JOIN vs implicit cross join)
--   TEST 3 — OPTIMIZED_1 rejected: non-SELECT blocked
--   TEST 4 — ORIGINAL rejected: DELETE blocked
--   TEST 5 — OPTIMIZED_1 rejected: result-set mismatch detected
--   TEST 6 — decision = ORIGINAL_FASTEST (no candidates to beat)
--   TEST 7 — WITH/CTE query accepted and validated
--   TEST 8 — p_iterations = 10 clamped to 5; "iterations_run":5 in output
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET DEFINE OFF

PROMPT
PROMPT ================================================================
PROMPT  Phase 4 — Validation Engine Test Suite (8 tests)
PROMPT ================================================================
PROMPT

-- ============================================================================
-- TEST 1: Valid original + valid optimized query (explicit column list)
-- Expected: both queries valid, results match, winner decided by timing
-- ============================================================================
PROMPT === TEST 1: Valid original + valid optimized query ===
DECLARE
    l_queries validation_engine_pkg.query_list_t;
    l_result  CLOB;
BEGIN
    l_queries(1) :=
        'SELECT customer_id, order_id, total_amount FROM orders WHERE customer_id = 1';
    validation_engine_pkg.validate_and_benchmark(
        p_original_query    =>
            'SELECT customer_id, order_id, total_amount FROM orders o WHERE o.customer_id = 1',
        p_optimized_queries => l_queries,
        p_iterations        => 3,
        p_result            => l_result
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_result, 1, 2000));
END;
/
PROMPT --- TEST 1 DONE ---
PROMPT

-- ============================================================================
-- TEST 2: Multiple optimized candidates — implicit cross join vs ANSI JOIN
-- Expected: OPTIMIZED_1 and OPTIMIZED_2 both valid; fastest selected
-- ============================================================================
PROMPT === TEST 2: Multiple optimized candidates ===
DECLARE
    l_queries validation_engine_pkg.query_list_t;
    l_result  CLOB;
BEGIN
    -- Optimized 1: explicit INNER JOIN
    l_queries(1) :=
        'SELECT o.order_id, c.first_name, o.total_amount ' ||
        'FROM orders o INNER JOIN customers c ON c.customer_id = o.customer_id';
    -- Optimized 2: reversed join order (same result set)
    l_queries(2) :=
        'SELECT o.order_id, c.first_name, o.total_amount ' ||
        'FROM customers c INNER JOIN orders o ON o.customer_id = c.customer_id';
    validation_engine_pkg.validate_and_benchmark(
        p_original_query    =>
            'SELECT o.order_id, c.first_name, o.total_amount ' ||
            'FROM orders o, customers c WHERE c.customer_id = o.customer_id',
        p_optimized_queries => l_queries,
        p_iterations        => 3,
        p_result            => l_result
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_result, 1, 2000));
END;
/
PROMPT --- TEST 2 DONE ---
PROMPT

-- ============================================================================
-- TEST 3: Reject non-SELECT optimized query (INSERT)
-- Expected: OPTIMIZED_1 is_valid = N; decision = ORIGINAL_FASTEST
-- ============================================================================
PROMPT === TEST 3: Reject non-SELECT optimized query ===
DECLARE
    l_queries validation_engine_pkg.query_list_t;
    l_result  CLOB;
BEGIN
    l_queries(1) := 'INSERT INTO orders (customer_id) VALUES (1)';
    validation_engine_pkg.validate_and_benchmark(
        p_original_query    => 'SELECT order_id, status FROM orders WHERE status = ''PENDING''',
        p_optimized_queries => l_queries,
        p_iterations        => 3,
        p_result            => l_result
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_result, 1, 2000));
END;
/
PROMPT --- TEST 3 DONE (INSERT rejected) ---
PROMPT

-- ============================================================================
-- TEST 4: Reject original query that is not SELECT (DELETE)
-- Expected: ORIGINAL is_valid = N; decision = NO_VALID_QUERY
-- ============================================================================
PROMPT === TEST 4: Reject non-SELECT original query ===
DECLARE
    l_queries validation_engine_pkg.query_list_t;
    l_result  CLOB;
BEGIN
    l_queries(1) := 'SELECT order_id FROM orders';
    validation_engine_pkg.validate_and_benchmark(
        p_original_query    => 'DELETE FROM orders WHERE 1 = 2',
        p_optimized_queries => l_queries,
        p_iterations        => 3,
        p_result            => l_result
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_result, 1, 2000));
END;
/
PROMPT --- TEST 4 DONE (DELETE rejected) ---
PROMPT

-- ============================================================================
-- TEST 5: Detect result-set mismatch (different WHERE predicate value)
-- Expected: OPTIMIZED_1 is_valid = N; results_match = NO; diff_row_count > 0
-- ============================================================================
PROMPT === TEST 5: Detect result-set mismatch ===
DECLARE
    l_queries validation_engine_pkg.query_list_t;
    l_result  CLOB;
BEGIN
    -- Intentionally wrong: different customer_id filter returns a different set
    l_queries(1) :=
        'SELECT customer_id, order_id, total_amount FROM orders WHERE customer_id = 2';
    validation_engine_pkg.validate_and_benchmark(
        p_original_query    =>
            'SELECT customer_id, order_id, total_amount FROM orders WHERE customer_id = 1',
        p_optimized_queries => l_queries,
        p_iterations        => 3,
        p_result            => l_result
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_result, 1, 2000));
END;
/
PROMPT --- TEST 5 DONE (mismatch detected) ---
PROMPT

-- ============================================================================
-- TEST 6: Empty optimized query list — only the original is benchmarked
-- Expected: decision = ORIGINAL_FASTEST; benchmarks array has one entry
-- ============================================================================
PROMPT === TEST 6: Empty optimized query list ===
DECLARE
    l_queries validation_engine_pkg.query_list_t;
    l_result  CLOB;
BEGIN
    l_queries.DELETE;  -- no candidates
    validation_engine_pkg.validate_and_benchmark(
        p_original_query    => 'SELECT customer_id, first_name, city FROM customers',
        p_optimized_queries => l_queries,
        p_iterations        => 3,
        p_result            => l_result
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_result, 1, 2000));
END;
/
PROMPT --- TEST 6 DONE (no candidates) ---
PROMPT

-- ============================================================================
-- TEST 7: WITH / CTE query accepted and validated against IN-subquery original
-- Expected: both queries valid; results_match = YES
-- ============================================================================
PROMPT === TEST 7: WITH (CTE) query accepted ===
DECLARE
    l_queries validation_engine_pkg.query_list_t;
    l_result  CLOB;
BEGIN
    -- Original: correlated IN-subquery
    -- Optimized: semantically equivalent CTE + JOIN
    l_queries(1) :=
        'WITH repeat_buyers AS (' ||
        '  SELECT customer_id FROM orders GROUP BY customer_id HAVING COUNT(*) > 1' ||
        ') ' ||
        'SELECT c.customer_id, c.first_name, c.last_name ' ||
        'FROM customers c JOIN repeat_buyers rb ON rb.customer_id = c.customer_id';
    validation_engine_pkg.validate_and_benchmark(
        p_original_query    =>
            'SELECT c.customer_id, c.first_name, c.last_name ' ||
            'FROM customers c ' ||
            'WHERE c.customer_id IN ' ||
            '  (SELECT customer_id FROM orders GROUP BY customer_id HAVING COUNT(*) > 1)',
        p_optimized_queries => l_queries,
        p_iterations        => 3,
        p_result            => l_result
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_result, 1, 2000));
END;
/
PROMPT --- TEST 7 DONE (CTE accepted and compared) ---
PROMPT

-- ============================================================================
-- TEST 8: p_iterations clamping — value > 5 is clamped to 5
-- Expected: "iterations_run":5 in JSON output
-- ============================================================================
PROMPT === TEST 8: Iterations clamped from 10 to 5 ===
DECLARE
    l_queries validation_engine_pkg.query_list_t;
    l_result  CLOB;
BEGIN
    l_queries(1) :=
        'SELECT product_id, product_name, price FROM products WHERE is_active = 1';
    validation_engine_pkg.validate_and_benchmark(
        p_original_query    =>
            'SELECT product_id, product_name, price FROM products WHERE is_active = 1',
        p_optimized_queries => l_queries,
        p_iterations        => 10,   -- will be clamped to 5
        p_result            => l_result
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_result, 1, 2000));
END;
/
PROMPT --- TEST 8 DONE (iterations_run should be 5) ---
PROMPT

PROMPT ================================================================
PROMPT  Phase 4 Test Suite Complete — 8 tests executed
PROMPT ================================================================
