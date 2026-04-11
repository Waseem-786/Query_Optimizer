-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 1
-- Script: install.sql
-- Purpose: Master install script — runs all SQL files in correct order
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET ECHO ON
SET DEFINE OFF

PROMPT
PROMPT ================================================================
PROMPT  AI-Powered SQL Query Optimizer — Phase 1 Installation
PROMPT  Version: 1.0.0
PROMPT ================================================================
PROMPT

-- Step 1: Create tables
PROMPT >> Step 1/3: Creating tables...
@@../sql/01_create_tables.sql

-- Step 2: Create package specification
PROMPT >> Step 2/3: Creating package specification...
@@../sql/02_create_package_spec.sql

-- Step 3: Create package body
PROMPT >> Step 3/3: Creating package body...
@@../sql/03_create_package_body.sql

PROMPT
PROMPT ================================================================
PROMPT  Installation complete!
PROMPT
PROMPT  Objects created:
PROMPT    - Table:   QUERY_PLAN_LOG
PROMPT    - Package: QUERY_ANALYZER_PKG
PROMPT
PROMPT  To verify:
PROMPT    SELECT object_name, object_type, status
PROMPT    FROM   user_objects
PROMPT    WHERE  object_name IN ('QUERY_PLAN_LOG', 'QUERY_ANALYZER_PKG');
PROMPT ================================================================
PROMPT

-- Show compilation status
SELECT object_name, object_type, status
FROM   user_objects
WHERE  object_name IN ('QUERY_PLAN_LOG', 'QUERY_ANALYZER_PKG')
ORDER BY object_type;
