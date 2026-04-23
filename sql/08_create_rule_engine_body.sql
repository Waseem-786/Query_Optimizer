-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 2
-- Script: 08_create_rule_engine_body.sql
-- Purpose: RULE_ENGINE_PKG package body — 7 modular optimization rules
-- ============================================================================

CREATE OR REPLACE PACKAGE BODY rule_engine_pkg
AS

    -- ========================================================================
    -- PRIVATE: build_error_response
    -- ========================================================================
    FUNCTION build_error_response (p_message IN VARCHAR2) RETURN CLOB IS
    BEGIN
        RETURN '{"status":"ERROR","version":"' || c_version
            || '","message":"' || REPLACE(p_message, '"', '\"') || '"}';
    END build_error_response;

    -- ========================================================================
    -- PRIVATE: escape_json
    -- Makes a VARCHAR2 safe for embedding inside a JSON string value.
    -- ========================================================================
    FUNCTION escape_json (p_val IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_val IS NULL THEN RETURN ''; END IF;
        RETURN REPLACE(
                 REPLACE(
                   REPLACE(p_val, '\', '\\'),
                 '"', '\"'),
               CHR(10), '\n');
    END escape_json;

    -- ========================================================================
    -- PRIVATE: get_rule_id
    -- Returns the rule_id for an active rule by name; NULL if not found.
    -- ========================================================================
    FUNCTION get_rule_id (p_rule_name IN VARCHAR2) RETURN NUMBER IS
        l_id NUMBER;
    BEGIN
        SELECT rule_id INTO l_id
        FROM   optimization_rules
        WHERE  rule_name = p_rule_name AND is_active = 1;
        RETURN l_id;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN RETURN NULL;
    END get_rule_id;

    -- ========================================================================
    -- PRIVATE: persist_result
    -- Inserts one triggered rule record into QUERY_RULE_RESULTS.
    -- Silently skips if the rule is not found in the catalogue.
    -- ========================================================================
    PROCEDURE persist_result (
        p_query_log_id  IN NUMBER,
        p_rule_name     IN VARCHAR2,
        p_severity      IN VARCHAR2,
        p_context       IN VARCHAR2,
        p_index_ddl     IN CLOB,
        p_fragment      IN CLOB
    ) IS
        l_rule_id NUMBER := get_rule_id(p_rule_name);
    BEGIN
        IF l_rule_id IS NULL THEN RETURN; END IF;

        INSERT INTO query_rule_results (
            query_log_id, rule_id, rule_name, severity,
            context_info, index_recommendation, optimized_fragment
        ) VALUES (
            p_query_log_id, l_rule_id, p_rule_name, p_severity,
            SUBSTR(p_context, 1, 4000), p_index_ddl, p_fragment
        );
    END persist_result;

    -- ========================================================================
    -- PRIVATE: extract_tables
    -- Extracts table names referenced after FROM and JOIN keywords.
    -- Returns a pipe-delimited VARCHAR2 of upper-cased table names.
    -- Uses REGEXP_SUBSTR with capture group (Oracle 11g+ compatible).
    -- ========================================================================
    FUNCTION extract_tables (p_query IN CLOB) RETURN VARCHAR2 IS
        l_upper  VARCHAR2(32767);
        l_result VARCHAR2(4000) := '';
        l_tbl    VARCHAR2(200);
        l_occ    PLS_INTEGER;
    BEGIN
        l_upper := UPPER(DBMS_LOB.SUBSTR(p_query, 32767, 1));

        -- Capture table name after FROM
        l_occ := 1;
        LOOP
            l_tbl := REGEXP_SUBSTR(l_upper, 'FROM\s+([A-Z][A-Z0-9_$#]*)', 1, l_occ, 'i', 1);
            EXIT WHEN l_tbl IS NULL;
            IF l_tbl NOT IN ('SELECT','DUAL','LATERAL','TABLE','XMLTABLE')
               AND INSTR(l_result, '|' || l_tbl || '|') = 0 THEN
                l_result := l_result || '|' || l_tbl;
            END IF;
            l_occ := l_occ + 1;
            EXIT WHEN l_occ > 20;
        END LOOP;

        -- Capture table name after JOIN variants
        l_occ := 1;
        LOOP
            l_tbl := REGEXP_SUBSTR(l_upper, 'JOIN\s+([A-Z][A-Z0-9_$#]*)', 1, l_occ, 'i', 1);
            EXIT WHEN l_tbl IS NULL;
            IF l_tbl NOT IN ('SELECT','DUAL','LATERAL','TABLE','XMLTABLE')
               AND INSTR(l_result, '|' || l_tbl || '|') = 0 THEN
                l_result := l_result || '|' || l_tbl;
            END IF;
            l_occ := l_occ + 1;
            EXIT WHEN l_occ > 20;
        END LOOP;

        -- Strip leading pipe
        RETURN LTRIM(l_result, '|');
    EXCEPTION
        WHEN OTHERS THEN RETURN '';
    END extract_tables;

    -- ========================================================================
    -- PRIVATE: extract_where_columns
    -- Extracts column names from WHERE predicates (before comparison operators).
    -- Handles optional table-alias prefix (alias.column).
    -- Returns a pipe-delimited VARCHAR2 of upper-cased column names.
    -- ========================================================================
    FUNCTION extract_where_columns (p_query IN CLOB) RETURN VARCHAR2 IS
        l_upper     VARCHAR2(32767);
        l_where_str VARCHAR2(32767);
        l_where_pos PLS_INTEGER;
        l_result    VARCHAR2(4000) := '';
        l_full_tok  VARCHAR2(200);
        l_col       VARCHAR2(200);
        l_occ       PLS_INTEGER := 1;
        -- Keywords that should not be treated as column names
        l_skip_kws  VARCHAR2(1000) :=
            '|AND|OR|NOT|NULL|IS|EXISTS|BETWEEN|LIKE|IN|WHERE|HAVING|'
         || 'CASE|WHEN|THEN|ELSE|END|SELECT|FROM|JOIN|ON|GROUP|ORDER|'
         || 'BY|FETCH|FIRST|ROWS|ONLY|DISTINCT|UNION|MINUS|INTERSECT|'
         || 'INNER|LEFT|RIGHT|OUTER|CROSS|FULL|INTO|VALUES|RETURNING|';
    BEGIN
        l_upper := UPPER(DBMS_LOB.SUBSTR(p_query, 32767, 1));

        l_where_pos := INSTR(l_upper, ' WHERE ');
        IF l_where_pos = 0 THEN RETURN ''; END IF;

        l_where_str := SUBSTR(l_upper, l_where_pos + 7);

        -- Truncate WHERE clause at subsequent clauses
        FOR kw IN (SELECT 'GROUP BY'   k FROM DUAL UNION ALL
                   SELECT ' ORDER '        FROM DUAL UNION ALL
                   SELECT ' HAVING '       FROM DUAL UNION ALL
                   SELECT ' UNION '        FROM DUAL UNION ALL
                   SELECT ' MINUS '        FROM DUAL UNION ALL
                   SELECT ' INTERSECT '    FROM DUAL UNION ALL
                   SELECT ' FETCH '        FROM DUAL) LOOP
            IF INSTR(l_where_str, kw.k) > 0 THEN
                l_where_str := SUBSTR(l_where_str, 1, INSTR(l_where_str, kw.k) - 1);
            END IF;
        END LOOP;

        -- Match: [optional_alias.]column_name followed by a comparison operator
        -- Pattern: ([A-Z][A-Z0-9_.]*) then whitespace then operator
        LOOP
            l_full_tok := REGEXP_SUBSTR(
                l_where_str,
                '[A-Z][A-Z0-9_.]*\s*(=|<>|!=|<|>|LIKE|BETWEEN|IN\s*\()',
                1, l_occ, 'i');
            EXIT WHEN l_full_tok IS NULL;

            -- Extract the identifier part only (before whitespace/operator)
            l_col := REGEXP_SUBSTR(l_full_tok, '^[A-Z][A-Z0-9_.]*', 1, 1, 'i');

            -- Strip table alias prefix if present (e.g. T1.COLUMN → COLUMN)
            IF INSTR(l_col, '.') > 0 THEN
                l_col := SUBSTR(l_col, INSTR(l_col, '.') + 1);
            END IF;

            l_col := UPPER(TRIM(l_col));

            -- Skip SQL keywords and already-found columns
            IF LENGTH(l_col) > 0
               AND INSTR(l_skip_kws, '|' || l_col || '|') = 0
               AND INSTR(l_result, '|' || l_col || '|') = 0 THEN
                l_result := l_result || '|' || l_col;
            END IF;

            l_occ := l_occ + 1;
            EXIT WHEN l_occ > 30; -- Safety cap
        END LOOP;

        RETURN LTRIM(l_result, '|');
    EXCEPTION
        WHEN OTHERS THEN RETURN '';
    END extract_where_columns;

    -- ========================================================================
    -- PRIVATE RULES — one procedure per rule
    -- Each rule procedure sets p_triggered := TRUE when it fires and calls
    -- persist_result() to store the finding.
    -- ========================================================================

    -- ------------------------------------------------------------------------
    -- RULE 1: SELECT * Detection
    -- Fires when the SELECT list contains a bare asterisk.
    -- ------------------------------------------------------------------------
    PROCEDURE rule_select_star (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_sample VARCHAR2(1000);
    BEGIN
        p_triggered := FALSE;
        l_sample    := UPPER(DBMS_LOB.SUBSTR(p_query, 500, 1));

        IF REGEXP_LIKE(l_sample, 'SELECT\s+\*') THEN
            p_triggered := TRUE;
            persist_result(
                p_query_id,
                'SELECT_STAR_DETECTED',
                'MEDIUM',
                'SELECT * detected — all columns are being fetched from the table',
                NULL,
                '-- Replace SELECT * with an explicit column list:' || CHR(10)
             || '-- SELECT col1, col2, col3 FROM ...'
            );
        END IF;
    END rule_select_star;

    -- ------------------------------------------------------------------------
    -- RULE 2: Full Table Scan Detection
    -- Reads the execution plan from PLAN_TABLE for the given statement ID.
    -- ------------------------------------------------------------------------
    PROCEDURE rule_full_table_scan (
        p_stmt_id   IN  VARCHAR2,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_context VARCHAR2(4000) := '';
    BEGIN
        p_triggered := FALSE;

        FOR rec IN (
            SELECT plan_table_output AS ln
            FROM   TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', p_stmt_id, 'BASIC'))
        ) LOOP
            IF INSTR(UPPER(rec.ln), 'TABLE ACCESS FULL') > 0 THEN
                p_triggered := TRUE;
                l_context   := l_context || TRIM(rec.ln) || '; ';
            END IF;
        END LOOP;

        IF p_triggered THEN
            persist_result(
                p_query_id,
                'FULL_TABLE_SCAN_DETECTED',
                'HIGH',
                'Full table scan found in plan: ' || SUBSTR(l_context, 1, 3800),
                NULL,
                NULL
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_full_table_scan;

    -- ------------------------------------------------------------------------
    -- RULE 3: Missing Index on Filter Column
    -- Checks USER_TAB_COLUMNS and USER_IND_COLUMNS for each
    -- (table, WHERE-column) combination detected in the query text.
    -- Generates CREATE INDEX DDL for every unindexed column found.
    -- ------------------------------------------------------------------------
    PROCEDURE rule_missing_indexes (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_tables    VARCHAR2(4000);
        l_cols      VARCHAR2(4000);
        l_tbl       VARCHAR2(200);
        l_col       VARCHAR2(200);
        l_t_rest    VARCHAR2(4000);
        l_c_rest    VARCHAR2(4000);
        l_t_pipe    PLS_INTEGER;
        l_c_pipe    PLS_INTEGER;
        l_cnt       NUMBER;
        l_context   VARCHAR2(4000) := '';
        l_ddl       CLOB           := '';
    BEGIN
        p_triggered := FALSE;
        l_tables    := extract_tables(p_query);
        l_cols      := extract_where_columns(p_query);

        IF l_tables IS NULL OR LENGTH(l_tables) = 0
           OR l_cols  IS NULL OR LENGTH(l_cols)  = 0 THEN
            RETURN;
        END IF;

        -- Iterate every table × column combination
        l_t_rest := l_tables;
        WHILE LENGTH(l_t_rest) > 0 LOOP
            l_t_pipe := INSTR(l_t_rest, '|');
            IF l_t_pipe > 0 THEN
                l_tbl    := SUBSTR(l_t_rest, 1, l_t_pipe - 1);
                l_t_rest := SUBSTR(l_t_rest, l_t_pipe + 1);
            ELSE
                l_tbl    := l_t_rest;
                l_t_rest := '';
            END IF;

            l_c_rest := l_cols;
            WHILE LENGTH(l_c_rest) > 0 LOOP
                l_c_pipe := INSTR(l_c_rest, '|');
                IF l_c_pipe > 0 THEN
                    l_col    := SUBSTR(l_c_rest, 1, l_c_pipe - 1);
                    l_c_rest := SUBSTR(l_c_rest, l_c_pipe + 1);
                ELSE
                    l_col    := l_c_rest;
                    l_c_rest := '';
                END IF;

                BEGIN
                    -- Only proceed if the column genuinely exists on this table
                    SELECT COUNT(*) INTO l_cnt
                    FROM   user_tab_columns
                    WHERE  table_name = l_tbl AND column_name = l_col;

                    IF l_cnt > 0 THEN
                        -- Check for any index with this column as a leading column
                        SELECT COUNT(*) INTO l_cnt
                        FROM   user_ind_columns
                        WHERE  table_name  = l_tbl
                          AND  column_name = l_col
                          AND  column_position = 1;

                        IF l_cnt = 0 THEN
                            p_triggered := TRUE;
                            l_context   := l_context || l_tbl || '.' || l_col || ' unindexed; ';
                            l_ddl       := l_ddl
                                        || 'CREATE INDEX idx_'
                                        || LOWER(l_tbl) || '_' || LOWER(l_col)
                                        || ' ON ' || l_tbl || ' (' || l_col || ');'
                                        || CHR(10);
                        END IF;
                    END IF;
                EXCEPTION
                    WHEN OTHERS THEN NULL; -- Column lookup failed; skip gracefully
                END;
            END LOOP;
        END LOOP;

        IF p_triggered THEN
            persist_result(
                p_query_id,
                'MISSING_INDEX_ON_FILTER',
                'HIGH',
                SUBSTR(l_context, 1, 3900),
                l_ddl,
                NULL
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_missing_indexes;

    -- ------------------------------------------------------------------------
    -- RULE 4: Function Applied to a Column in WHERE Clause
    -- Detects scalar functions that suppress index usage on the column argument.
    -- ------------------------------------------------------------------------
    PROCEDURE rule_function_on_column (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_upper     VARCHAR2(32767);
        l_where_pos PLS_INTEGER;
        l_where_str VARCHAR2(32767);
        l_found     VARCHAR2(1000) := '';

        TYPE t_fn_tab IS TABLE OF VARCHAR2(30);
        l_fns t_fn_tab := t_fn_tab(
            'UPPER(', 'LOWER(', 'TRUNC(', 'TO_DATE(', 'TO_NUMBER(',
            'TO_CHAR(', 'SUBSTR(', 'NVL(', 'TRIM(', 'LTRIM(', 'RTRIM(',
            'DECODE(', 'ROUND(', 'FLOOR(', 'CEIL(', 'LENGTH(', 'INSTR('
        );
    BEGIN
        p_triggered := FALSE;
        l_upper     := UPPER(DBMS_LOB.SUBSTR(p_query, 32767, 1));
        l_where_pos := INSTR(l_upper, ' WHERE ');
        IF l_where_pos = 0 THEN RETURN; END IF;

        l_where_str := SUBSTR(l_upper, l_where_pos);

        FOR i IN 1 .. l_fns.COUNT LOOP
            IF INSTR(l_where_str, l_fns(i)) > 0 THEN
                l_found := l_found || RTRIM(l_fns(i), '(') || ' ';
            END IF;
        END LOOP;

        IF LENGTH(TRIM(l_found)) > 0 THEN
            p_triggered := TRUE;
            persist_result(
                p_query_id,
                'FUNCTION_ON_INDEXED_COLUMN',
                'MEDIUM',
                'Functions in WHERE clause that suppress index usage: ' || TRIM(l_found),
                NULL,
                '-- Option 1: Create a Function-Based Index:' || CHR(10)
             || '--   CREATE INDEX idx_fbi ON table_name (UPPER(column_name));' || CHR(10)
             || '-- Option 2: Rewrite predicate to isolate the column on one side.'
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_function_on_column;

    -- ------------------------------------------------------------------------
    -- RULE 5: Subquery That Can Be Rewritten as a JOIN
    -- Detects IN(SELECT ...), NOT IN(SELECT ...), and EXISTS(SELECT ...).
    -- ------------------------------------------------------------------------
    PROCEDURE rule_subquery_to_join (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_upper VARCHAR2(32767);
        l_found VARCHAR2(300) := '';
    BEGIN
        p_triggered := FALSE;
        l_upper     := UPPER(DBMS_LOB.SUBSTR(p_query, 32767, 1));

        IF REGEXP_LIKE(l_upper, 'IN\s*\(\s*SELECT')     THEN l_found := l_found || 'IN(SELECT) ';     END IF;
        IF REGEXP_LIKE(l_upper, 'NOT\s+IN\s*\(\s*SELECT') THEN l_found := l_found || 'NOT IN(SELECT) '; END IF;
        IF REGEXP_LIKE(l_upper, 'EXISTS\s*\(\s*SELECT') THEN l_found := l_found || 'EXISTS(SELECT) '; END IF;

        IF LENGTH(TRIM(l_found)) > 0 THEN
            p_triggered := TRUE;
            persist_result(
                p_query_id,
                'SUBQUERY_CANDIDATE_FOR_JOIN',
                'MEDIUM',
                'Subquery pattern(s) detected: ' || TRIM(l_found),
                NULL,
                '-- Rewrite as explicit JOIN. Example:' || CHR(10)
             || '-- FROM t1 INNER JOIN t2 ON t1.id = t2.ref_id AND [condition]' || CHR(10)
             || '-- For NOT IN, use: LEFT JOIN t2 ON t1.id = t2.ref_id WHERE t2.ref_id IS NULL'
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_subquery_to_join;

    -- ------------------------------------------------------------------------
    -- RULE 6: Unnecessary DISTINCT
    -- Fires when SELECT DISTINCT is present in the query text.
    -- ------------------------------------------------------------------------
    PROCEDURE rule_unnecessary_distinct (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_upper VARCHAR2(500);
    BEGIN
        p_triggered := FALSE;
        l_upper     := UPPER(DBMS_LOB.SUBSTR(p_query, 200, 1));

        IF REGEXP_LIKE(l_upper, 'SELECT\s+DISTINCT') THEN
            p_triggered := TRUE;
            persist_result(
                p_query_id,
                'UNNECESSARY_DISTINCT',
                'LOW',
                'SELECT DISTINCT detected — verify deduplicate step is necessary',
                NULL,
                '-- If all joins are on primary/unique keys the result is already unique.' || CHR(10)
             || '-- Remove DISTINCT and verify row count matches expectations.'
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_unnecessary_distinct;

    -- ------------------------------------------------------------------------
    -- RULE 7: Cartesian Join Detection
    -- Two detection strategies:
    --   A) Execution plan contains the string CARTESIAN.
    --   B) FROM clause has comma-separated tables with no cross-alias predicate
    --      and no JOIN keyword (implicit cross join).
    -- ------------------------------------------------------------------------
    PROCEDURE rule_cartesian_join (
        p_query     IN  CLOB,
        p_stmt_id   IN  VARCHAR2,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_upper       VARCHAR2(32767);
        l_from_start  PLS_INTEGER;
        l_from_end    PLS_INTEGER;
        l_from_str    VARCHAR2(500);
        l_comma_cnt   PLS_INTEGER;
        l_found       BOOLEAN := FALSE;
    BEGIN
        p_triggered := FALSE;
        l_upper     := UPPER(DBMS_LOB.SUBSTR(p_query, 32767, 1));

        -- Strategy A: check execution plan for CARTESIAN keyword
        BEGIN
            FOR rec IN (
                SELECT plan_table_output AS ln
                FROM   TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE', p_stmt_id, 'BASIC'))
            ) LOOP
                IF INSTR(UPPER(rec.ln), 'CARTESIAN') > 0 THEN
                    l_found := TRUE;
                END IF;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        -- Strategy B: comma-separated FROM without JOIN keyword and no cross-table predicate
        IF NOT l_found THEN
            l_from_start := INSTR(l_upper, ' FROM ');
            IF l_from_start > 0 THEN
                -- End of FROM list is wherever the next clause starts
                l_from_end := LEAST(
                    CASE WHEN INSTR(l_upper, ' WHERE ', l_from_start) > 0
                         THEN INSTR(l_upper, ' WHERE ', l_from_start) ELSE 99999 END,
                    CASE WHEN INSTR(l_upper, ' JOIN ',  l_from_start) > 0
                         THEN INSTR(l_upper, ' JOIN ',  l_from_start) ELSE 99999 END,
                    CASE WHEN INSTR(l_upper, ' ORDER ', l_from_start) > 0
                         THEN INSTR(l_upper, ' ORDER ', l_from_start) ELSE 99999 END
                );
                IF l_from_end = 99999 THEN l_from_end := LENGTH(l_upper); END IF;

                l_from_str  := SUBSTR(l_upper, l_from_start + 6,
                                      l_from_end - l_from_start - 6);
                l_comma_cnt := LENGTH(l_from_str)
                             - LENGTH(REPLACE(l_from_str, ',', ''));

                -- Multiple comma-separated tables, no JOIN keyword, and no t1.col = t2.col predicate
                IF  l_comma_cnt >= 1
                AND INSTR(l_upper, ' JOIN ') = 0
                AND NOT REGEXP_LIKE(l_upper, 'WHERE.*[A-Z][A-Z0-9_]*\.[A-Z][A-Z0-9_]*\s*=\s*[A-Z][A-Z0-9_]*\.[A-Z]')
                THEN
                    l_found := TRUE;
                END IF;
            END IF;
        END IF;

        IF l_found THEN
            p_triggered := TRUE;
            persist_result(
                p_query_id,
                'CARTESIAN_JOIN_DETECTED',
                'HIGH',
                'Cartesian product detected — missing or incomplete join conditions between tables',
                NULL,
                '-- Add explicit ON/USING conditions for every table pair.' || CHR(10)
             || '-- Prefer ANSI syntax:  FROM t1 INNER JOIN t2 ON t1.id = t2.ref_id' || CHR(10)
             || '-- Use CROSS JOIN keyword only when a Cartesian product is intentional.'
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_cartesian_join;

    -- ========================================================================
    -- PRIVATE: build_json_report
    -- Assembles the final JSON CLOB output from QUERY_RULE_RESULTS rows.
    -- ========================================================================
    FUNCTION build_json_report (
        p_query         IN CLOB,
        p_query_id      IN NUMBER,
        p_elapsed_ms    IN NUMBER,
        p_plan_json     IN CLOB,
        p_rules_total   IN NUMBER,
        p_rules_hit     IN NUMBER
    ) RETURN CLOB IS
        l_json      CLOB;
        l_rules_arr CLOB := '';
        l_idx_arr   CLOB := '';
        l_first     BOOLEAN := TRUE;
        l_first_idx BOOLEAN := TRUE;
        l_high      NUMBER  := 0;
        l_medium    NUMBER  := 0;
        l_low       NUMBER  := 0;
    BEGIN
        -- Aggregate severity counts for this analysis run
        BEGIN
            SELECT
                SUM(CASE WHEN qrr.severity = 'HIGH'   THEN 1 ELSE 0 END),
                SUM(CASE WHEN qrr.severity = 'MEDIUM' THEN 1 ELSE 0 END),
                SUM(CASE WHEN qrr.severity = 'LOW'    THEN 1 ELSE 0 END)
            INTO l_high, l_medium, l_low
            FROM query_rule_results qrr
            WHERE qrr.query_log_id = p_query_id
              AND qrr.triggered_at >= SYSTIMESTAMP - INTERVAL '2' MINUTE;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        -- Build triggered_rules JSON array
        FOR rec IN (
            SELECT
                r.rule_name, r.category, qrr.severity,
                r.description, r.recommendation,
                qrr.context_info,
                qrr.index_recommendation,
                qrr.optimized_fragment
            FROM   query_rule_results qrr
            JOIN   optimization_rules r ON r.rule_id = qrr.rule_id
            WHERE  qrr.query_log_id = p_query_id
              AND  qrr.triggered_at >= SYSTIMESTAMP - INTERVAL '2' MINUTE
            ORDER BY
                CASE qrr.severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                qrr.triggered_at
        ) LOOP
            IF NOT l_first THEN l_rules_arr := l_rules_arr || ',' || CHR(10); END IF;
            l_rules_arr := l_rules_arr
                || '    {' || CHR(10)
                || '      "rule_name": "'       || escape_json(rec.rule_name)  || '",' || CHR(10)
                || '      "category": "'        || escape_json(rec.category)   || '",' || CHR(10)
                || '      "severity": "'        || escape_json(rec.severity)   || '",' || CHR(10)
                || '      "description": "'     || escape_json(rec.description) || '",' || CHR(10)
                || '      "recommendation": "'  || escape_json(SUBSTR(TO_CHAR(rec.recommendation), 1, 800)) || '",' || CHR(10)
                || '      "context": "'         || escape_json(rec.context_info) || '",' || CHR(10)
                || '      "index_recommendation": '
                || CASE WHEN rec.index_recommendation IS NOT NULL
                        THEN '"' || escape_json(SUBSTR(TO_CHAR(rec.index_recommendation), 1, 2000)) || '"'
                        ELSE 'null' END || ',' || CHR(10)
                || '      "optimized_fragment": '
                || CASE WHEN rec.optimized_fragment IS NOT NULL
                        THEN '"' || escape_json(SUBSTR(TO_CHAR(rec.optimized_fragment), 1, 1000)) || '"'
                        ELSE 'null' END || CHR(10)
                || '    }';
            l_first := FALSE;

            -- Collect index DDL into separate array
            IF rec.index_recommendation IS NOT NULL THEN
                IF NOT l_first_idx THEN l_idx_arr := l_idx_arr || ', '; END IF;
                l_idx_arr   := l_idx_arr
                             || '"' || escape_json(SUBSTR(TO_CHAR(rec.index_recommendation), 1, 1000)) || '"';
                l_first_idx := FALSE;
            END IF;
        END LOOP;

        -- Assemble complete JSON
        DBMS_LOB.CREATETEMPORARY(l_json, TRUE);
        DBMS_LOB.WRITEAPPEND(l_json, LENGTH(
            '{' || CHR(10)
         || '  "status": "SUCCESS",' || CHR(10)
         || '  "version": "' || c_version || '",' || CHR(10)
         || '  "execution_time_ms": ' || ROUND(p_elapsed_ms, 2) || ',' || CHR(10)
         || '  "query": "' || escape_json(SUBSTR(TO_CHAR(p_query), 1, 500)) || '",' || CHR(10)
         || '  "rule_summary": {' || CHR(10)
         || '    "total_rules_evaluated": ' || p_rules_total || ',' || CHR(10)
         || '    "rules_triggered": '       || p_rules_hit   || ',' || CHR(10)
         || '    "high_severity": '         || NVL(l_high,   0) || ',' || CHR(10)
         || '    "medium_severity": '       || NVL(l_medium, 0) || ',' || CHR(10)
         || '    "low_severity": '          || NVL(l_low,    0) || CHR(10)
         || '  },' || CHR(10)
         || '  "triggered_rules": [' || CHR(10)),
         '{' || CHR(10)
         || '  "status": "SUCCESS",' || CHR(10)
         || '  "version": "' || c_version || '",' || CHR(10)
         || '  "execution_time_ms": ' || ROUND(p_elapsed_ms, 2) || ',' || CHR(10)
         || '  "query": "' || escape_json(SUBSTR(TO_CHAR(p_query), 1, 500)) || '",' || CHR(10)
         || '  "rule_summary": {' || CHR(10)
         || '    "total_rules_evaluated": ' || p_rules_total || ',' || CHR(10)
         || '    "rules_triggered": '       || p_rules_hit   || ',' || CHR(10)
         || '    "high_severity": '         || NVL(l_high,   0) || ',' || CHR(10)
         || '    "medium_severity": '       || NVL(l_medium, 0) || ',' || CHR(10)
         || '    "low_severity": '          || NVL(l_low,    0) || CHR(10)
         || '  },' || CHR(10)
         || '  "triggered_rules": [' || CHR(10));

        IF l_rules_arr IS NOT NULL THEN
            DBMS_LOB.APPEND(l_json, l_rules_arr);
        END IF;

        DBMS_LOB.WRITEAPPEND(l_json, LENGTH(CHR(10) || '  ],' || CHR(10)),
                             CHR(10) || '  ],' || CHR(10));

        DECLARE l_tail CLOB;
        BEGIN
            DBMS_LOB.CREATETEMPORARY(l_tail, TRUE);
            DBMS_LOB.WRITEAPPEND(l_tail, LENGTH(
                '  "index_recommendations": ['  || l_idx_arr || '],' || CHR(10)
             || '  "plan_analysis": '),
                '  "index_recommendations": ['  || l_idx_arr || '],' || CHR(10)
             || '  "plan_analysis": ');
            DBMS_LOB.APPEND(l_json, l_tail);
            IF DBMS_LOB.ISTEMPORARY(l_tail) = 1 THEN DBMS_LOB.FREETEMPORARY(l_tail); END IF;
        END;

        IF p_plan_json IS NOT NULL AND DBMS_LOB.GETLENGTH(p_plan_json) > 0 THEN
            DBMS_LOB.APPEND(l_json, p_plan_json);
        ELSE
            DBMS_LOB.WRITEAPPEND(l_json, 4, 'null');
        END IF;

        DBMS_LOB.WRITEAPPEND(l_json, LENGTH(CHR(10) || '}'), CHR(10) || '}');

        RETURN l_json;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN build_error_response('Report assembly failed: ' || SQLERRM);
    END build_json_report;

    -- ========================================================================
    -- APPLY_RULES  (Public)
    -- Orchestrates all 7 rules and assembles the final Phase 2 JSON report.
    -- ========================================================================
    PROCEDURE apply_rules (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER  DEFAULT NULL,
        p_report    OUT CLOB
    ) IS
        l_start         TIMESTAMP   := SYSTIMESTAMP;
        l_elapsed_ms    NUMBER;
        l_stmt_id       VARCHAR2(60);
        l_query_log_id  NUMBER      := p_query_id;
        l_plan_json     CLOB;
        l_phase1_report CLOB;
        l_upper         VARCHAR2(200);

        -- Rule state
        l_triggered   BOOLEAN;
        l_rules_total NUMBER := 7;
        l_rules_hit   NUMBER := 0;
    BEGIN
        -- ---------------------------------------------------------------
        -- Input validation
        -- ---------------------------------------------------------------
        IF p_query IS NULL OR DBMS_LOB.GETLENGTH(p_query) = 0 THEN
            p_report := build_error_response('Query input is NULL or empty');
            RETURN;
        END IF;

        l_upper := UPPER(DBMS_LOB.SUBSTR(p_query, 200, 1));
        IF l_upper NOT LIKE 'SELECT%' AND l_upper NOT LIKE 'WITH%' THEN
            p_report := build_error_response('Only SELECT queries are supported in Phase 2');
            RETURN;
        END IF;

        -- ---------------------------------------------------------------
        -- Phase 1 integration: log the query if no ID was supplied
        -- ---------------------------------------------------------------
        IF l_query_log_id IS NULL THEN
            query_analyzer_pkg.analyze_query(p_query, l_phase1_report);
            BEGIN
                SELECT id INTO l_query_log_id
                FROM   (SELECT id FROM query_plan_log ORDER BY created_at DESC)
                WHERE  ROWNUM = 1;
                -- Retrieve Phase 1 plan analysis for embedding
                SELECT analysis_json INTO l_plan_json
                FROM   query_plan_log WHERE id = l_query_log_id;
            EXCEPTION
                WHEN OTHERS THEN l_query_log_id := -1; l_plan_json := NULL;
            END;
        END IF;

        -- ---------------------------------------------------------------
        -- Generate a fresh EXPLAIN PLAN for rule evaluation
        -- (Rules 2 and 7 need direct plan table access)
        -- ---------------------------------------------------------------
        l_stmt_id := 'RE_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3');
        BEGIN
            DELETE FROM plan_table WHERE statement_id = l_stmt_id;
            EXECUTE IMMEDIATE 'EXPLAIN PLAN SET STATEMENT_ID = '''
                              || l_stmt_id || ''' FOR ' || p_query;
        EXCEPTION
            WHEN OTHERS THEN
                l_stmt_id := NULL; -- Plan-dependent rules will skip gracefully
        END;

        -- ---------------------------------------------------------------
        -- Evaluate all 7 rules
        -- ---------------------------------------------------------------

        -- Rule 1: SELECT *
        rule_select_star(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 2: Full Table Scan (requires plan)
        IF l_stmt_id IS NOT NULL THEN
            rule_full_table_scan(l_stmt_id, l_query_log_id, l_triggered);
            IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;
        ELSE
            l_rules_total := l_rules_total - 1;
        END IF;

        -- Rule 3: Missing Indexes
        rule_missing_indexes(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 4: Functions on Indexed Columns
        rule_function_on_column(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 5: Subquery → JOIN Candidate
        rule_subquery_to_join(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 6: Unnecessary DISTINCT
        rule_unnecessary_distinct(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 7: Cartesian Join (requires plan)
        IF l_stmt_id IS NOT NULL THEN
            rule_cartesian_join(p_query, l_stmt_id, l_query_log_id, l_triggered);
            IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;
        ELSE
            l_rules_total := l_rules_total - 1;
        END IF;

        COMMIT;

        -- ---------------------------------------------------------------
        -- Build and return the final report
        -- ---------------------------------------------------------------
        l_elapsed_ms := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start)) * 1000;

        p_report := build_json_report(
            p_query,
            l_query_log_id,
            l_elapsed_ms,
            l_plan_json,
            l_rules_total,
            l_rules_hit
        );

    EXCEPTION
        WHEN OTHERS THEN
            p_report := build_error_response('Unexpected error in APPLY_RULES: ' || SQLERRM);
            BEGIN ROLLBACK; EXCEPTION WHEN OTHERS THEN NULL; END;
    END apply_rules;

    -- ========================================================================
    -- GET_RULE_RESULTS  (Public)
    -- Returns triggered rule rows for a given QUERY_PLAN_LOG entry.
    -- ========================================================================
    PROCEDURE get_rule_results (
        p_query_id  IN  NUMBER,
        p_result    OUT SYS_REFCURSOR
    ) IS
    BEGIN
        OPEN p_result FOR
            SELECT
                qrr.result_id,
                qrr.rule_name,
                r.category,
                qrr.severity,
                r.description,
                qrr.context_info,
                qrr.index_recommendation,
                qrr.optimized_fragment,
                qrr.triggered_at
            FROM  query_rule_results qrr
            JOIN  optimization_rules r ON r.rule_id = qrr.rule_id
            WHERE qrr.query_log_id = p_query_id
            ORDER BY
                CASE qrr.severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                qrr.triggered_at;
    END get_rule_results;

END rule_engine_pkg;
/

PROMPT >> Package body RULE_ENGINE_PKG created successfully.
