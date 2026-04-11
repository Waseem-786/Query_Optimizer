-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 1
-- Script: 03_create_package_body.sql
-- Purpose: QUERY_ANALYZER_PKG package body — full implementation
-- ============================================================================

CREATE OR REPLACE PACKAGE BODY query_analyzer_pkg
AS

    -- ========================================================================
    -- PRIVATE: validate_query
    -- Ensures the input is a non-null SELECT statement.
    -- Returns NULL on success, or an error message string on failure.
    -- ========================================================================
    FUNCTION validate_query (p_query IN CLOB)
        RETURN VARCHAR2
    IS
        l_trimmed   VARCHAR2(32767);
    BEGIN
        -- Null check
        IF p_query IS NULL OR DBMS_LOB.GETLENGTH(p_query) = 0 THEN
            RETURN 'Query input is NULL or empty';
        END IF;

        -- Get first 200 chars, trim and uppercase for keyword check
        l_trimmed := UPPER(TRIM(DBMS_LOB.SUBSTR(p_query, 200, 1)));

        -- Must start with SELECT or WITH (CTE)
        IF l_trimmed NOT LIKE 'SELECT%' AND l_trimmed NOT LIKE 'WITH%' THEN
            RETURN 'Only SELECT queries are supported in Phase 1';
        END IF;

        -- Reject dangerous keywords anywhere in the query
        IF    INSTR(UPPER(p_query), 'INSERT ')  > 0
           OR INSTR(UPPER(p_query), 'UPDATE ')  > 0
           OR INSTR(UPPER(p_query), 'DELETE ')  > 0
           OR INSTR(UPPER(p_query), 'DROP ')    > 0
           OR INSTR(UPPER(p_query), 'ALTER ')   > 0
           OR INSTR(UPPER(p_query), 'TRUNCATE') > 0
           OR INSTR(UPPER(p_query), 'CREATE ')  > 0
           OR INSTR(UPPER(p_query), 'GRANT ')   > 0
           OR INSTR(UPPER(p_query), 'REVOKE ')  > 0
        THEN
            RETURN 'DML/DDL statements are not allowed — SELECT only';
        END IF;

        RETURN NULL; -- valid
    END validate_query;

    -- ========================================================================
    -- PRIVATE: build_error_response
    -- Constructs a JSON error response.
    -- ========================================================================
    FUNCTION build_error_response (p_message IN VARCHAR2)
        RETURN CLOB
    IS
        l_json CLOB;
    BEGIN
        l_json := '{' || CHR(10)
            || '  "status": "' || c_status_err || '",' || CHR(10)
            || '  "message": "' || REPLACE(p_message, '"', '\"') || '"' || CHR(10)
            || '}';
        RETURN l_json;
    END build_error_response;

    -- ========================================================================
    -- PRIVATE: extract_metric
    -- Extracts a numeric value from a plan line based on a label.
    -- Example line: "   Cost (%CPU): 125 (0%)"  → returns 125
    -- ========================================================================
    FUNCTION extract_number_after (
        p_text   IN VARCHAR2,
        p_label  IN VARCHAR2
    ) RETURN NUMBER
    IS
        l_pos    NUMBER;
        l_substr VARCHAR2(100);
        l_num    VARCHAR2(50);
        l_char   CHAR(1);
    BEGIN
        l_pos := INSTR(UPPER(p_text), UPPER(p_label));
        IF l_pos = 0 THEN
            RETURN NULL;
        END IF;

        l_substr := SUBSTR(p_text, l_pos + LENGTH(p_label), 50);

        -- Extract first number sequence
        l_num := '';
        FOR i IN 1..LENGTH(l_substr) LOOP
            l_char := SUBSTR(l_substr, i, 1);
            IF l_char BETWEEN '0' AND '9' OR l_char = '.' THEN
                l_num := l_num || l_char;
            ELSIF LENGTH(l_num) > 0 THEN
                EXIT;
            END IF;
        END LOOP;

        IF l_num IS NOT NULL AND LENGTH(l_num) > 0 THEN
            RETURN TO_NUMBER(l_num);
        END IF;

        RETURN NULL;
    EXCEPTION
        WHEN OTHERS THEN RETURN NULL;
    END extract_number_after;

    -- ========================================================================
    -- PARSE_PLAN  (Public)
    -- Parses raw DBMS_XPLAN output and produces a JSON metrics report.
    -- ========================================================================
    PROCEDURE parse_plan (
        p_plan_text IN  CLOB,
        p_result    OUT CLOB
    )
    IS
        l_metrics       t_plan_metrics;
        l_line          VARCHAR2(4000);
        l_upper_line    VARCHAR2(4000);
        l_plan_upper    CLOB;
        l_obs           VARCHAR2(4000) := '';
        l_offset        NUMBER := 1;
        l_len           NUMBER;
        l_newline_pos   NUMBER;
        l_max_cost      NUMBER := 0;
        l_max_rows      NUMBER := 0;
        l_has_full_scan BOOLEAN := FALSE;
        l_has_index     BOOLEAN := FALSE;
        l_index_name    VARCHAR2(200) := '';
        l_join_type     VARCHAR2(100) := '';
        l_filter        VARCHAR2(4000) := '';
        l_access_path   VARCHAR2(200) := '';
    BEGIN
        IF p_plan_text IS NULL OR DBMS_LOB.GETLENGTH(p_plan_text) = 0 THEN
            p_result := build_error_response('Empty execution plan');
            RETURN;
        END IF;

        l_plan_upper := UPPER(p_plan_text);
        l_len := DBMS_LOB.GETLENGTH(p_plan_text);

        -- ----------------------------------------------------------------
        -- Line-by-line scan of the execution plan
        -- ----------------------------------------------------------------
        WHILE l_offset <= l_len LOOP
            -- Find next newline
            l_newline_pos := DBMS_LOB.INSTR(p_plan_text, CHR(10), l_offset);
            IF l_newline_pos = 0 THEN
                l_newline_pos := l_len + 1;
            END IF;

            -- Extract current line
            IF l_newline_pos - l_offset > 0 THEN
                l_line := DBMS_LOB.SUBSTR(p_plan_text,
                            LEAST(l_newline_pos - l_offset, 4000),
                            l_offset);
            ELSE
                l_line := '';
            END IF;
            l_upper_line := UPPER(TRIM(l_line));

            -- Detect scan types
            IF INSTR(l_upper_line, 'TABLE ACCESS FULL') > 0 THEN
                l_has_full_scan := TRUE;
                l_access_path  := 'TABLE ACCESS FULL';
            END IF;

            IF INSTR(l_upper_line, 'INDEX RANGE SCAN') > 0 THEN
                l_has_index   := TRUE;
                l_access_path := 'INDEX RANGE SCAN';
            ELSIF INSTR(l_upper_line, 'INDEX UNIQUE SCAN') > 0 THEN
                l_has_index   := TRUE;
                l_access_path := 'INDEX UNIQUE SCAN';
            ELSIF INSTR(l_upper_line, 'INDEX FULL SCAN') > 0 THEN
                l_has_index   := TRUE;
                l_access_path := 'INDEX FULL SCAN';
            ELSIF INSTR(l_upper_line, 'INDEX FAST FULL SCAN') > 0 THEN
                l_has_index   := TRUE;
                l_access_path := 'INDEX FAST FULL SCAN';
            ELSIF INSTR(l_upper_line, 'INDEX SKIP SCAN') > 0 THEN
                l_has_index   := TRUE;
                l_access_path := 'INDEX SKIP SCAN';
            END IF;

            -- Detect join types
            IF INSTR(l_upper_line, 'NESTED LOOPS') > 0 THEN
                l_join_type := 'NESTED LOOPS';
            ELSIF INSTR(l_upper_line, 'HASH JOIN') > 0 THEN
                l_join_type := 'HASH JOIN';
            ELSIF INSTR(l_upper_line, 'MERGE JOIN') > 0 THEN
                l_join_type := 'MERGE JOIN';
            ELSIF INSTR(l_upper_line, 'SORT MERGE') > 0 THEN
                l_join_type := 'SORT MERGE JOIN';
            END IF;

            -- Detect filter predicates
            IF INSTR(l_upper_line, 'FILTER') > 0
               AND INSTR(l_upper_line, 'PREDICATE') = 0
               AND INSTR(l_upper_line, '- FILTER') = 0
            THEN
                NULL; -- skip generic FILTER operations
            END IF;

            IF INSTR(l_upper_line, 'ACCESS(') > 0
               OR INSTR(l_upper_line, 'FILTER(') > 0
            THEN
                l_filter := l_filter || TRIM(l_line) || '; ';
            END IF;

            -- Extract cost and rows from plan table format
            -- Typical format: |  0 | SELECT STATEMENT  |      |    10 |   500 |     5   (0)|
            DECLARE
                l_cost_val NUMBER;
                l_rows_val NUMBER;
            BEGIN
                l_cost_val := extract_number_after(l_line, 'Cost (%CPU):');
                IF l_cost_val IS NULL THEN
                    -- Try pipe-delimited format — cost is usually 6th column
                    IF INSTR(l_line, '|') > 0 THEN
                        DECLARE
                            l_parts   VARCHAR2(4000) := l_line;
                            l_pipe1   NUMBER;
                            l_pipe2   NUMBER;
                            l_col     NUMBER := 0;
                            l_val     VARCHAR2(200);
                        BEGIN
                            WHILE INSTR(l_parts, '|') > 0 LOOP
                                l_pipe1 := INSTR(l_parts, '|');
                                l_val   := TRIM(SUBSTR(l_parts, 1, l_pipe1 - 1));
                                l_parts := SUBSTR(l_parts, l_pipe1 + 1);
                                l_col   := l_col + 1;

                                -- Column 5 = Rows, Column 6 = Bytes, Column 7 = Cost
                                IF l_col = 5 THEN
                                    BEGIN
                                        l_rows_val := TO_NUMBER(REGEXP_REPLACE(l_val, '[^0-9.]', ''));
                                    EXCEPTION WHEN OTHERS THEN NULL;
                                    END;
                                ELSIF l_col = 7 THEN
                                    BEGIN
                                        l_cost_val := TO_NUMBER(REGEXP_REPLACE(l_val, '[^0-9.]', ''));
                                    EXCEPTION WHEN OTHERS THEN NULL;
                                    END;
                                END IF;
                            END LOOP;
                        END;
                    END IF;
                END IF;

                IF l_cost_val IS NOT NULL AND l_cost_val > l_max_cost THEN
                    l_max_cost := l_cost_val;
                END IF;
                IF l_rows_val IS NOT NULL AND l_rows_val > l_max_rows THEN
                    l_max_rows := l_rows_val;
                END IF;
            END;

            l_offset := l_newline_pos + 1;
        END LOOP;

        -- ----------------------------------------------------------------
        -- Determine primary scan type
        -- ----------------------------------------------------------------
        IF l_has_full_scan AND NOT l_has_index THEN
            l_metrics.scan_type := 'FULL TABLE SCAN';
        ELSIF l_has_index AND NOT l_has_full_scan THEN
            l_metrics.scan_type := l_access_path;
        ELSIF l_has_full_scan AND l_has_index THEN
            l_metrics.scan_type := 'MIXED (FULL + INDEX)';
        ELSE
            l_metrics.scan_type := 'UNKNOWN';
        END IF;

        l_metrics.cost        := l_max_cost;
        l_metrics.cardinality := l_max_rows;
        l_metrics.index_used  := l_has_index;
        l_metrics.join_type   := l_join_type;
        l_metrics.filter_cond := l_filter;
        l_metrics.access_path := l_access_path;

        -- ----------------------------------------------------------------
        -- Generate observations
        -- ----------------------------------------------------------------
        IF l_has_full_scan THEN
            l_obs := l_obs || 'Full table scan detected|';
        END IF;
        IF NOT l_has_index AND l_has_full_scan THEN
            l_obs := l_obs || 'No index usage found — consider adding indexes|';
        END IF;
        IF l_max_cost > 500 THEN
            l_obs := l_obs || 'High cost detected (' || l_max_cost || ') — query may be expensive|';
        END IF;
        IF l_max_rows > 10000 THEN
            l_obs := l_obs || 'Large row estimate (' || l_max_rows || ') — consider filtering or pagination|';
        END IF;
        IF l_join_type IS NOT NULL AND LENGTH(l_join_type) > 0 THEN
            l_obs := l_obs || l_join_type || ' join detected|';
        END IF;
        IF l_join_type = 'NESTED LOOPS' AND l_max_rows > 1000 THEN
            l_obs := l_obs || 'Nested loops with large row count may be slow — consider hash join|';
        END IF;
        IF l_has_full_scan AND l_filter IS NOT NULL AND LENGTH(l_filter) > 0 THEN
            l_obs := l_obs || 'Potential missing index on filtered column(s)|';
        END IF;
        IF l_obs IS NULL OR LENGTH(l_obs) = 0 THEN
            l_obs := 'No significant issues detected|';
        END IF;

        l_metrics.observations := RTRIM(l_obs, '|');

        -- ----------------------------------------------------------------
        -- Build JSON result
        -- ----------------------------------------------------------------
        DECLARE
            l_idx_used_str VARCHAR2(5);
            l_obs_array    CLOB := '';
            l_obs_item     VARCHAR2(1000);
            l_obs_rest     VARCHAR2(4000) := l_metrics.observations;
            l_pipe_pos     NUMBER;
            l_first        BOOLEAN := TRUE;
        BEGIN
            IF l_metrics.index_used THEN
                l_idx_used_str := 'true';
            ELSE
                l_idx_used_str := 'false';
            END IF;

            -- Build observations JSON array
            LOOP
                l_pipe_pos := INSTR(l_obs_rest, '|');
                IF l_pipe_pos > 0 THEN
                    l_obs_item := SUBSTR(l_obs_rest, 1, l_pipe_pos - 1);
                    l_obs_rest := SUBSTR(l_obs_rest, l_pipe_pos + 1);
                ELSE
                    l_obs_item := l_obs_rest;
                    l_obs_rest := '';
                END IF;

                IF l_obs_item IS NOT NULL AND LENGTH(TRIM(l_obs_item)) > 0 THEN
                    IF NOT l_first THEN
                        l_obs_array := l_obs_array || ',' || CHR(10);
                    END IF;
                    l_obs_array := l_obs_array || '      "' || TRIM(l_obs_item) || '"';
                    l_first := FALSE;
                END IF;

                EXIT WHEN l_obs_rest IS NULL OR LENGTH(l_obs_rest) = 0;
            END LOOP;

            p_result := '{' || CHR(10)
                || '  "scan_type": "'   || NVL(l_metrics.scan_type, 'UNKNOWN') || '",' || CHR(10)
                || '  "cost": '         || NVL(TO_CHAR(l_metrics.cost), '0') || ',' || CHR(10)
                || '  "rows": '         || NVL(TO_CHAR(l_metrics.cardinality), '0') || ',' || CHR(10)
                || '  "index_used": '   || l_idx_used_str || ',' || CHR(10)
                || '  "index_name": "'  || NVL(l_metrics.index_name, '') || '",' || CHR(10)
                || '  "join_type": "'   || NVL(l_metrics.join_type, 'NONE') || '",' || CHR(10)
                || '  "access_path": "' || NVL(l_metrics.access_path, '') || '",' || CHR(10)
                || '  "filter": "'      || NVL(REPLACE(SUBSTR(l_metrics.filter_cond, 1, 500), '"', '\"'), '') || '",' || CHR(10)
                || '  "observations": [' || CHR(10)
                || l_obs_array || CHR(10)
                || '    ]' || CHR(10)
                || '}';
        END;

    EXCEPTION
        WHEN OTHERS THEN
            p_result := build_error_response('Plan parsing failed: ' || SQLERRM);
    END parse_plan;

    -- ========================================================================
    -- ANALYZE_QUERY  (Public)
    -- Main entry point — validates, generates plan, parses, logs, and reports.
    -- ========================================================================
    PROCEDURE analyze_query (
        p_query     IN  CLOB,
        p_report    OUT CLOB
    )
    IS
        l_err_msg       VARCHAR2(4000);
        l_plan_clob     CLOB;
        l_analysis_clob CLOB;
        l_start_time    TIMESTAMP;
        l_end_time      TIMESTAMP;
        l_elapsed_ms    NUMBER;
        l_stmt_id       VARCHAR2(30);
        l_line          VARCHAR2(4000);
    BEGIN
        l_start_time := SYSTIMESTAMP;

        -- ==================================================================
        -- Step 1: Validate input
        -- ==================================================================
        l_err_msg := validate_query(p_query);
        IF l_err_msg IS NOT NULL THEN
            p_report := build_error_response(l_err_msg);

            -- Log the error
            INSERT INTO query_plan_log (query_text, status, error_message)
            VALUES (p_query, c_status_err, l_err_msg);
            COMMIT;
            RETURN;
        END IF;

        -- ==================================================================
        -- Step 2: Generate unique statement ID for this analysis
        -- ==================================================================
        l_stmt_id := 'QA_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3');

        -- ==================================================================
        -- Step 3: Run EXPLAIN PLAN
        -- ==================================================================
        BEGIN
            -- Clean previous plan for this statement id
            DELETE FROM plan_table WHERE statement_id = l_stmt_id;

            EXECUTE IMMEDIATE
                'EXPLAIN PLAN SET STATEMENT_ID = ''' || l_stmt_id
                || ''' FOR ' || p_query;
        EXCEPTION
            WHEN OTHERS THEN
                l_err_msg := 'Failed to generate execution plan: ' || SQLERRM;
                p_report  := build_error_response(l_err_msg);

                INSERT INTO query_plan_log (query_text, status, error_message)
                VALUES (p_query, c_status_err, l_err_msg);
                COMMIT;
                RETURN;
        END;

        -- ==================================================================
        -- Step 4: Fetch plan output from DBMS_XPLAN
        -- ==================================================================
        BEGIN
            DBMS_LOB.CREATETEMPORARY(l_plan_clob, TRUE);

            FOR rec IN (
                SELECT plan_table_output AS line_text
                FROM   TABLE(DBMS_XPLAN.DISPLAY(
                           'PLAN_TABLE', l_stmt_id, 'ALL'))
            ) LOOP
                DBMS_LOB.WRITEAPPEND(l_plan_clob,
                    LENGTH(rec.line_text) + 1,
                    rec.line_text || CHR(10));
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN
                l_err_msg := 'Failed to retrieve execution plan: ' || SQLERRM;
                p_report  := build_error_response(l_err_msg);

                INSERT INTO query_plan_log (query_text, status, error_message)
                VALUES (p_query, c_status_err, l_err_msg);
                COMMIT;
                RETURN;
        END;

        -- ==================================================================
        -- Step 5: Parse execution plan
        -- ==================================================================
        parse_plan(l_plan_clob, l_analysis_clob);

        -- ==================================================================
        -- Step 6: Calculate elapsed time
        -- ==================================================================
        l_end_time   := SYSTIMESTAMP;
        l_elapsed_ms := EXTRACT(SECOND FROM (l_end_time - l_start_time)) * 1000;

        -- ==================================================================
        -- Step 7: Log to QUERY_PLAN_LOG
        -- ==================================================================
        INSERT INTO query_plan_log (
            query_text, plan_output, analysis_json,
            status, execution_time
        ) VALUES (
            p_query, l_plan_clob, l_analysis_clob,
            c_status_ok, l_elapsed_ms
        );
        COMMIT;

        -- ==================================================================
        -- Step 8: Build final JSON report
        -- ==================================================================
        p_report := '{' || CHR(10)
            || '  "status": "' || c_status_ok || '",' || CHR(10)
            || '  "version": "' || c_version || '",' || CHR(10)
            || '  "execution_time_ms": ' || ROUND(l_elapsed_ms, 2) || ',' || CHR(10)
            || '  "query": "' || REPLACE(SUBSTR(TO_CHAR(p_query), 1, 500), '"', '\"') || '",' || CHR(10)
            || '  "analysis": ' || l_analysis_clob || ',' || CHR(10)
            || '  "raw_plan": "' || REPLACE(REPLACE(
                    SUBSTR(TO_CHAR(l_plan_clob), 1, 2000),
                    '"', '\"'),
                    CHR(10), '\n') || '"' || CHR(10)
            || '}';

        -- Cleanup temporary LOB
        IF DBMS_LOB.ISTEMPORARY(l_plan_clob) = 1 THEN
            DBMS_LOB.FREETEMPORARY(l_plan_clob);
        END IF;

    EXCEPTION
        WHEN OTHERS THEN
            p_report := build_error_response('Unexpected error: ' || SQLERRM);

            BEGIN
                INSERT INTO query_plan_log (query_text, status, error_message)
                VALUES (p_query, c_status_err, SQLERRM);
                COMMIT;
            EXCEPTION
                WHEN OTHERS THEN NULL; -- Don't let logging failure mask the real error
            END;
    END analyze_query;

    -- ========================================================================
    -- GET_ANALYSIS_HISTORY  (Public)
    -- Returns recent analysis log entries as a ref cursor.
    -- ========================================================================
    PROCEDURE get_analysis_history (
        p_limit     IN  NUMBER DEFAULT 10,
        p_result    OUT SYS_REFCURSOR
    )
    IS
    BEGIN
        OPEN p_result FOR
            SELECT id,
                   DBMS_LOB.SUBSTR(query_text, 200, 1) AS query_preview,
                   status,
                   error_message,
                   execution_time,
                   created_at
            FROM   query_plan_log
            ORDER BY created_at DESC
            FETCH FIRST p_limit ROWS ONLY;
    END get_analysis_history;

END query_analyzer_pkg;
/

PROMPT >> Package body QUERY_ANALYZER_PKG created successfully.
