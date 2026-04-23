-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 4 Installation
-- Script: install_phase4.sql
-- Purpose: Master installer for Phase 4 database objects
-- Prerequisites: Phase 1 and Phase 2 must already be installed.
--               Run install.sql then install_phase2.sql first.
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO ON
SET DEFINE OFF

PROMPT
PROMPT ================================================================
PROMPT  AI-Powered SQL Query Optimizer — Phase 4 Installation
PROMPT  Version: 4.0.0
PROMPT ================================================================
PROMPT

-- Step 1: Create QUERY_BENCHMARK table
PROMPT >> Step 1/3: Creating QUERY_BENCHMARK table...
@@../sql/09_create_benchmark_table.sql

-- Step 2: Create VALIDATION_ENGINE_PKG specification
PROMPT >> Step 2/3: Creating VALIDATION_ENGINE_PKG specification...
@@../sql/10_create_validation_package_spec.sql

-- Step 3: Create VALIDATION_ENGINE_PKG body
PROMPT >> Step 3/3: Creating VALIDATION_ENGINE_PKG body...
@@../sql/11_create_validation_package_body.sql

PROMPT
PROMPT ================================================================
PROMPT  Phase 4 Installation Complete!
PROMPT
PROMPT  Objects created:
PROMPT    - Table:    QUERY_BENCHMARK
PROMPT    - Package:  VALIDATION_ENGINE_PKG
PROMPT
PROMPT  Quick verification:
PROMPT    SELECT object_name, object_type, status
PROMPT    FROM   user_objects
PROMPT    WHERE  object_name IN
PROMPT           ('QUERY_BENCHMARK','VALIDATION_ENGINE_PKG')
PROMPT    ORDER BY object_type;
PROMPT
PROMPT  Quick test:
PROMPT    DECLARE
PROMPT      l_queries validation_engine_pkg.query_list_t;
PROMPT      l_result  CLOB;
PROMPT    BEGIN
PROMPT      l_queries(1) :=
PROMPT        'SELECT customer_id, order_id, total_amount FROM orders WHERE customer_id = 1';
PROMPT      validation_engine_pkg.validate_and_benchmark(
PROMPT        p_original_query    =>
PROMPT          'SELECT customer_id, order_id, total_amount FROM orders WHERE customer_id = 1',
PROMPT        p_optimized_queries => l_queries,
PROMPT        p_iterations        => 3,
PROMPT        p_result            => l_result
PROMPT      );
PROMPT      DBMS_OUTPUT.PUT_LINE(SUBSTR(l_result, 1, 2000));
PROMPT    END;
PROMPT    /
PROMPT ================================================================
PROMPT

-- Show compilation status
SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('QUERY_BENCHMARK', 'VALIDATION_ENGINE_PKG')
ORDER BY object_type, object_name;
