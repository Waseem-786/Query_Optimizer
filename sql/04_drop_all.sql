-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 1
-- Script: 04_drop_all.sql
-- Purpose: Drop all Phase 1 database objects (cleanup / re-install)
-- ============================================================================

PROMPT >> Dropping QUERY_ANALYZER_PKG...
BEGIN
    EXECUTE IMMEDIATE 'DROP PACKAGE query_analyzer_pkg';
    DBMS_OUTPUT.PUT_LINE('Package dropped.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -4043 THEN RAISE; END IF;
        DBMS_OUTPUT.PUT_LINE('Package does not exist — skipped.');
END;
/

PROMPT >> Dropping QUERY_PLAN_LOG table...
BEGIN
    EXECUTE IMMEDIATE 'DROP TABLE query_plan_log PURGE';
    DBMS_OUTPUT.PUT_LINE('Table dropped.');
EXCEPTION
    WHEN OTHERS THEN
        IF SQLCODE != -942 THEN RAISE; END IF;
        DBMS_OUTPUT.PUT_LINE('Table does not exist — skipped.');
END;
/

PROMPT >> Cleanup complete.
