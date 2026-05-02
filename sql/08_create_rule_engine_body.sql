-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 2 (revised)
-- Script: 08_create_rule_engine_body.sql
-- Purpose: RULE_ENGINE_PKG package body
--          7 original rules (enhanced) + 3 new deep-analysis rules
--          Multi-table aware: every rule iterates EVERY table referenced.
-- ============================================================================

CREATE OR REPLACE PACKAGE BODY rule_engine_pkg
AS

    -- ========================================================================
    -- PACKAGE-LEVEL STATE
    --   Dedupe set used across all rule procedures within ONE apply_rules call.
    --   Reset by reset_dedupe() at the start of every apply_rules invocation.
    -- ========================================================================
    g_dedupe_keys VARCHAR2(32767) := '';

    -- ========================================================================
    -- PRIVATE: reset_dedupe
    -- ========================================================================
    PROCEDURE reset_dedupe IS
    BEGIN
        g_dedupe_keys := '';
    END reset_dedupe;

    -- ========================================================================
    -- PRIVATE: mark_or_seen
    --   Returns TRUE if the key was already recorded in this run, otherwise
    --   records it and returns FALSE. Caller uses the boolean to skip dupes.
    -- ========================================================================
    FUNCTION mark_or_seen (p_key IN VARCHAR2) RETURN BOOLEAN IS
        l_norm VARCHAR2(400);
    BEGIN
        IF p_key IS NULL OR LENGTH(p_key) = 0 THEN RETURN FALSE; END IF;
        l_norm := UPPER(TRIM(p_key));
        IF INSTR(g_dedupe_keys, '|' || l_norm || '|') > 0 THEN
            RETURN TRUE;
        END IF;
        IF NVL(LENGTH(g_dedupe_keys), 0) + LENGTH(l_norm) + 2 < 32760 THEN
            g_dedupe_keys := g_dedupe_keys || '|' || l_norm || '|';
        END IF;
        RETURN FALSE;
    END mark_or_seen;

    -- ========================================================================
    -- PRIVATE: strip_comments
    --   Removes  -- line comments  and  /* block comments */  from the query
    --   text BEFORE any helper scans it.  Earlier runs hit false negatives
    --   because line comments after a literal (e.g.  '114'  --IBW Handling )
    --   confused position-based regex matchers.  Oracle itself ignores SQL
    --   comments natively in EXPLAIN PLAN, so the stripped text is used only
    --   inside our text-scanning helpers; the original p_query is still passed
    --   to extract_sql_window for display so users see their actual source.
    -- ========================================================================
    FUNCTION strip_comments (p_text IN VARCHAR2) RETURN VARCHAR2 IS
        l_buf  VARCHAR2(32767);
        l_len  PLS_INTEGER;
        l_i    PLS_INTEGER;
        l_ch1  VARCHAR2(2);
        l_end  PLS_INTEGER;
    BEGIN
        IF p_text IS NULL THEN RETURN NULL; END IF;
        l_buf := p_text;
        l_len := NVL(LENGTH(l_buf), 0);
        l_i   := 1;
        --
        -- Walk char by char.  When we hit a comment we replace its bytes with
        -- the SAME number of spaces so every offset downstream still matches
        -- the original text.  REGEXP_REPLACE substitutes a single space — that
        -- shifted positions and broke extract_subquery_body() for predicates
        -- that came AFTER a comment.
        --
        WHILE l_i <= l_len LOOP
            l_ch1 := SUBSTR(l_buf, l_i, 2);

            IF l_ch1 = '--' THEN
                l_end := INSTR(l_buf, CHR(10), l_i);
                IF l_end = 0 THEN l_end := l_len + 1; END IF;
                IF l_end - l_i > 0 THEN
                    l_buf := SUBSTR(l_buf, 1, l_i - 1)
                          || RPAD(' ', l_end - l_i, ' ')
                          || SUBSTR(l_buf, l_end);
                END IF;
                l_i := l_end;

            ELSIF l_ch1 = '/*' THEN
                l_end := INSTR(l_buf, '*/', l_i + 2);
                IF l_end = 0 THEN
                    l_end := l_len + 1;
                ELSE
                    l_end := l_end + 2;
                END IF;
                IF l_end - l_i > 0 THEN
                    l_buf := SUBSTR(l_buf, 1, l_i - 1)
                          || RPAD(' ', l_end - l_i, ' ')
                          || SUBSTR(l_buf, l_end);
                END IF;
                l_i := l_end;

            ELSIF SUBSTR(l_buf, l_i, 1) = '''' THEN
                -- Skip past string literal so '--' inside a literal stays put.
                l_end := INSTR(l_buf, '''', l_i + 1);
                IF l_end = 0 THEN
                    l_i := l_len + 1;
                ELSE
                    l_i := l_end + 1;
                END IF;

            ELSE
                l_i := l_i + 1;
            END IF;
        END LOOP;

        RETURN l_buf;
    EXCEPTION
        WHEN OTHERS THEN RETURN p_text;
    END strip_comments;

    -- ========================================================================
    -- PRIVATE: is_sql_function
    --   TRUE when the token is a known SQL function name. Used by predicate
    --   scanners to reject "column" tokens that are actually inner function
    --   calls — e.g. NVL(DECODE(col, ...)) parses DECODE as a column unless
    --   we filter known function identifiers out.
    -- ========================================================================
    FUNCTION is_sql_function (p_token IN VARCHAR2) RETURN BOOLEAN IS
        l_t VARCHAR2(40);
    BEGIN
        IF p_token IS NULL THEN RETURN FALSE; END IF;
        l_t := UPPER(TRIM(p_token));
        RETURN l_t IN (
            'NVL','NVL2','COALESCE','NULLIF','DECODE','CASE','CAST',
            'TO_CHAR','TO_DATE','TO_NUMBER','TO_TIMESTAMP','TO_TIMESTAMP_TZ',
            'UPPER','LOWER','INITCAP','TRIM','LTRIM','RTRIM',
            'SUBSTR','SUBSTRB','INSTR','INSTRB','LENGTH','LENGTHB',
            'LPAD','RPAD','REPLACE','TRANSLATE','CONCAT',
            'REGEXP_SUBSTR','REGEXP_REPLACE','REGEXP_INSTR','REGEXP_LIKE',
            'ABS','ROUND','TRUNC','FLOOR','CEIL','CEILING','SIGN','MOD','REMAINDER',
            'POWER','SQRT','EXP','LN','LOG','SIN','COS','TAN','ASIN','ACOS','ATAN',
            'SYSDATE','SYSTIMESTAMP','CURRENT_DATE','CURRENT_TIMESTAMP',
            'EXTRACT','ADD_MONTHS','MONTHS_BETWEEN','LAST_DAY','NEXT_DAY',
            'NUMTOYMINTERVAL','NUMTODSINTERVAL','FROM_TZ',
            'SUM','AVG','COUNT','MIN','MAX','STDDEV','VARIANCE','LISTAGG',
            'MEDIAN','PERCENTILE_CONT','PERCENTILE_DISC',
            'ROW_NUMBER','RANK','DENSE_RANK','LAG','LEAD',
            'FIRST_VALUE','LAST_VALUE','NTILE','PERCENT_RANK','CUME_DIST',
            'INTERNAL_FUNCTION','SYS_OP_C2C','SYS_OP_DESCEND','SYS_GUID',
            'GREATEST','LEAST','USER','UID',
            'XMLAGG','XMLELEMENT','JSON_VALUE','JSON_QUERY'
        );
    END is_sql_function;

    -- ========================================================================
    -- PRIVATE: mask_select_projections
    --   Returns a copy of p_query in which every SELECT projection list (the
    --   text between SELECT and the matching FROM at the same paren depth) is
    --   replaced with spaces.  Lengths and offsets are preserved so downstream
    --   INSTR / REGEXP_INSTR positions still align with the ORIGINAL source —
    --   keeping extract_sql_window faithful while removing false-positive
    --   matches that previously fired on functions inside SELECT lists
    --   (e.g. SUM(NVL(DECODE(col,...))) ).
    -- ========================================================================
    FUNCTION mask_select_projections (p_query IN CLOB) RETURN VARCHAR2 IS
        l_text   VARCHAR2(32767);
        l_upper  VARCHAR2(32767);
        l_len    PLS_INTEGER;
        l_sel    PLS_INTEGER;
        l_from   PLS_INTEGER;
        l_occ    PLS_INTEGER := 1;
        l_depth  PLS_INTEGER;
        l_j      PLS_INTEGER;
        l_jch    VARCHAR2(1);
        l_jdepth PLS_INTEGER;
    BEGIN
        IF p_query IS NULL THEN RETURN NULL; END IF;
        -- Strip comments first so position-based scanning never sees them
        l_text  := strip_comments(DBMS_LOB.SUBSTR(p_query, 32767, 1));
        l_upper := UPPER(l_text);
        l_len   := NVL(LENGTH(l_upper), 0);
        IF l_len = 0 THEN RETURN l_text; END IF;

        LOOP
            l_sel := REGEXP_INSTR(
                l_upper,
                '(^|[^A-Z0-9_])(SELECT)([^A-Z0-9_]|$)',
                1, l_occ, 0, 'i', 2);
            EXIT WHEN l_sel = 0 OR l_sel IS NULL;

            -- Paren depth at l_sel = (count '(' - count ')') in the prefix
            l_depth := 0;
            IF l_sel > 1 THEN
                DECLARE
                    l_prefix VARCHAR2(32767) := SUBSTR(l_upper, 1, l_sel - 1);
                BEGIN
                    l_depth :=
                        (NVL(LENGTH(l_prefix), 0) - NVL(LENGTH(REPLACE(l_prefix, '(', '')), 0))
                      - (NVL(LENGTH(l_prefix), 0) - NVL(LENGTH(REPLACE(l_prefix, ')', '')), 0));
                END;
            END IF;

            -- Walk forward looking for FROM at the same paren depth
            l_j      := l_sel + 6;
            l_jdepth := l_depth;
            l_from   := 0;
            WHILE l_j <= l_len LOOP
                l_jch := SUBSTR(l_upper, l_j, 1);
                IF l_jch = '(' THEN
                    l_jdepth := l_jdepth + 1;
                ELSIF l_jch = ')' THEN
                    l_jdepth := l_jdepth - 1;
                    IF l_jdepth < l_depth THEN EXIT; END IF;
                ELSIF l_jdepth = l_depth
                      AND l_jch = 'F'
                      AND l_j + 3 <= l_len
                      AND SUBSTR(l_upper, l_j, 4) = 'FROM'
                      AND (l_j = 1
                           OR NOT REGEXP_LIKE(SUBSTR(l_upper, l_j - 1, 1), '[A-Z0-9_]'))
                      AND (l_j + 4 > l_len
                           OR NOT REGEXP_LIKE(SUBSTR(l_upper, l_j + 4, 1), '[A-Z0-9_]'))
                THEN
                    l_from := l_j;
                    EXIT;
                END IF;
                l_j := l_j + 1;
            END LOOP;

            IF l_from > l_sel + 6 THEN
                DECLARE
                    l_blank_len PLS_INTEGER := l_from - (l_sel + 6);
                BEGIN
                    IF l_blank_len > 0 AND l_blank_len < 32760 THEN
                        l_text  := SUBSTR(l_text,  1, l_sel + 5)
                                || RPAD(' ', l_blank_len, ' ')
                                || SUBSTR(l_text,  l_from);
                        l_upper := SUBSTR(l_upper, 1, l_sel + 5)
                                || RPAD(' ', l_blank_len, ' ')
                                || SUBSTR(l_upper, l_from);
                    END IF;
                END;
            END IF;

            l_occ := l_occ + 1;
            EXIT WHEN l_occ > 30;
        END LOOP;

        RETURN l_text;
    EXCEPTION
        WHEN OTHERS THEN
            RETURN DBMS_LOB.SUBSTR(p_query, 32767, 1);
    END mask_select_projections;

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
    -- ========================================================================
    FUNCTION escape_json (p_val IN VARCHAR2) RETURN VARCHAR2 IS
    BEGIN
        IF p_val IS NULL THEN RETURN ''; END IF;
        RETURN
            REPLACE(
              REPLACE(
                REPLACE(
                  REPLACE(
                    REPLACE(p_val, '\', '\\'),
                  '"',     '\"'),
                CHR(13),   '\r'),
              CHR(10),     '\n'),
            CHR(9),        '\t');
    END escape_json;

    -- ========================================================================
    -- PRIVATE: get_rule_id
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
    --   Returns pipe-delimited upper-cased list of every table after FROM/JOIN.
    -- ========================================================================
    FUNCTION extract_tables (p_query IN CLOB) RETURN VARCHAR2 IS
        l_upper  VARCHAR2(32767);
        l_result VARCHAR2(4000) := '';
        l_tbl    VARCHAR2(200);
        l_occ    PLS_INTEGER;
    BEGIN
        l_upper := UPPER(strip_comments(DBMS_LOB.SUBSTR(p_query, 32767, 1)));

        l_occ := 1;
        LOOP
            l_tbl := REGEXP_SUBSTR(l_upper, 'FROM\s+([A-Z][A-Z0-9_$#]*)', 1, l_occ, 'i', 1);
            EXIT WHEN l_tbl IS NULL;
            IF l_tbl NOT IN ('SELECT','DUAL','LATERAL','TABLE','XMLTABLE')
               AND INSTR(l_result, '|' || l_tbl || '|') = 0 THEN
                l_result := l_result || '|' || l_tbl;
            END IF;
            l_occ := l_occ + 1;
            EXIT WHEN l_occ > 30;
        END LOOP;

        l_occ := 1;
        LOOP
            l_tbl := REGEXP_SUBSTR(l_upper, 'JOIN\s+([A-Z][A-Z0-9_$#]*)', 1, l_occ, 'i', 1);
            EXIT WHEN l_tbl IS NULL;
            IF l_tbl NOT IN ('SELECT','DUAL','LATERAL','TABLE','XMLTABLE')
               AND INSTR(l_result, '|' || l_tbl || '|') = 0 THEN
                l_result := l_result || '|' || l_tbl;
            END IF;
            l_occ := l_occ + 1;
            EXIT WHEN l_occ > 30;
        END LOOP;

        RETURN LTRIM(l_result, '|');
    EXCEPTION
        WHEN OTHERS THEN RETURN '';
    END extract_tables;

    -- ========================================================================
    -- PRIVATE: extract_where_columns
    -- ========================================================================
    FUNCTION extract_where_columns (p_query IN CLOB) RETURN VARCHAR2 IS
        l_upper     VARCHAR2(32767);
        l_where_str VARCHAR2(32767);
        l_where_pos PLS_INTEGER;
        l_result    VARCHAR2(4000) := '';
        l_full_tok  VARCHAR2(200);
        l_col       VARCHAR2(200);
        l_occ       PLS_INTEGER := 1;
        l_skip_kws  VARCHAR2(1000) :=
            '|AND|OR|NOT|NULL|IS|EXISTS|BETWEEN|LIKE|IN|WHERE|HAVING|'
         || 'CASE|WHEN|THEN|ELSE|END|SELECT|FROM|JOIN|ON|GROUP|ORDER|'
         || 'BY|FETCH|FIRST|ROWS|ONLY|DISTINCT|UNION|MINUS|INTERSECT|'
         || 'INNER|LEFT|RIGHT|OUTER|CROSS|FULL|INTO|VALUES|RETURNING|';
    BEGIN
        l_upper := UPPER(strip_comments(DBMS_LOB.SUBSTR(p_query, 32767, 1)));
        l_where_pos := INSTR(l_upper, ' WHERE ');
        IF l_where_pos = 0 THEN RETURN ''; END IF;
        l_where_str := SUBSTR(l_upper, l_where_pos + 7);

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

        LOOP
            l_full_tok := REGEXP_SUBSTR(
                l_where_str,
                '[A-Z][A-Z0-9_.]*\s*(=|<>|!=|<|>|LIKE|BETWEEN|IN\s*\()',
                1, l_occ, 'i');
            EXIT WHEN l_full_tok IS NULL;
            l_col := REGEXP_SUBSTR(l_full_tok, '^[A-Z][A-Z0-9_.]*', 1, 1, 'i');
            IF INSTR(l_col, '.') > 0 THEN
                l_col := SUBSTR(l_col, INSTR(l_col, '.') + 1);
            END IF;
            l_col := UPPER(TRIM(l_col));
            IF LENGTH(l_col) > 0
               AND INSTR(l_skip_kws, '|' || l_col || '|') = 0
               AND INSTR(l_result, '|' || l_col || '|') = 0 THEN
                l_result := l_result || '|' || l_col;
            END IF;
            l_occ := l_occ + 1;
            EXIT WHEN l_occ > 50;
        END LOOP;

        RETURN LTRIM(l_result, '|');
    EXCEPTION
        WHEN OTHERS THEN RETURN '';
    END extract_where_columns;

    -- ========================================================================
    -- PRIVATE: extract_join_columns
    --   Picks up columns appearing in JOIN ... ON predicates and in
    --   WHERE  alias.col = alias.col  cross-table predicates.
    --   Returns pipe-delimited list of column names (no alias prefix).
    -- ========================================================================
    FUNCTION extract_join_columns (p_query IN CLOB) RETURN VARCHAR2 IS
        l_upper  VARCHAR2(32767);
        l_result VARCHAR2(4000) := '';
        l_match  VARCHAR2(400);
        l_col    VARCHAR2(200);
        l_occ    PLS_INTEGER;
    BEGIN
        l_upper := UPPER(strip_comments(DBMS_LOB.SUBSTR(p_query, 32767, 1)));

        -- Pattern 1: JOIN tbl ON alias.col = alias.col
        --   capture both column names from each ON
        l_occ := 1;
        LOOP
            l_match := REGEXP_SUBSTR(
                l_upper,
                'ON\s+[A-Z][A-Z0-9_]*\.([A-Z][A-Z0-9_]*)\s*=\s*[A-Z][A-Z0-9_]*\.([A-Z][A-Z0-9_]*)',
                1, l_occ, 'i');
            EXIT WHEN l_match IS NULL;

            FOR g IN 1..2 LOOP
                l_col := REGEXP_SUBSTR(
                    l_match,
                    'ON\s+[A-Z][A-Z0-9_]*\.([A-Z][A-Z0-9_]*)\s*=\s*[A-Z][A-Z0-9_]*\.([A-Z][A-Z0-9_]*)',
                    1, 1, 'i', g);
                IF l_col IS NOT NULL
                   AND INSTR(l_result, '|' || l_col || '|') = 0 THEN
                    l_result := l_result || '|' || l_col;
                END IF;
            END LOOP;

            l_occ := l_occ + 1;
            EXIT WHEN l_occ > 30;
        END LOOP;

        -- Pattern 2: WHERE alias.col = alias.col (implicit join)
        l_occ := 1;
        LOOP
            l_match := REGEXP_SUBSTR(
                l_upper,
                '[A-Z][A-Z0-9_]*\.([A-Z][A-Z0-9_]*)\s*=\s*[A-Z][A-Z0-9_]*\.([A-Z][A-Z0-9_]*)',
                1, l_occ, 'i');
            EXIT WHEN l_match IS NULL;

            FOR g IN 1..2 LOOP
                l_col := REGEXP_SUBSTR(
                    l_match,
                    '[A-Z][A-Z0-9_]*\.([A-Z][A-Z0-9_]*)\s*=\s*[A-Z][A-Z0-9_]*\.([A-Z][A-Z0-9_]*)',
                    1, 1, 'i', g);
                IF l_col IS NOT NULL
                   AND INSTR(l_result, '|' || l_col || '|') = 0 THEN
                    l_result := l_result || '|' || l_col;
                END IF;
            END LOOP;

            l_occ := l_occ + 1;
            EXIT WHEN l_occ > 30;
        END LOOP;

        RETURN LTRIM(l_result, '|');
    EXCEPTION
        WHEN OTHERS THEN RETURN '';
    END extract_join_columns;

    -- ========================================================================
    -- PRIVATE: extract_groupby_orderby
    --   Returns pipe-delimited columns mentioned in GROUP BY and ORDER BY.
    -- ========================================================================
    FUNCTION extract_groupby_orderby (p_query IN CLOB) RETURN VARCHAR2 IS
        l_upper  VARCHAR2(32767);
        l_clause VARCHAR2(4000);
        l_result VARCHAR2(4000) := '';
        l_pos    PLS_INTEGER;
        l_end    PLS_INTEGER;
        l_col    VARCHAR2(200);
        l_occ    PLS_INTEGER;
    BEGIN
        l_upper := UPPER(strip_comments(DBMS_LOB.SUBSTR(p_query, 32767, 1)));

        FOR kw IN (
            SELECT ' GROUP BY '  k FROM DUAL UNION ALL
            SELECT ' ORDER BY '    FROM DUAL
        ) LOOP
            l_pos := INSTR(l_upper, kw.k);
            IF l_pos > 0 THEN
                l_end := LEAST(
                    CASE WHEN INSTR(l_upper, ' HAVING ', l_pos) > 0
                         THEN INSTR(l_upper, ' HAVING ', l_pos) ELSE 99999 END,
                    CASE WHEN INSTR(l_upper, ' ORDER ', l_pos + LENGTH(kw.k)) > 0
                         THEN INSTR(l_upper, ' ORDER ', l_pos + LENGTH(kw.k)) ELSE 99999 END,
                    CASE WHEN INSTR(l_upper, ' FETCH ', l_pos) > 0
                         THEN INSTR(l_upper, ' FETCH ', l_pos) ELSE 99999 END,
                    CASE WHEN INSTR(l_upper, ' UNION ', l_pos) > 0
                         THEN INSTR(l_upper, ' UNION ', l_pos) ELSE 99999 END
                );
                IF l_end = 99999 THEN l_end := LENGTH(l_upper); END IF;
                l_clause := SUBSTR(l_upper, l_pos + LENGTH(kw.k), l_end - l_pos - LENGTH(kw.k));

                l_occ := 1;
                LOOP
                    l_col := REGEXP_SUBSTR(l_clause, '([A-Z][A-Z0-9_]*\.)?([A-Z][A-Z0-9_]*)', 1, l_occ, 'i', 2);
                    EXIT WHEN l_col IS NULL;
                    l_col := UPPER(TRIM(l_col));
                    IF LENGTH(l_col) > 0
                       AND l_col NOT IN ('ASC','DESC','NULLS','FIRST','LAST')
                       AND INSTR(l_result, '|' || l_col || '|') = 0 THEN
                        l_result := l_result || '|' || l_col;
                    END IF;
                    l_occ := l_occ + 1;
                    EXIT WHEN l_occ > 30;
                END LOOP;
            END IF;
        END LOOP;

        RETURN LTRIM(l_result, '|');
    EXCEPTION
        WHEN OTHERS THEN RETURN '';
    END extract_groupby_orderby;

    -- ========================================================================
    -- PRIVATE: is_column_indexed
    --   TRUE if any index on p_table has p_column as the leading column.
    -- ========================================================================
    FUNCTION is_column_indexed (p_table IN VARCHAR2, p_column IN VARCHAR2)
        RETURN BOOLEAN IS
        l_cnt NUMBER;
    BEGIN
        SELECT COUNT(*) INTO l_cnt
        FROM   all_ind_columns
        WHERE  table_name      = p_table
          AND  column_name     = p_column
          AND  column_position = 1;
        RETURN l_cnt > 0;
    EXCEPTION
        WHEN OTHERS THEN RETURN FALSE;
    END is_column_indexed;

    -- ========================================================================
    -- PRIVATE: column_exists_on_table
    -- ========================================================================
    FUNCTION column_exists_on_table (p_table IN VARCHAR2, p_column IN VARCHAR2)
        RETURN BOOLEAN IS
        l_cnt NUMBER;
    BEGIN
        SELECT COUNT(*) INTO l_cnt
        FROM   all_tab_columns
        WHERE  table_name = p_table AND column_name = p_column;
        RETURN l_cnt > 0;
    EXCEPTION
        WHEN OTHERS THEN RETURN FALSE;
    END column_exists_on_table;

    -- ========================================================================
    -- PRIVATE: get_table_metrics
    --   Reads NUM_ROWS, BLOCKS, AVG_ROW_LEN from USER_TABLES.
    --   All OUT params are NULL when stats are missing.
    -- ========================================================================
    PROCEDURE get_table_metrics (
        p_table       IN  VARCHAR2,
        p_num_rows    OUT NUMBER,
        p_blocks      OUT NUMBER,
        p_avg_row_len OUT NUMBER
    ) IS
    BEGIN
        -- ALL_TABLES: visible to current user, may show multiple owners.
        -- Take the row with the highest NUM_ROWS (most informative stats).
        SELECT num_rows, blocks, avg_row_len
        INTO   p_num_rows, p_blocks, p_avg_row_len
        FROM   (
            SELECT num_rows, blocks, avg_row_len
            FROM   all_tables
            WHERE  table_name = p_table
            ORDER BY NVL(num_rows, 0) DESC NULLS LAST
        )
        WHERE  ROWNUM = 1;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN
            p_num_rows := NULL; p_blocks := NULL; p_avg_row_len := NULL;
        WHEN OTHERS THEN
            p_num_rows := NULL; p_blocks := NULL; p_avg_row_len := NULL;
    END get_table_metrics;

    -- ========================================================================
    -- PRIVATE: build_table_summary
    --   Build a CLOB block summarising one table: size, indexes, PK, columns.
    -- ========================================================================
    FUNCTION build_table_summary (p_table IN VARCHAR2) RETURN CLOB IS
        l_buf       CLOB;
        l_rows      NUMBER;
        l_blocks    NUMBER;
        l_avg_row   NUMBER;
        l_col_cnt   NUMBER;
        l_pk_cols   VARCHAR2(2000) := '';
        l_idx_block VARCHAR2(4000) := '';
    BEGIN
        DBMS_LOB.CREATETEMPORARY(l_buf, TRUE);
        get_table_metrics(p_table, l_rows, l_blocks, l_avg_row);

        BEGIN
            SELECT COUNT(*) INTO l_col_cnt
            FROM   all_tab_columns
            WHERE  table_name = p_table;
        EXCEPTION
            WHEN OTHERS THEN l_col_cnt := 0;
        END;

        -- Primary key columns (ordered by position) — across all schemas user can see
        BEGIN
            FOR rec IN (
                SELECT cc.column_name
                FROM   all_constraints c
                JOIN   all_cons_columns cc
                  ON   cc.constraint_name = c.constraint_name
                  AND  cc.owner           = c.owner
                WHERE  c.table_name      = p_table
                  AND  c.constraint_type = 'P'
                ORDER BY cc.position
            ) LOOP
                IF NVL(LENGTH(l_pk_cols), 0) > 0 THEN l_pk_cols := l_pk_cols || ', '; END IF;
                l_pk_cols := l_pk_cols || rec.column_name;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        -- Index list with leading columns
        BEGIN
            FOR rec IN (
                SELECT i.index_name, i.uniqueness, i.index_type,
                       LISTAGG(ic.column_name, ', ')
                         WITHIN GROUP (ORDER BY ic.column_position) AS cols
                FROM   all_indexes i
                JOIN   all_ind_columns ic
                  ON   ic.index_name  = i.index_name
                  AND  ic.index_owner = i.owner
                WHERE  i.table_name = p_table
                GROUP  BY i.index_name, i.uniqueness, i.index_type
                ORDER  BY i.index_name
            ) LOOP
                l_idx_block := l_idx_block
                    || '--   ' || RPAD(rec.uniqueness, 9) || rec.index_name
                    || '(' || rec.cols || ')'  || CHR(10);
                EXIT WHEN NVL(LENGTH(l_idx_block), 0) > 3500;
            END LOOP;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        -- Compose
        DBMS_LOB.WRITEAPPEND(l_buf,
            LENGTH('-- ============================================' || CHR(10)),
            '-- ============================================' || CHR(10));
        DBMS_LOB.WRITEAPPEND(l_buf,
            LENGTH('-- TABLE: ' || p_table || CHR(10)),
            '-- TABLE: ' || p_table || CHR(10));

        DECLARE l_tmp VARCHAR2(400);
        BEGIN
            l_tmp := '--   Rows:        '
                  || NVL(TO_CHAR(l_rows, 'FM999G999G999G999'), '<no stats>')
                  || CHR(10);
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_tmp), l_tmp);

            l_tmp := '--   Blocks:      '
                  || NVL(TO_CHAR(l_blocks, 'FM999G999G999'), '<no stats>')
                  || CHR(10);
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_tmp), l_tmp);

            l_tmp := '--   Avg row len: '
                  || NVL(TO_CHAR(l_avg_row), '<no stats>') || ' bytes'
                  || CHR(10);
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_tmp), l_tmp);

            l_tmp := '--   Columns:     ' || NVL(TO_CHAR(l_col_cnt), '0') || CHR(10);
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_tmp), l_tmp);

            l_tmp := '--   Primary key: '
                  || NVL(l_pk_cols, '<none>') || CHR(10);
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_tmp), l_tmp);
        END;

        IF NVL(LENGTH(l_idx_block), 0) > 0 THEN
            DBMS_LOB.WRITEAPPEND(l_buf,
                LENGTH('--   Indexes:' || CHR(10)),
                '--   Indexes:' || CHR(10));
            DBMS_LOB.WRITEAPPEND(l_buf, LENGTH(l_idx_block), l_idx_block);
        ELSE
            DBMS_LOB.WRITEAPPEND(l_buf,
                LENGTH('--   Indexes:    <none>' || CHR(10)),
                '--   Indexes:    <none>' || CHR(10));
        END IF;

        RETURN l_buf;
    EXCEPTION
        WHEN OTHERS THEN RETURN NULL;
    END build_table_summary;

    -- ========================================================================
    -- PRIVATE: find_table_alias
    --   Given a fully-qualified table name, scan the source for
    --     FROM <table> [AS] <alias>
    --     JOIN <table> [AS] <alias>
    --   and return the first alias found. NULL when the table is referenced
    --   without an alias.
    -- ========================================================================
    FUNCTION find_table_alias (p_query IN CLOB, p_table IN VARCHAR2)
        RETURN VARCHAR2 IS
        l_upper VARCHAR2(32767);
        l_alias VARCHAR2(60);
        l_kws   VARCHAR2(400) :=
            '|JOIN|ON|WHERE|GROUP|ORDER|LEFT|RIGHT|INNER|OUTER|FULL|CROSS|'
         || 'HAVING|UNION|MINUS|INTERSECT|AND|OR|FETCH|SELECT|FROM|PARTITION|';
    BEGIN
        l_upper := UPPER(strip_comments(DBMS_LOB.SUBSTR(p_query, 32767, 1)));

        l_alias := REGEXP_SUBSTR(
            l_upper,
            '(?:FROM|JOIN)\s+' || p_table || '\s+(AS\s+)?([A-Z][A-Z0-9_]*)',
            1, 1, 'i', 2);

        IF l_alias IS NULL THEN RETURN NULL; END IF;
        IF INSTR(l_kws, '|' || l_alias || '|') > 0 THEN RETURN NULL; END IF;
        RETURN l_alias;
    EXCEPTION
        WHEN OTHERS THEN RETURN NULL;
    END find_table_alias;

    -- ========================================================================
    -- PRIVATE: extract_sql_window
    --   Returns a small window of source SQL around p_position, expanded out
    --   to the nearest line breaks before/after, capped at p_max chars.
    --   Useful for showing the exact predicate / fragment that triggered a rule.
    -- ========================================================================
    FUNCTION extract_sql_window (
        p_query     IN CLOB,
        p_position  IN PLS_INTEGER,
        p_radius    IN PLS_INTEGER DEFAULT 80,
        p_max       IN PLS_INTEGER DEFAULT 360
    ) RETURN VARCHAR2 IS
        l_text VARCHAR2(32767);
        l_lo   PLS_INTEGER;
        l_hi   PLS_INTEGER;
        l_nl_b PLS_INTEGER;
        l_nl_a PLS_INTEGER;
    BEGIN
        IF p_query IS NULL OR p_position IS NULL OR p_position < 1 THEN
            RETURN NULL;
        END IF;
        l_text := DBMS_LOB.SUBSTR(p_query, 32767, 1);

        l_lo := GREATEST(1,                       p_position - p_radius);
        l_hi := LEAST   (NVL(LENGTH(l_text), 0),  p_position + p_radius);
        IF l_hi <= l_lo THEN RETURN NULL; END IF;

        -- Expand back to start of line: search the prefix [1..l_lo] backward
        l_nl_b := INSTR(SUBSTR(l_text, 1, l_lo), CHR(10), -1, 1);
        IF l_nl_b > 0 AND l_lo - l_nl_b < 200 THEN l_lo := l_nl_b + 1; END IF;
        -- Expand forward to end of line
        l_nl_a := INSTR(l_text, CHR(10), l_hi);
        IF l_nl_a > 0 AND l_nl_a - l_hi < 200 THEN l_hi := l_nl_a - 1; END IF;

        IF (l_hi - l_lo + 1) > p_max THEN
            l_hi := l_lo + p_max - 1;
        END IF;

        RETURN TRIM(SUBSTR(l_text, l_lo, l_hi - l_lo + 1));
    EXCEPTION
        WHEN OTHERS THEN RETURN NULL;
    END extract_sql_window;

    -- ========================================================================
    -- PRIVATE: extract_subquery_body
    --   Given a position pointing at the '(' that opens a subquery, walk
    --   forward matching parens and return the contents (without outer parens).
    --   Capped at p_max chars to keep one row's payload sane.
    -- ========================================================================
    FUNCTION extract_subquery_body (
        p_query     IN CLOB,
        p_open_pos  IN PLS_INTEGER,
        p_max       IN PLS_INTEGER DEFAULT 1500
    ) RETURN VARCHAR2 IS
        l_text  VARCHAR2(32767);
        l_depth PLS_INTEGER := 0;
        l_i     PLS_INTEGER;
        l_ch    VARCHAR2(1);
        l_end   PLS_INTEGER;
        l_size  PLS_INTEGER;
    BEGIN
        IF p_query IS NULL OR p_open_pos IS NULL OR p_open_pos < 1 THEN
            RETURN NULL;
        END IF;
        l_text := DBMS_LOB.SUBSTR(p_query, 32767, 1);
        IF SUBSTR(l_text, p_open_pos, 1) != '(' THEN RETURN NULL; END IF;

        l_i := p_open_pos;
        WHILE l_i <= LENGTH(l_text) LOOP
            l_ch := SUBSTR(l_text, l_i, 1);
            IF l_ch = '(' THEN
                l_depth := l_depth + 1;
            ELSIF l_ch = ')' THEN
                l_depth := l_depth - 1;
                IF l_depth = 0 THEN
                    l_end := l_i;
                    EXIT;
                END IF;
            END IF;
            l_i := l_i + 1;
            EXIT WHEN l_i - p_open_pos > 8000;  -- safety cap
        END LOOP;

        IF l_end IS NULL THEN
            -- Unbalanced — return what we have so far
            l_end := LEAST(p_open_pos + p_max + 1, LENGTH(l_text));
        END IF;

        l_size := LEAST(l_end - p_open_pos - 1, p_max);
        IF l_size <= 0 THEN RETURN NULL; END IF;
        RETURN TRIM(SUBSTR(l_text, p_open_pos + 1, l_size));
    EXCEPTION
        WHEN OTHERS THEN RETURN NULL;
    END extract_subquery_body;

    -- ========================================================================
    -- RULE 1: SELECT *
    -- ========================================================================
    PROCEDURE rule_select_star (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_sample VARCHAR2(1000);
    BEGIN
        p_triggered := FALSE;
        l_sample    := UPPER(strip_comments(DBMS_LOB.SUBSTR(p_query, 500, 1)));

        IF REGEXP_LIKE(l_sample, 'SELECT\s+\*') THEN
            p_triggered := TRUE;
            persist_result(
                p_query_id,
                'SELECT_STAR_DETECTED',
                'MEDIUM',
                'SELECT * detected — every column is fetched, blocking covering index scans',
                NULL,
                '-- Replace SELECT * with an explicit column list:' || CHR(10)
             || '-- SELECT col1, col2, col3 FROM ...'
            );
        END IF;
    END rule_select_star;

    -- ========================================================================
    -- RULE 2: Full Table Scan (ENHANCED)
    --   Reads PLAN_TABLE directly to capture per-table cost & cardinality,
    --   then enriches each finding with USER_TABLES.NUM_ROWS so the user can
    --   judge severity (50-row lookup vs 50M-row fact table).
    -- ========================================================================
    PROCEDURE rule_full_table_scan (
        p_stmt_id   IN  VARCHAR2,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_context  VARCHAR2(4000) := '';
        l_real_rows NUMBER;
        l_blocks    NUMBER;
        l_avg_row   NUMBER;
        l_count     PLS_INTEGER := 0;
        -- Below this row count a full scan is genuinely the cheapest access
        -- path (a single block read beats any index lookup overhead). Skip
        -- the rule entirely for these rather than emit a HIGH-severity
        -- false-positive that the user has to manually dismiss every time.
        c_tiny_table_threshold CONSTANT NUMBER := 256;
    BEGIN
        p_triggered := FALSE;

        FOR rec IN (
            SELECT object_name, object_owner, cost, cardinality
            FROM   plan_table
            WHERE  statement_id = p_stmt_id
              AND  operation    = 'TABLE ACCESS'
              AND  options      = 'FULL'
              AND  object_name IS NOT NULL
            ORDER BY id
        ) LOOP
            -- Skip DUAL — Oracle's canonical singleton table. Full scan is
            -- the only access path; flagging it is always noise.
            IF UPPER(rec.object_name) = 'DUAL' THEN
                CONTINUE;
            END IF;

            get_table_metrics(rec.object_name, l_real_rows, l_blocks, l_avg_row);

            -- Skip tiny tables. A FULL scan of <256 rows with <2 blocks is
            -- cheaper than the index lookup it would replace, and ships
            -- exactly zero actionable advice to the user.
            IF l_real_rows IS NOT NULL
               AND l_real_rows <= c_tiny_table_threshold
               AND NVL(l_blocks, 0) <= 2
            THEN
                CONTINUE;
            END IF;

            p_triggered := TRUE;
            l_count     := l_count + 1;

            l_context := l_context
                || rec.object_name
                || ' (FTS, plan cost=' || NVL(TO_CHAR(rec.cost), '?')
                || ', plan rows=' || NVL(TO_CHAR(rec.cardinality), '?')
                || ', table actual rows='
                || NVL(TO_CHAR(l_real_rows, 'FM999G999G999'), '<no stats>')
                || ', blocks=' || NVL(TO_CHAR(l_blocks), '<no stats>')
                || '); ';

            EXIT WHEN LENGTH(l_context) > 3800;
        END LOOP;

        IF p_triggered THEN
            persist_result(
                p_query_id,
                'FULL_TABLE_SCAN_DETECTED',
                'HIGH',
                'Full table scan on ' || l_count || ' table(s): '
                  || SUBSTR(l_context, 1, 3500),
                NULL,
                NULL
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_full_table_scan;

    -- ========================================================================
    -- RULE 3: Missing Index — PER-(TABLE, COLUMN) EMISSION
    --   For every (table, column) hit where:
    --     - the column is referenced in a WHERE predicate or JOIN ON,
    --     - the column actually exists on that table,
    --     - and there is no index with the column as its leading key,
    --   we emit ONE rule row carrying:
    --     - context_info     : "TBL.COL — <role> on <size> table"
    --     - index_recommendation: a focused CREATE INDEX DDL for that column
    --     - optimized_fragment: the source SQL window around the actual
    --                          predicate (alias.col preferred over bare col)
    --   Capped at c_max_emit findings to keep the report readable.
    -- ========================================================================
    PROCEDURE rule_missing_indexes (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_tables    VARCHAR2(4000);
        l_filters   VARCHAR2(4000);
        l_joins     VARCHAR2(4000);
        l_all_cols  VARCHAR2(8000);
        l_tbl       VARCHAR2(200);
        l_col       VARCHAR2(200);
        l_t_rest    VARCHAR2(4000);
        l_c_rest    VARCHAR2(8000);
        l_t_pipe    PLS_INTEGER;
        l_c_pipe    PLS_INTEGER;
        l_role      VARCHAR2(30);

        l_alias       VARCHAR2(60);
        l_pos         PLS_INTEGER;
        l_window      VARCHAR2(500);
        l_rows        NUMBER;
        l_blocks      NUMBER;
        l_avg_row_len NUMBER;
        l_size_tag    VARCHAR2(160);
        l_priority    VARCHAR2(20);
        l_severity    VARCHAR2(10);
        l_context     VARCHAR2(2000);
        l_ddl         CLOB;
        l_fragment    CLOB;
        l_emitted     PLS_INTEGER := 0;
        c_max_emit CONSTANT PLS_INTEGER := 12;
    BEGIN
        p_triggered := FALSE;
        l_tables    := extract_tables(p_query);
        l_filters   := extract_where_columns(p_query);
        l_joins     := extract_join_columns(p_query);

        IF l_tables IS NULL OR LENGTH(l_tables) = 0 THEN RETURN; END IF;

        -- Combine filter + join columns (deduped via pipe-bracketing test)
        l_all_cols := l_filters;
        IF NVL(LENGTH(l_joins), 0) > 0 THEN
            FOR jc IN (
                SELECT REGEXP_SUBSTR(l_joins, '[^|]+', 1, LEVEL) AS col
                FROM   DUAL
                CONNECT BY REGEXP_SUBSTR(l_joins, '[^|]+', 1, LEVEL) IS NOT NULL
            ) LOOP
                IF jc.col IS NOT NULL
                   AND INSTR('|' || NVL(l_all_cols, '') || '|', '|' || jc.col || '|') = 0 THEN
                    l_all_cols := CASE WHEN NVL(LENGTH(l_all_cols), 0) = 0
                                       THEN jc.col
                                       ELSE l_all_cols || '|' || jc.col END;
                END IF;
            END LOOP;
        END IF;

        IF l_all_cols IS NULL OR LENGTH(l_all_cols) = 0 THEN RETURN; END IF;

        l_t_rest := l_tables;
        <<table_loop>>
        WHILE NVL(LENGTH(l_t_rest), 0) > 0 LOOP
            EXIT table_loop WHEN l_emitted >= c_max_emit;

            l_t_pipe := INSTR(l_t_rest, '|');
            IF l_t_pipe > 0 THEN
                l_tbl    := SUBSTR(l_t_rest, 1, l_t_pipe - 1);
                l_t_rest := SUBSTR(l_t_rest, l_t_pipe + 1);
            ELSE
                l_tbl    := l_t_rest;
                l_t_rest := '';
            END IF;

            -- Resolve alias once per table (used for predicate localization)
            l_alias := find_table_alias(p_query, l_tbl);

            -- Pull table size once per table
            get_table_metrics(l_tbl, l_rows, l_blocks, l_avg_row_len);

            IF l_rows IS NULL THEN
                l_size_tag := 'size unknown (no stats)';
                l_priority := 'unknown';
                l_severity := 'HIGH';
            ELSIF l_rows < 1000 THEN
                l_size_tag := TO_CHAR(l_rows, 'FM999G999') || ' rows — small lookup';
                l_priority := 'low';
                l_severity := 'LOW';   -- FTS on tiny tables is harmless
            ELSIF l_rows < 100000 THEN
                l_size_tag := TO_CHAR(l_rows, 'FM999G999') || ' rows';
                l_priority := 'medium';
                l_severity := 'MEDIUM';
            ELSE
                l_size_tag := TO_CHAR(l_rows, 'FM999G999G999') || ' rows — large';
                l_priority := 'high';
                l_severity := 'HIGH';
            END IF;

            l_c_rest := l_all_cols;
            WHILE NVL(LENGTH(l_c_rest), 0) > 0 LOOP
                EXIT WHEN l_emitted >= c_max_emit;

                l_c_pipe := INSTR(l_c_rest, '|');
                IF l_c_pipe > 0 THEN
                    l_col    := SUBSTR(l_c_rest, 1, l_c_pipe - 1);
                    l_c_rest := SUBSTR(l_c_rest, l_c_pipe + 1);
                ELSE
                    l_col    := l_c_rest;
                    l_c_rest := '';
                END IF;

                IF column_exists_on_table(l_tbl, l_col)
                   AND NOT is_column_indexed(l_tbl, l_col) THEN

                    -- Role: filter / join / both
                    l_role := CASE
                                WHEN INSTR('|' || l_joins   || '|', '|' || l_col || '|') > 0
                                  AND INSTR('|' || l_filters || '|', '|' || l_col || '|') > 0
                                THEN 'filter + join key'
                                WHEN INSTR('|' || l_joins || '|', '|' || l_col || '|') > 0
                                THEN 'join key'
                                ELSE 'filter column'
                              END;

                    -- Try alias.col first, then bare col, to localize the predicate
                    l_pos := 0;
                    IF l_alias IS NOT NULL THEN
                        l_pos := REGEXP_INSTR(
                            UPPER(DBMS_LOB.SUBSTR(p_query, 32767, 1)),
                            '\W' || l_alias || '\.' || l_col || '\W',
                            1, 1, 0, 'i');
                    END IF;
                    IF l_pos = 0 THEN
                        l_pos := REGEXP_INSTR(
                            UPPER(DBMS_LOB.SUBSTR(p_query, 32767, 1)),
                            '\W' || l_col || '\W',
                            1, 1, 0, 'i');
                    END IF;

                    IF l_pos > 0 THEN
                        l_window := extract_sql_window(p_query, l_pos + 1, 90, 320);
                    ELSE
                        l_window := NULL;
                    END IF;

                    p_triggered := TRUE;
                    l_emitted   := l_emitted + 1;

                    l_context := l_tbl || '.' || l_col
                              || ' — ' || l_role
                              || ' on ' || l_size_tag
                              || ' (priority=' || l_priority || ')';

                    l_ddl := 'CREATE INDEX idx_'
                          || LOWER(l_tbl) || '_' || LOWER(l_col)
                          || CHR(10)
                          || '  ON ' || l_tbl || ' (' || l_col || ');';

                    l_fragment :=
                           '-- Predicate referencing this column:' || CHR(10)
                        || NVL(l_window, '<could not locate predicate in source>')
                        || CHR(10)
                        || CHR(10)
                        || '-- Why this matters:' || CHR(10)
                        || '--   * Role:           ' || l_role || CHR(10)
                        || '--   * Table size:     ' || l_size_tag || CHR(10)
                        || '--   * Existing index: NONE on '
                            || l_tbl || '(' || l_col || ' ...)' || CHR(10)
                        || CHR(10)
                        || CASE l_priority
                             WHEN 'high' THEN
                                  '-- Recommendation: create the index above. On large tables'
                               || CHR(10)
                               || '--   the cost-based optimizer will switch to INDEX RANGE SCAN'
                               || CHR(10)
                               || '--   once stats are gathered: '
                               || 'EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, ''' || l_tbl || ''');'
                             WHEN 'low' THEN
                                  '-- Recommendation: a full scan on a small table is usually'
                               || CHR(10)
                               || '--   cheaper than maintaining an index — verify before adding.'
                             ELSE
                                  '-- Recommendation: add the index. If the column is also part'
                               || CHR(10)
                               || '--   of a WHERE filter, prefer a composite index leading with'
                               || CHR(10)
                               || '--   the most selective column.'
                           END;

                    persist_result(
                        p_query_id,
                        'MISSING_INDEX_ON_FILTER',
                        l_severity,
                        SUBSTR(l_context, 1, 4000),
                        l_ddl,
                        l_fragment
                    );
                END IF;
            END LOOP;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_missing_indexes;

    -- ========================================================================
    -- RULE 4: Function on Indexed Column (PRECISION REWRITE)
    --   For every FUNCTION(table.column) hit in a WHERE / HAVING / ON predicate
    --   we emit ONE row per (function, table_qualified_column) pair.
    --
    --   Key precision improvements vs. previous version:
    --     * mask_select_projections() removes SELECT-list text before scanning,
    --       so functions inside SUM(NVL(DECODE(...))) projections no longer
    --       trigger this WHERE-only rule.
    --     * is_sql_function() rejects "column" tokens that are actually nested
    --       function calls (NVL(DECODE(...))  -> DECODE is not a column).
    --     * mark_or_seen() de-duplicates by (function, table.column) — one
    --       finding per real predicate, not one per UNION branch.
    --     * Severity is HIGH when the wrapped column is a JOIN key (kills the
    --       join's index access) and MEDIUM otherwise.
    --   Capped at c_max_emit hits.
    -- ========================================================================
    PROCEDURE rule_function_on_column (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_masked      VARCHAR2(32767);
        l_upper       VARCHAR2(32767);
        l_where_pos   PLS_INTEGER;
        l_match       VARCHAR2(400);
        l_pos         PLS_INTEGER;
        l_alias       VARCHAR2(50);
        l_col         VARCHAR2(100);
        l_table_qual  VARCHAR2(160);
        l_window      VARCHAR2(500);
        l_context     VARCHAR2(2000);
        l_fragment    CLOB;
        l_emitted     PLS_INTEGER := 0;
        l_occ         PLS_INTEGER;
        l_join_cols   VARCHAR2(4000);
        l_severity    VARCHAR2(10);
        l_dedupe_key  VARCHAR2(400);
        c_max_emit CONSTANT PLS_INTEGER := 8;

        TYPE t_fn_tab IS TABLE OF VARCHAR2(30);
        l_fns t_fn_tab := t_fn_tab(
            'UPPER', 'LOWER', 'TRUNC', 'TO_DATE', 'TO_NUMBER',
            'TO_CHAR', 'SUBSTR', 'NVL', 'TRIM', 'LTRIM', 'RTRIM',
            'DECODE', 'ROUND', 'FLOOR', 'CEIL', 'LENGTH', 'INSTR'
        );
    BEGIN
        p_triggered := FALSE;

        -- Mask out SELECT projections so we only scan WHERE/HAVING/ON regions
        l_masked := mask_select_projections(p_query);
        IF l_masked IS NULL THEN RETURN; END IF;
        l_upper := UPPER(l_masked);

        l_where_pos := INSTR(l_upper, ' WHERE ');
        IF l_where_pos = 0 THEN RETURN; END IF;

        l_join_cols := UPPER(NVL(extract_join_columns(p_query), ''));

        FOR i IN 1 .. l_fns.COUNT LOOP
            EXIT WHEN l_emitted >= c_max_emit;
            l_occ := 1;
            LOOP
                EXIT WHEN l_emitted >= c_max_emit;

                l_pos := REGEXP_INSTR(
                    l_upper,
                    '\W' || l_fns(i) || '\s*\(',
                    l_where_pos, l_occ, 0, 'i');
                EXIT WHEN l_pos = 0 OR l_pos IS NULL;

                l_match := REGEXP_SUBSTR(
                    l_upper,
                    l_fns(i) || '\s*\(\s*([A-Z][A-Z0-9_]*\.)?([A-Z][A-Z0-9_$#]*)',
                    l_pos, 1, 'i', 0);

                IF l_match IS NULL THEN
                    l_occ := l_occ + 1;
                    CONTINUE;
                END IF;

                l_alias := REGEXP_SUBSTR(
                    l_match,
                    l_fns(i) || '\s*\(\s*([A-Z][A-Z0-9_]*\.)?([A-Z][A-Z0-9_$#]*)',
                    1, 1, 'i', 1);
                l_col   := REGEXP_SUBSTR(
                    l_match,
                    l_fns(i) || '\s*\(\s*([A-Z][A-Z0-9_]*\.)?([A-Z][A-Z0-9_$#]*)',
                    1, 1, 'i', 2);

                -- Reject when the captured "column" is actually another SQL
                -- function name (e.g. NVL(DECODE(col,...)) — DECODE is not a col).
                IF is_sql_function(l_col) THEN
                    l_occ := l_occ + 1;
                    CONTINUE;
                END IF;

                IF l_alias IS NULL THEN
                    l_table_qual := l_col;
                ELSE
                    l_table_qual := RTRIM(l_alias, '.') || '.' || l_col;
                END IF;

                -- Dedupe by (function, table.column) — one finding per pair
                l_dedupe_key := 'FN:' || l_fns(i) || ':' || UPPER(l_table_qual);
                IF mark_or_seen(l_dedupe_key) THEN
                    l_occ := l_occ + 1;
                    CONTINUE;
                END IF;

                -- HIGH when the wrapped column is a join key — wrapping a join
                -- column is materially worse than wrapping a single-table filter.
                IF NVL(LENGTH(l_join_cols), 0) > 0
                   AND INSTR('|' || l_join_cols || '|', '|' || UPPER(l_col) || '|') > 0
                THEN
                    l_severity := 'HIGH';
                ELSE
                    l_severity := 'MEDIUM';
                END IF;

                p_triggered := TRUE;
                l_emitted   := l_emitted + 1;

                -- Source-SQL window comes from the ORIGINAL query for accurate display
                l_window := extract_sql_window(p_query, l_pos + 1, 100, 360);

                l_context := 'Function ' || l_fns(i)
                          || '() wraps column ' || l_table_qual
                          || ' inside WHERE — prevents B-tree index usage'
                          || CASE WHEN l_severity = 'HIGH'
                                  THEN ' (column is a JOIN key)'
                                  ELSE '' END;

                l_fragment :=
                       '-- Offending fragment:' || CHR(10)
                    || NVL(l_window, '<unable to extract source window>') || CHR(10)
                    || CHR(10)
                    || '-- Option 1 — Function-Based Index:' || CHR(10)
                    || '--   CREATE INDEX idx_fbi ON <table> ('
                    || l_fns(i) || '(' || l_col || '));' || CHR(10)
                    || '-- Option 2 — Rewrite to leave the column bare:' || CHR(10)
                    || CASE l_fns(i)
                         WHEN 'TRUNC' THEN
                            '--   ' || l_table_qual
                            || ' >= TRUNC(:dt) AND ' || l_table_qual
                            || ' < TRUNC(:dt) + 1'
                         WHEN 'TO_DATE' THEN
                            '--   ' || l_table_qual
                            || ' = DATE ''YYYY-MM-DD''   -- pre-cast on the literal side'
                         WHEN 'NVL' THEN
                            '--   (' || l_table_qual || ' = :v OR '
                            || l_table_qual || ' IS NULL)'
                         WHEN 'UPPER' THEN
                            '--   Store column already upper-cased, OR use FBI on UPPER('
                            || l_col || ').'
                         WHEN 'DECODE' THEN
                            '--   Replace DECODE with CASE on a non-indexed expression, '
                            || 'or pre-compute the mapped value in the application.'
                         ELSE
                            '--   Move the function from the column side to the '
                            || 'literal/bind side so ' || l_table_qual
                            || ' remains usable by a B-tree index.'
                       END;

                persist_result(
                    p_query_id,
                    'FUNCTION_ON_INDEXED_COLUMN',
                    l_severity,
                    SUBSTR(l_context, 1, 4000),
                    NULL,
                    l_fragment
                );

                l_occ := l_occ + 1;
                EXIT WHEN l_occ > 30;
            END LOOP;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_function_on_column;

    -- ========================================================================
    -- RULE 5: Subquery → JOIN Candidate (PER-OCCURRENCE)
    --   For every subquery pattern hit (IN, NOT IN, EXISTS, NOT EXISTS,
    --   <op> (SELECT ...)) we emit a separate row with:
    --     - context_info     : "<KIND> subquery — <one-line summary>"
    --     - optimized_fragment: the actual subquery body extracted from source
    --                          + a tailored rewrite skeleton.
    --   Capped at c_max_emit hits.
    -- ========================================================================
    PROCEDURE rule_subquery_to_join (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_upper       VARCHAR2(32767);
        l_kind        VARCHAR2(40);
        l_pattern     VARCHAR2(80);
        l_open_pos    PLS_INTEGER;
        l_anchor_pos  PLS_INTEGER;
        l_body        VARCHAR2(2000);
        l_window      VARCHAR2(500);
        l_inner       VARCHAR2(120);  -- summary: "FROM table_name"
        l_context     VARCHAR2(2000);
        l_fragment    CLOB;
        l_emitted     PLS_INTEGER := 0;
        l_occ         PLS_INTEGER;
        c_max_emit CONSTANT PLS_INTEGER := 8;

        TYPE t_pat IS RECORD (kind VARCHAR2(40), regex VARCHAR2(120));
        TYPE t_pat_tab IS TABLE OF t_pat;
        l_pats t_pat_tab := t_pat_tab();
    BEGIN
        p_triggered := FALSE;
        l_upper     := UPPER(strip_comments(DBMS_LOB.SUBSTR(p_query, 32767, 1)));

        l_pats.EXTEND(5);
        l_pats(1).kind := 'NOT IN(SELECT)';   l_pats(1).regex := 'NOT\s+IN\s*\(\s*SELECT';
        l_pats(2).kind := 'NOT EXISTS';       l_pats(2).regex := 'NOT\s+EXISTS\s*\(\s*SELECT';
        l_pats(3).kind := 'IN(SELECT)';       l_pats(3).regex := '(?<!NOT\s)IN\s*\(\s*SELECT';
        l_pats(4).kind := 'EXISTS(SELECT)';   l_pats(4).regex := '(?<!NOT\s)EXISTS\s*\(\s*SELECT';
        l_pats(5).kind := 'SCALAR (=...SELECT)'; l_pats(5).regex := '=\s*\(\s*SELECT';

        FOR p IN 1 .. l_pats.COUNT LOOP
            EXIT WHEN l_emitted >= c_max_emit;
            l_occ := 1;
            LOOP
                EXIT WHEN l_emitted >= c_max_emit;

                -- Note: Oracle regex doesn't support look-behind, so for the
                -- "no preceding NOT" patterns we emulate by scanning then
                -- checking the prior chars manually.
                l_kind    := l_pats(p).kind;
                l_pattern := REPLACE(l_pats(p).regex, '(?<!NOT\s)', '');

                l_anchor_pos := REGEXP_INSTR(l_upper, l_pattern, 1, l_occ, 0, 'i');
                EXIT WHEN l_anchor_pos = 0 OR l_anchor_pos IS NULL;

                -- For IN(SELECT) / EXISTS(SELECT) variants, exclude cases
                -- where the prior token is NOT (those are already handled).
                IF l_pats(p).regex LIKE '(?<!NOT%' THEN
                    DECLARE l_lookback VARCHAR2(10);
                    BEGIN
                        l_lookback := UPPER(SUBSTR(l_upper,
                                            GREATEST(1, l_anchor_pos - 4), 4));
                        IF l_lookback LIKE '%NOT %' OR l_lookback LIKE '%NOT' THEN
                            l_occ := l_occ + 1;
                            CONTINUE;
                        END IF;
                    END;
                END IF;

                -- Find the opening paren that follows the keyword
                l_open_pos := INSTR(l_upper, '(', l_anchor_pos);
                EXIT WHEN l_open_pos = 0;

                l_body   := extract_subquery_body(p_query, l_open_pos, 1500);
                l_window := extract_sql_window  (p_query, l_anchor_pos, 80, 240);

                IF l_body IS NULL THEN
                    l_occ := l_occ + 1;
                    CONTINUE;
                END IF;

                -- One-line summary: pull "FROM <ident>" out of the body
                l_inner := REGEXP_SUBSTR(UPPER(l_body),
                              'FROM\s+([A-Z][A-Z0-9_$#]*)', 1, 1, 'i', 0);

                p_triggered := TRUE;
                l_emitted   := l_emitted + 1;

                l_context := l_kind || ' subquery'
                          || CASE WHEN l_inner IS NOT NULL
                                  THEN ' over ' || TRIM(l_inner) ELSE '' END
                          || CASE WHEN l_window IS NOT NULL
                                  THEN ' — at: ' || SUBSTR(l_window, 1, 200)
                                  ELSE '' END;

                l_fragment :=
                       '-- Offending subquery body:' || CHR(10)
                    || '(' || CHR(10) || l_body || CHR(10) || ')' || CHR(10)
                    || CHR(10)
                    || CASE l_kind
                         WHEN 'IN(SELECT)' THEN
                              '-- Rewrite as INNER JOIN:' || CHR(10)
                           || '-- FROM outer_table o' || CHR(10)
                           || '-- INNER JOIN ( ' || CHR(10)
                           || REGEXP_REPLACE(l_body, '^', '   ', 1, 0, 'm')
                           || CHR(10)
                           || '-- ) sub ON o.<key> = sub.<key>'
                         WHEN 'NOT IN(SELECT)' THEN
                              '-- Rewrite as anti-join (handles NULLs better than NOT IN):'
                           || CHR(10)
                           || '-- FROM outer_table o' || CHR(10)
                           || '-- LEFT JOIN ( ' || CHR(10)
                           || REGEXP_REPLACE(l_body, '^', '   ', 1, 0, 'm')
                           || CHR(10)
                           || '-- ) sub ON o.<key> = sub.<key>' || CHR(10)
                           || '-- WHERE sub.<key> IS NULL'
                         WHEN 'EXISTS(SELECT)' THEN
                              '-- Often equivalent to a semi-join:' || CHR(10)
                           || '-- FROM outer_table o' || CHR(10)
                           || '-- WHERE EXISTS is fine when correlated; if uncorrelated,'
                           || CHR(10)
                           || '-- rewrite as INNER JOIN with DISTINCT-by-key as needed.'
                         WHEN 'NOT EXISTS' THEN
                              '-- Anti-join rewrite (often the same plan as NOT EXISTS):'
                           || CHR(10)
                           || '-- LEFT JOIN ... ON ... WHERE <other>.<key> IS NULL'
                         WHEN 'SCALAR (=...SELECT)' THEN
                              '-- Scalar subqueries execute once per outer row when'
                           || CHR(10)
                           || '-- correlated. Consider window function instead, e.g.'
                           || CHR(10)
                           || '-- MAX(col) OVER (PARTITION BY <key>) in a CTE.'
                         ELSE
                              '-- Rewrite as explicit JOIN where possible.'
                       END;

                persist_result(
                    p_query_id,
                    'SUBQUERY_CANDIDATE_FOR_JOIN',
                    'MEDIUM',
                    SUBSTR(l_context, 1, 4000),
                    NULL,
                    l_fragment
                );

                l_occ := l_occ + 1;
                EXIT WHEN l_occ > 30;
            END LOOP;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_subquery_to_join;

    -- ========================================================================
    -- RULE 6: Unnecessary DISTINCT (PRECISION REWRITE)
    --   Three cases now handled with distinct severity:
    --     1) DISTINCT coexists with GROUP BY in the same statement.
    --        Every GROUP BY group is unique by definition, so DISTINCT does
    --        an extra sort/hash that produces zero new rows.  -> MEDIUM
    --     2) DISTINCT over joins where every join key is PK/UK.
    --        Result already unique, DISTINCT is wasted work.   -> LOW
    --     3) DISTINCT with non-unique joins.
    --        DISTINCT may be masking a real duplicate problem. -> LOW
    -- ========================================================================
    PROCEDURE rule_unnecessary_distinct (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_full_upper      VARCHAR2(32767);
        l_tables          VARCHAR2(4000);
        l_joins           VARCHAR2(4000);
        l_all_unique      BOOLEAN := TRUE;
        l_has_joins       BOOLEAN := FALSE;
        l_has_groupby     BOOLEAN := FALSE;
        l_t_rest          VARCHAR2(4000);
        l_c_rest          VARCHAR2(4000);
        l_tbl             VARCHAR2(200);
        l_col             VARCHAR2(200);
        l_unique_cnt      NUMBER;
        l_total_cnt       NUMBER  := 0;
        l_unique_hits     NUMBER  := 0;
        l_verdict         VARCHAR2(2000);
        l_severity        VARCHAR2(10) := 'LOW';
        l_t_pipe          PLS_INTEGER;
        l_c_pipe          PLS_INTEGER;
        l_distinct_pos    PLS_INTEGER;
        l_groupby_pos     PLS_INTEGER;
    BEGIN
        p_triggered := FALSE;
        l_full_upper := UPPER(strip_comments(DBMS_LOB.SUBSTR(p_query, 32767, 1)));

        l_distinct_pos := REGEXP_INSTR(l_full_upper, '(^|\W)SELECT\s+DISTINCT(\W|$)',
                                       1, 1, 0, 'i');
        IF l_distinct_pos = 0 OR l_distinct_pos IS NULL THEN RETURN; END IF;

        p_triggered := TRUE;

        -- Detect coexistence of GROUP BY at any level following DISTINCT
        l_groupby_pos := REGEXP_INSTR(l_full_upper, '(^|\W)GROUP\s+BY(\W|$)',
                                      l_distinct_pos, 1, 0, 'i');
        IF l_groupby_pos > l_distinct_pos THEN
            l_has_groupby := TRUE;
        END IF;

        l_tables := extract_tables(p_query);
        l_joins  := extract_join_columns(p_query);

        IF LENGTH(NVL(l_joins, '')) > 0 THEN
            l_has_joins := TRUE;

            l_t_rest := l_tables;
            WHILE LENGTH(NVL(l_t_rest, '')) > 0 LOOP
                l_t_pipe := INSTR(l_t_rest, '|');
                IF l_t_pipe > 0 THEN
                    l_tbl    := SUBSTR(l_t_rest, 1, l_t_pipe - 1);
                    l_t_rest := SUBSTR(l_t_rest, l_t_pipe + 1);
                ELSE
                    l_tbl    := l_t_rest;
                    l_t_rest := '';
                END IF;

                l_c_rest := l_joins;
                WHILE LENGTH(NVL(l_c_rest, '')) > 0 LOOP
                    l_c_pipe := INSTR(l_c_rest, '|');
                    IF l_c_pipe > 0 THEN
                        l_col    := SUBSTR(l_c_rest, 1, l_c_pipe - 1);
                        l_c_rest := SUBSTR(l_c_rest, l_c_pipe + 1);
                    ELSE
                        l_col    := l_c_rest;
                        l_c_rest := '';
                    END IF;

                    IF column_exists_on_table(l_tbl, l_col) THEN
                        l_total_cnt := l_total_cnt + 1;
                        BEGIN
                            SELECT COUNT(*) INTO l_unique_cnt
                            FROM   all_constraints c
                            JOIN   all_cons_columns cc
                              ON   cc.constraint_name = c.constraint_name
                              AND  cc.owner           = c.owner
                            WHERE  c.table_name      = l_tbl
                              AND  cc.column_name    = l_col
                              AND  c.constraint_type IN ('P','U');
                            IF l_unique_cnt > 0 THEN
                                l_unique_hits := l_unique_hits + 1;
                            ELSE
                                l_all_unique := FALSE;
                            END IF;
                        EXCEPTION
                            WHEN OTHERS THEN l_all_unique := FALSE;
                        END;
                    END IF;
                END LOOP;
            END LOOP;
        END IF;

        IF l_has_groupby THEN
            l_severity := 'MEDIUM';
            l_verdict  := 'DISTINCT is REDUNDANT after GROUP BY — every group is '
                       || 'already unique. Remove DISTINCT to skip the extra sort/hash.';
        ELSIF l_has_joins AND l_total_cnt > 0 AND l_all_unique THEN
            l_severity := 'LOW';
            l_verdict  := 'DISTINCT is likely UNNECESSARY — all '
                       || l_total_cnt || ' join key(s) reference PK/UK columns ('
                       || l_unique_hits || '/' || l_total_cnt || ' verified)';
        ELSIF l_has_joins AND l_total_cnt > 0 THEN
            l_severity := 'LOW';
            l_verdict  := 'DISTINCT may be MASKING duplicates — '
                       || (l_total_cnt - l_unique_hits)
                       || ' of ' || l_total_cnt
                       || ' join key(s) are not PK/UK columns. Investigate the join.';
        ELSE
            l_severity := 'LOW';
            l_verdict  := 'DISTINCT detected — verify the deduplicate step is required';
        END IF;

        persist_result(
            p_query_id,
            'UNNECESSARY_DISTINCT',
            l_severity,
            l_verdict,
            NULL,
            CASE WHEN l_has_groupby THEN
                '-- GROUP BY already produces one row per group.' || CHR(10)
             || '-- DISTINCT after GROUP BY adds a second sort/hash for zero benefit.' || CHR(10)
             || '-- Remove DISTINCT and re-run EXPLAIN PLAN to confirm a cheaper plan.'
            ELSE
                '-- If all join conditions hit PK/UK columns, remove DISTINCT.' || CHR(10)
             || '-- Otherwise, find the join producing duplicates and fix the join condition.'
            END
        );
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_unnecessary_distinct;

    -- ========================================================================
    -- RULE 7: Cartesian Join (unchanged)
    -- ========================================================================
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
        l_cnt         NUMBER;
    BEGIN
        p_triggered := FALSE;
        l_upper     := UPPER(strip_comments(DBMS_LOB.SUBSTR(p_query, 32767, 1)));

        BEGIN
            SELECT COUNT(*) INTO l_cnt
            FROM   plan_table
            WHERE  statement_id = p_stmt_id
              AND  options LIKE '%CARTESIAN%';
            IF l_cnt > 0 THEN l_found := TRUE; END IF;
        EXCEPTION
            WHEN OTHERS THEN NULL;
        END;

        IF NOT l_found THEN
            l_from_start := INSTR(l_upper, ' FROM ');
            IF l_from_start > 0 THEN
                l_from_end := LEAST(
                    CASE WHEN INSTR(l_upper, ' WHERE ', l_from_start) > 0
                         THEN INSTR(l_upper, ' WHERE ', l_from_start) ELSE 99999 END,
                    CASE WHEN INSTR(l_upper, ' JOIN ',  l_from_start) > 0
                         THEN INSTR(l_upper, ' JOIN ',  l_from_start) ELSE 99999 END,
                    CASE WHEN INSTR(l_upper, ' ORDER ', l_from_start) > 0
                         THEN INSTR(l_upper, ' ORDER ', l_from_start) ELSE 99999 END
                );
                IF l_from_end = 99999 THEN l_from_end := LENGTH(l_upper); END IF;
                l_from_str  := SUBSTR(l_upper, l_from_start + 6, l_from_end - l_from_start - 6);
                l_comma_cnt := LENGTH(l_from_str) - LENGTH(REPLACE(l_from_str, ',', ''));

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
                'Cartesian product detected — missing or incomplete join conditions',
                NULL,
                '-- Add explicit ON/USING for every table pair.' || CHR(10)
             || '-- Prefer ANSI: FROM t1 INNER JOIN t2 ON t1.id = t2.ref_id' || CHR(10)
             || '-- Use CROSS JOIN keyword only when a Cartesian is intentional.'
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_cartesian_join;

    -- ========================================================================
    -- RULE 8 (NEW): Table Context Summary
    --   Always-on. Fires once per query but emits ONE QUERY_RULE_RESULTS row
    --   per referenced table, packed with size + indexes + PK + columns info.
    -- ========================================================================
    PROCEDURE rule_table_context_summary (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_tables   VARCHAR2(4000);
        l_t_rest   VARCHAR2(4000);
        l_tbl      VARCHAR2(200);
        l_t_pipe   PLS_INTEGER;
        l_summary  CLOB;
        l_rows     NUMBER;
        l_blocks   NUMBER;
        l_avg_row  NUMBER;
        l_ctx      VARCHAR2(4000);
    BEGIN
        p_triggered := FALSE;
        l_tables    := extract_tables(p_query);
        IF LENGTH(NVL(l_tables, '')) = 0 THEN RETURN; END IF;

        l_t_rest := l_tables;
        WHILE LENGTH(NVL(l_t_rest, '')) > 0 LOOP
            l_t_pipe := INSTR(l_t_rest, '|');
            IF l_t_pipe > 0 THEN
                l_tbl    := SUBSTR(l_t_rest, 1, l_t_pipe - 1);
                l_t_rest := SUBSTR(l_t_rest, l_t_pipe + 1);
            ELSE
                l_tbl    := l_t_rest;
                l_t_rest := '';
            END IF;

            -- Confirm table is visible to current user (any schema)
            DECLARE l_exists NUMBER;
            BEGIN
                SELECT COUNT(*) INTO l_exists
                FROM   all_tables WHERE table_name = l_tbl;
                IF l_exists = 0 THEN CONTINUE; END IF;
            EXCEPTION
                WHEN OTHERS THEN CONTINUE;
            END;

            p_triggered := TRUE;
            get_table_metrics(l_tbl, l_rows, l_blocks, l_avg_row);

            l_ctx := l_tbl
                  || ': rows=' || NVL(TO_CHAR(l_rows, 'FM999G999G999'), '<no stats>')
                  || ', blocks=' || NVL(TO_CHAR(l_blocks), '<no stats>')
                  || ', avg_row_len=' || NVL(TO_CHAR(l_avg_row), '<no stats>');

            l_summary := build_table_summary(l_tbl);

            persist_result(
                p_query_id,
                'TABLE_CONTEXT_SUMMARY',
                'LOW',
                SUBSTR(l_ctx, 1, 4000),
                NULL,
                l_summary
            );

            IF l_summary IS NOT NULL AND DBMS_LOB.ISTEMPORARY(l_summary) = 1 THEN
                DBMS_LOB.FREETEMPORARY(l_summary);
            END IF;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_table_context_summary;

    -- ========================================================================
    -- RULE 9 (NEW): Aggregate / Sort on Unindexed Column
    --   Detects GROUP BY / ORDER BY columns that are not the leading column
    --   of any index on the relevant tables.
    -- ========================================================================
    PROCEDURE rule_aggregate_index_hint (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_tables  VARCHAR2(4000);
        l_cols    VARCHAR2(4000);
        l_t_rest  VARCHAR2(4000);
        l_c_rest  VARCHAR2(4000);
        l_tbl     VARCHAR2(200);
        l_col     VARCHAR2(200);
        l_t_pipe  PLS_INTEGER;
        l_c_pipe  PLS_INTEGER;
        l_context VARCHAR2(4000) := '';
        l_ddl     CLOB           := '';
    BEGIN
        p_triggered := FALSE;
        l_tables    := extract_tables(p_query);
        l_cols      := extract_groupby_orderby(p_query);

        IF LENGTH(NVL(l_tables, '')) = 0 OR LENGTH(NVL(l_cols, '')) = 0 THEN RETURN; END IF;

        l_t_rest := l_tables;
        WHILE LENGTH(NVL(l_t_rest, '')) > 0 LOOP
            l_t_pipe := INSTR(l_t_rest, '|');
            IF l_t_pipe > 0 THEN
                l_tbl    := SUBSTR(l_t_rest, 1, l_t_pipe - 1);
                l_t_rest := SUBSTR(l_t_rest, l_t_pipe + 1);
            ELSE
                l_tbl    := l_t_rest;
                l_t_rest := '';
            END IF;

            l_c_rest := l_cols;
            WHILE LENGTH(NVL(l_c_rest, '')) > 0 LOOP
                l_c_pipe := INSTR(l_c_rest, '|');
                IF l_c_pipe > 0 THEN
                    l_col    := SUBSTR(l_c_rest, 1, l_c_pipe - 1);
                    l_c_rest := SUBSTR(l_c_rest, l_c_pipe + 1);
                ELSE
                    l_col    := l_c_rest;
                    l_c_rest := '';
                END IF;

                IF column_exists_on_table(l_tbl, l_col)
                   AND NOT is_column_indexed(l_tbl, l_col) THEN
                    p_triggered := TRUE;
                    l_context := l_context
                              || l_tbl || '.' || l_col || ' (group/order, unindexed); ';
                    l_ddl     := l_ddl
                              || 'CREATE INDEX idx_' || LOWER(l_tbl) || '_' || LOWER(l_col)
                              || '_sort ON ' || l_tbl || ' (' || l_col || ');' || CHR(10);
                END IF;
                EXIT WHEN LENGTH(l_context) > 3800;
            END LOOP;
            EXIT WHEN LENGTH(l_context) > 3800;
        END LOOP;

        IF p_triggered THEN
            persist_result(
                p_query_id,
                'AGGREGATE_INDEX_HINT',
                'MEDIUM',
                'GROUP BY / ORDER BY columns lack a leading index entry: '
                  || SUBSTR(l_context, 1, 3800),
                l_ddl,
                NULL
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_aggregate_index_hint;

    -- ========================================================================
    -- RULE 10 (NEW): High Plan Cost
    --   Reads PLAN_TABLE.cost for the root row (id=0) and fires when above
    --   threshold (default 1000).
    -- ========================================================================
    PROCEDURE rule_high_cost_plan (
        p_stmt_id   IN  VARCHAR2,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        c_threshold CONSTANT NUMBER := 1000;
        l_cost      NUMBER;
        l_rows      NUMBER;
        l_top_op    VARCHAR2(80);
        l_top_obj   VARCHAR2(80);
    BEGIN
        p_triggered := FALSE;
        IF p_stmt_id IS NULL THEN RETURN; END IF;

        BEGIN
            SELECT cost, cardinality
            INTO   l_cost, l_rows
            FROM   plan_table
            WHERE  statement_id = p_stmt_id
              AND  id = 0;
        EXCEPTION
            WHEN NO_DATA_FOUND THEN RETURN;
        END;

        IF l_cost IS NULL OR l_cost < c_threshold THEN RETURN; END IF;

        BEGIN
            SELECT operation || ' ' || NVL(options, ''), object_name
            INTO   l_top_op, l_top_obj
            FROM   (
                SELECT operation, options, object_name, cost
                FROM   plan_table
                WHERE  statement_id = p_stmt_id
                  AND  id > 0
                ORDER  BY cost DESC NULLS LAST
            )
            WHERE  ROWNUM = 1;
        EXCEPTION
            WHEN OTHERS THEN l_top_op := NULL; l_top_obj := NULL;
        END;

        p_triggered := TRUE;
        persist_result(
            p_query_id,
            'HIGH_COST_PLAN',
            'HIGH',
            'Plan cost ' || l_cost || ' exceeds threshold (' || c_threshold || '). '
              || 'Estimated output rows: ' || NVL(TO_CHAR(l_rows), '?')
              || CASE WHEN l_top_op IS NOT NULL THEN
                    '. Highest-cost step: ' || l_top_op || ' '
                    || NVL(l_top_obj, '<unknown>')
                 ELSE '' END,
            NULL,
            '-- Inspect the plan top-down. Common high-cost causes:' || CHR(10)
         || '--   * full table scans on large tables' || CHR(10)
         || '--   * large hash joins or sort operations' || CHR(10)
         || '--   * stale statistics (try DBMS_STATS.GATHER_TABLE_STATS)' || CHR(10)
         || '--   * missing index on selective WHERE predicate'
        );
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_high_cost_plan;

    -- ========================================================================
    -- RULE 11 (NEW): Implicit Type Conversion
    --   Reads PLAN_TABLE.FILTER_PREDICATES and ACCESS_PREDICATES for the
    --   markers Oracle injects when it must coerce datatypes silently:
    --     INTERNAL_FUNCTION(col)  -> generic implicit conversion
    --     SYS_OP_C2C(col)         -> NCHAR/NVARCHAR2 to CHAR/VARCHAR2
    --   Both disable index access on the wrapped column AND make the result
    --   NLS-dependent.  Severity HIGH because consequences are correctness +
    --   performance, not just performance.
    -- ========================================================================
    PROCEDURE rule_implicit_type_conversion (
        p_stmt_id   IN  VARCHAR2,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_count      PLS_INTEGER := 0;
        l_dedupe_key VARCHAR2(400);
    BEGIN
        p_triggered := FALSE;
        IF p_stmt_id IS NULL THEN RETURN; END IF;

        FOR rec IN (
            SELECT object_name,
                   filter_predicates AS pred_text,
                   'FILTER'          AS pred_kind
            FROM   plan_table
            WHERE  statement_id = p_stmt_id
              AND  filter_predicates IS NOT NULL
              AND  (UPPER(filter_predicates) LIKE '%INTERNAL_FUNCTION(%'
                    OR UPPER(filter_predicates) LIKE '%SYS_OP_C2C(%')
            UNION ALL
            SELECT object_name,
                   access_predicates AS pred_text,
                   'ACCESS'          AS pred_kind
            FROM   plan_table
            WHERE  statement_id = p_stmt_id
              AND  access_predicates IS NOT NULL
              AND  (UPPER(access_predicates) LIKE '%INTERNAL_FUNCTION(%'
                    OR UPPER(access_predicates) LIKE '%SYS_OP_C2C(%')
        ) LOOP
            EXIT WHEN l_count >= 8;
            l_dedupe_key := 'ITC:' || NVL(rec.object_name, '?') || ':'
                         || SUBSTR(rec.pred_text, 1, 200);
            IF NOT mark_or_seen(l_dedupe_key) THEN
                p_triggered := TRUE;
                l_count := l_count + 1;
                persist_result(
                    p_query_id,
                    'IMPLICIT_TYPE_CONVERSION',
                    'HIGH',
                    'Implicit datatype conversion in ' || rec.pred_kind
                      || ' predicate on ' || NVL(rec.object_name, '<unknown>')
                      || ' — predicate: ' || SUBSTR(rec.pred_text, 1, 800),
                    NULL,
                    '-- Predicate from execution plan:' || CHR(10)
                 || '-- ' || SUBSTR(rec.pred_text, 1, 1500) || CHR(10)
                 || CHR(10)
                 || '-- Oracle injected INTERNAL_FUNCTION() / SYS_OP_C2C() because the' || CHR(10)
                 || '-- literal datatype does not match the column. Fix the literal:' || CHR(10)
                 || '--   DATE column   :  TO_DATE(''2020-02-07'',''YYYY-MM-DD'')' || CHR(10)
                 || '--                    or DATE ''2020-02-07''' || CHR(10)
                 || '--   NUMBER column :  drop the quotes — branch_code = 114, not ''114''' || CHR(10)
                 || '--   NCHAR/CHAR    :  use the same type on both sides.' || CHR(10)
                 || '-- After fixing the type, the optimizer can use the index on this column.'
                );
            END IF;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_implicit_type_conversion;

    -- ========================================================================
    -- RULE 12 (NEW): Literal Instead of Bind
    --   Scans WHERE-only text (after SELECT-projection masking) for predicates
    --   of the form  <col> = '<literal>'  or  <col> = <number_literal>.
    --   Fires only when the column has at least one index — literals on
    --   non-indexed filters do not affect cursor sharing in any meaningful way.
    -- ========================================================================
    PROCEDURE rule_literal_instead_of_bind (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_masked     VARCHAR2(32767);
        l_upper      VARCHAR2(32767);
        l_tables     VARCHAR2(4000);
        l_where_pos  PLS_INTEGER;
        l_where_str  VARCHAR2(32767);
        l_match      VARCHAR2(400);
        l_alias      VARCHAR2(50);
        l_col        VARCHAR2(100);
        l_literal    VARCHAR2(200);
        l_full_col   VARCHAR2(160);
        l_occ        PLS_INTEGER;
        l_emitted    PLS_INTEGER := 0;
        l_dedupe_key VARCHAR2(400);
        l_t_rest     VARCHAR2(4000);
        l_t_pipe     PLS_INTEGER;
        l_tbl        VARCHAR2(200);
        l_indexed_on VARCHAR2(200);
        l_context    VARCHAR2(2000);
        c_max_emit   CONSTANT PLS_INTEGER := 6;
        c_pat        CONSTANT VARCHAR2(200) :=
            '([A-Z][A-Z0-9_]*\.)?([A-Z][A-Z0-9_$#]*)\s*=\s*(''[^'']*''|-?\d+(\.\d+)?)';
    BEGIN
        p_triggered := FALSE;
        l_masked := mask_select_projections(p_query);
        IF l_masked IS NULL THEN RETURN; END IF;
        l_upper := UPPER(l_masked);

        l_where_pos := INSTR(l_upper, ' WHERE ');
        IF l_where_pos = 0 THEN RETURN; END IF;
        l_where_str := SUBSTR(l_upper, l_where_pos);
        l_tables    := extract_tables(p_query);
        IF NVL(LENGTH(l_tables), 0) = 0 THEN RETURN; END IF;

        l_occ := 1;
        LOOP
            EXIT WHEN l_emitted >= c_max_emit;
            l_match := REGEXP_SUBSTR(l_where_str, c_pat, 1, l_occ, 'i', 0);
            EXIT WHEN l_match IS NULL;

            l_alias   := REGEXP_SUBSTR(l_match, c_pat, 1, 1, 'i', 1);
            l_col     := REGEXP_SUBSTR(l_match, c_pat, 1, 1, 'i', 2);
            l_literal := REGEXP_SUBSTR(l_match, c_pat, 1, 1, 'i', 3);

            IF is_sql_function(l_col) THEN
                l_occ := l_occ + 1;
                CONTINUE;
            END IF;

            IF l_alias IS NULL THEN
                l_full_col := l_col;
            ELSE
                l_full_col := RTRIM(l_alias, '.') || '.' || l_col;
            END IF;

            -- Check the column is indexed somewhere
            l_indexed_on := NULL;
            l_t_rest := l_tables;
            WHILE NVL(LENGTH(l_t_rest), 0) > 0 LOOP
                l_t_pipe := INSTR(l_t_rest, '|');
                IF l_t_pipe > 0 THEN
                    l_tbl    := SUBSTR(l_t_rest, 1, l_t_pipe - 1);
                    l_t_rest := SUBSTR(l_t_rest, l_t_pipe + 1);
                ELSE
                    l_tbl    := l_t_rest;
                    l_t_rest := '';
                END IF;
                IF column_exists_on_table(l_tbl, l_col)
                   AND is_column_indexed(l_tbl, l_col) THEN
                    l_indexed_on := l_tbl;
                    EXIT;
                END IF;
            END LOOP;

            IF l_indexed_on IS NULL THEN
                l_occ := l_occ + 1;
                CONTINUE;
            END IF;

            l_dedupe_key := 'BIND:' || UPPER(l_full_col) || ':' || l_literal;
            IF mark_or_seen(l_dedupe_key) THEN
                l_occ := l_occ + 1;
                CONTINUE;
            END IF;

            p_triggered := TRUE;
            l_emitted   := l_emitted + 1;

            l_context := 'Indexed column ' || l_full_col
                      || ' (on ' || l_indexed_on || ') compared to literal '
                      || l_literal
                      || ' — use a bind variable for cursor sharing';

            persist_result(
                p_query_id,
                'LITERAL_INSTEAD_OF_BIND',
                'LOW',
                SUBSTR(l_context, 1, 4000),
                NULL,
                '-- Original predicate:' || CHR(10)
             || '--   ' || l_full_col || ' = ' || l_literal || CHR(10)
             || CHR(10)
             || '-- Replace with a bind variable:' || CHR(10)
             || '--   ' || l_full_col || ' = :v' || CHR(10)
             || CHR(10)
             || '-- Then in application code:' || CHR(10)
             || '--   EXECUTE IMMEDIATE ''<sql>'' USING ' || l_literal || ';' || CHR(10)
             || '-- Each distinct literal forces a hard parse and pollutes the cursor cache.'
            );
            l_occ := l_occ + 1;
            EXIT WHEN l_occ > 50;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_literal_instead_of_bind;

    -- ========================================================================
    -- RULE 13 (NEW): Stale Statistics
    --   For every table referenced, reads ALL_TABLES.LAST_ANALYZED.
    --   Fires when LAST_ANALYZED is NULL (never gathered) or older than
    --   c_threshold_days days.  Generates DBMS_STATS.GATHER_TABLE_STATS DDL.
    -- ========================================================================
    PROCEDURE rule_stale_statistics (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        c_threshold_days CONSTANT NUMBER := 30;
        l_tables    VARCHAR2(4000);
        l_t_rest    VARCHAR2(4000);
        l_tbl       VARCHAR2(200);
        l_t_pipe    PLS_INTEGER;
        l_last_an   DATE;
        l_owner     VARCHAR2(60);
        l_age_days  NUMBER;
        l_context   VARCHAR2(4000) := '';
        l_count     PLS_INTEGER    := 0;
        l_ddl       CLOB           := '';
    BEGIN
        p_triggered := FALSE;
        l_tables    := extract_tables(p_query);
        IF NVL(LENGTH(l_tables), 0) = 0 THEN RETURN; END IF;

        l_t_rest := l_tables;
        WHILE NVL(LENGTH(l_t_rest), 0) > 0 LOOP
            l_t_pipe := INSTR(l_t_rest, '|');
            IF l_t_pipe > 0 THEN
                l_tbl    := SUBSTR(l_t_rest, 1, l_t_pipe - 1);
                l_t_rest := SUBSTR(l_t_rest, l_t_pipe + 1);
            ELSE
                l_tbl    := l_t_rest;
                l_t_rest := '';
            END IF;

            l_last_an := NULL; l_owner := NULL;
            BEGIN
                SELECT owner, last_analyzed
                INTO   l_owner, l_last_an
                FROM   (
                    SELECT owner, last_analyzed
                    FROM   all_tables
                    WHERE  table_name = l_tbl
                    ORDER  BY NVL(last_analyzed, DATE '1900-01-01') DESC
                )
                WHERE ROWNUM = 1;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN CONTINUE;
                WHEN OTHERS        THEN CONTINUE;
            END;

            IF l_last_an IS NULL THEN
                l_count   := l_count + 1;
                l_context := l_context || l_tbl || ' (NO STATS); ';
                l_ddl := l_ddl
                      || 'EXEC DBMS_STATS.GATHER_TABLE_STATS('''
                      || l_owner || ''','''|| l_tbl || ''', cascade=>TRUE);'
                      || CHR(10);
            ELSE
                l_age_days := SYSDATE - l_last_an;
                IF l_age_days > c_threshold_days THEN
                    l_count   := l_count + 1;
                    l_context := l_context || l_tbl
                              || ' (' || ROUND(l_age_days) || ' days old); ';
                    l_ddl := l_ddl
                          || 'EXEC DBMS_STATS.GATHER_TABLE_STATS('''
                          || l_owner || ''','''|| l_tbl || ''', cascade=>TRUE);'
                          || CHR(10);
                END IF;
            END IF;

            EXIT WHEN LENGTH(l_context) > 3500;
        END LOOP;

        IF l_count > 0 THEN
            p_triggered := TRUE;
            persist_result(
                p_query_id,
                'STALE_STATISTICS',
                'MEDIUM',
                l_count || ' table(s) have stale or missing statistics: '
                  || SUBSTR(l_context, 1, 3800),
                l_ddl,
                '-- Refresh statistics on each listed table. The optimizer makes' || CHR(10)
             || '-- cardinality estimates from these stats; stale data drives' || CHR(10)
             || '-- wrong join order, wrong access path, and wrong join method.' || CHR(10)
             || '-- For high-churn tables enable INCREMENTAL stats to avoid' || CHR(10)
             || '-- full-table gathers on partition-level changes:' || CHR(10)
             || '--   EXEC DBMS_STATS.SET_TABLE_PREFS(USER,''<tbl>'',''INCREMENTAL'',''TRUE'');'
            );
        END IF;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_stale_statistics;

    -- ========================================================================
    -- RULE 14 (NEW): LIKE with Leading Wildcard
    --   Scans WHERE-only text for predicates of the form
    --     <col> LIKE '%<rest>'
    --   The leading % disables B-tree access on <col>.  Severity HIGH because
    --   the alternative on a large table is a full scan even when the column
    --   is indexed.
    -- ========================================================================
    PROCEDURE rule_like_leading_wildcard (
        p_query     IN  CLOB,
        p_query_id  IN  NUMBER,
        p_triggered OUT BOOLEAN
    ) IS
        l_masked     VARCHAR2(32767);
        l_upper      VARCHAR2(32767);
        l_where_pos  PLS_INTEGER;
        l_where_str  VARCHAR2(32767);
        l_match      VARCHAR2(400);
        l_alias      VARCHAR2(50);
        l_col        VARCHAR2(100);
        l_pattern    VARCHAR2(400);
        l_full_col   VARCHAR2(160);
        l_window     VARCHAR2(500);
        l_pos        PLS_INTEGER;
        l_occ        PLS_INTEGER;
        l_emitted    PLS_INTEGER := 0;
        l_dedupe_key VARCHAR2(400);
        c_max_emit   CONSTANT PLS_INTEGER := 6;
        c_pat        CONSTANT VARCHAR2(200) :=
            '([A-Z][A-Z0-9_]*\.)?([A-Z][A-Z0-9_$#]*)\s+LIKE\s+''(%[^'']*)''';
    BEGIN
        p_triggered := FALSE;
        l_masked := mask_select_projections(p_query);
        IF l_masked IS NULL THEN RETURN; END IF;
        l_upper := UPPER(l_masked);

        l_where_pos := INSTR(l_upper, ' WHERE ');
        IF l_where_pos = 0 THEN RETURN; END IF;
        l_where_str := SUBSTR(l_upper, l_where_pos);

        l_occ := 1;
        LOOP
            EXIT WHEN l_emitted >= c_max_emit;
            l_match := REGEXP_SUBSTR(l_where_str, c_pat, 1, l_occ, 'i', 0);
            EXIT WHEN l_match IS NULL;

            l_alias   := REGEXP_SUBSTR(l_match, c_pat, 1, 1, 'i', 1);
            l_col     := REGEXP_SUBSTR(l_match, c_pat, 1, 1, 'i', 2);
            l_pattern := REGEXP_SUBSTR(l_match, c_pat, 1, 1, 'i', 3);

            IF is_sql_function(l_col) THEN
                l_occ := l_occ + 1;
                CONTINUE;
            END IF;

            IF l_alias IS NULL THEN
                l_full_col := l_col;
            ELSE
                l_full_col := RTRIM(l_alias, '.') || '.' || l_col;
            END IF;

            l_dedupe_key := 'LIKE:' || UPPER(l_full_col) || ':' || l_pattern;
            IF mark_or_seen(l_dedupe_key) THEN
                l_occ := l_occ + 1;
                CONTINUE;
            END IF;

            p_triggered := TRUE;
            l_emitted   := l_emitted + 1;

            -- Locate the predicate in the ORIGINAL source for accurate windowing
            l_pos := REGEXP_INSTR(
                UPPER(DBMS_LOB.SUBSTR(p_query, 32767, 1)),
                l_col || '\s+LIKE\s+''%',
                1, 1, 0, 'i');
            IF l_pos > 0 THEN
                l_window := extract_sql_window(p_query, l_pos, 80, 240);
            ELSE
                l_window := NULL;
            END IF;

            persist_result(
                p_query_id,
                'LIKE_LEADING_WILDCARD',
                'HIGH',
                'LIKE with leading % on ' || l_full_col
                  || ' — pattern ''' || l_pattern || ''' blocks B-tree index access',
                NULL,
                '-- Offending predicate:' || CHR(10)
             || NVL(l_window, l_full_col || ' LIKE ''' || l_pattern || '''') || CHR(10)
             || CHR(10)
             || '-- Why: B-tree indexes are sorted by leading character. With the' || CHR(10)
             || '-- leading char unknown the optimizer falls back to a full scan.' || CHR(10)
             || CHR(10)
             || '-- Options:' || CHR(10)
             || '--   1) Pin the leading char if business logic allows.' || CHR(10)
             || '--   2) Substring search → Oracle Text:' || CHR(10)
             || '--      CREATE INDEX idx_text ON <tbl>(<col>)' || CHR(10)
             || '--        INDEXTYPE IS CTXSYS.CONTEXT;' || CHR(10)
             || '--      WHERE CONTAINS(<col>, ''<term>'') > 0' || CHR(10)
             || '--   3) Two-prefix case (LIKE ''1%'' OR LIKE ''2%''):' || CHR(10)
             || '--      replace with  BETWEEN ''1'' AND ''3''' || CHR(10)
             || '--      single index range scan instead of two.'
            );
            l_occ := l_occ + 1;
            EXIT WHEN l_occ > 50;
        END LOOP;
    EXCEPTION
        WHEN OTHERS THEN p_triggered := FALSE;
    END rule_like_leading_wildcard;

    -- ========================================================================
    -- PRIVATE: build_json_report (unchanged structurally)
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
                        THEN '"' || escape_json(SUBSTR(TO_CHAR(rec.optimized_fragment), 1, 3000)) || '"'
                        ELSE 'null' END || CHR(10)
                || '    }';
            l_first := FALSE;

            IF rec.index_recommendation IS NOT NULL THEN
                IF NOT l_first_idx THEN l_idx_arr := l_idx_arr || ', '; END IF;
                l_idx_arr   := l_idx_arr
                             || '"' || escape_json(SUBSTR(TO_CHAR(rec.index_recommendation), 1, 1000)) || '"';
                l_first_idx := FALSE;
            END IF;
        END LOOP;

        DECLARE
            l_header VARCHAR2(4000);
        BEGIN
            l_header :=
                '{' || CHR(10)
             || '  "status": "SUCCESS",' || CHR(10)
             || '  "version": "' || c_version || '",' || CHR(10)
             || '  "execution_time_ms": ' || ROUND(p_elapsed_ms, 2) || ',' || CHR(10)
             || '  "query_log_id": ' || NVL(TO_CHAR(p_query_id), 'null') || ',' || CHR(10)
             || '  "query": "' || escape_json(SUBSTR(TO_CHAR(p_query), 1, 500)) || '",' || CHR(10)
             || '  "rule_summary": {' || CHR(10)
             || '    "total_rules_evaluated": ' || p_rules_total || ',' || CHR(10)
             || '    "rules_triggered": '       || p_rules_hit   || ',' || CHR(10)
             || '    "high_severity": '         || NVL(l_high,   0) || ',' || CHR(10)
             || '    "medium_severity": '       || NVL(l_medium, 0) || ',' || CHR(10)
             || '    "low_severity": '          || NVL(l_low,    0) || CHR(10)
             || '  },' || CHR(10)
             || '  "triggered_rules": [' || CHR(10);

            DBMS_LOB.CREATETEMPORARY(l_json, TRUE);
            DBMS_LOB.WRITEAPPEND(l_json, LENGTH(l_header), l_header);
        END;

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
    --   14 rules: 7 enhanced + 3 deep-analysis + 4 precision rules.
    --   Plan-dependent rules (skipped when EXPLAIN PLAN fails):
    --     2  FULL_TABLE_SCAN_DETECTED
    --     7  CARTESIAN_JOIN_DETECTED
    --     10 HIGH_COST_PLAN
    --     11 IMPLICIT_TYPE_CONVERSION
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

        l_triggered   BOOLEAN;
        l_rules_total NUMBER := 14;
        l_rules_hit   NUMBER := 0;
    BEGIN
        IF p_query IS NULL OR DBMS_LOB.GETLENGTH(p_query) = 0 THEN
            p_report := build_error_response('Query input is NULL or empty');
            RETURN;
        END IF;

        l_upper := UPPER(DBMS_LOB.SUBSTR(p_query, 200, 1));
        IF l_upper NOT LIKE 'SELECT%' AND l_upper NOT LIKE 'WITH%' THEN
            p_report := build_error_response('Only SELECT queries are supported in Phase 2');
            RETURN;
        END IF;

        -- Reset per-run dedupe state so identical predicates across UNION
        -- branches / subqueries are not double-counted.
        reset_dedupe;

        IF l_query_log_id IS NULL THEN
            query_analyzer_pkg.analyze_query(p_query, l_phase1_report);
            DECLARE
                l_p1_status VARCHAR2(20);
                l_p1_err    VARCHAR2(4000);
            BEGIN
                SELECT id, status, error_message
                  INTO l_query_log_id, l_p1_status, l_p1_err
                  FROM (SELECT id, status, error_message
                          FROM query_plan_log
                         ORDER BY created_at DESC)
                 WHERE ROWNUM = 1;
                -- If Phase 1 failed (e.g. table not found, ORA-00942) the
                -- meaningful action is to return that error to the caller.
                -- Previously we silently continued; non-plan-dependent rules
                -- still fired against the raw text and the user saw a phantom
                -- "SUCCESS · 1 finding" alongside an empty execution plan.
                IF l_p1_status = 'ERROR' THEN
                    p_report := build_error_response(
                        NVL(l_p1_err, 'Phase 1 analysis failed without details'));
                    RETURN;
                END IF;
                BEGIN
                    SELECT analysis_json INTO l_plan_json
                      FROM query_plan_log WHERE id = l_query_log_id;
                EXCEPTION
                    WHEN OTHERS THEN l_plan_json := NULL;
                END;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN l_query_log_id := -1; l_plan_json := NULL;
                WHEN OTHERS         THEN l_query_log_id := -1; l_plan_json := NULL;
            END;
        END IF;

        l_stmt_id := 'RE_' || TO_CHAR(SYSTIMESTAMP, 'YYYYMMDDHH24MISSFF3');
        BEGIN
            DELETE FROM plan_table WHERE statement_id = l_stmt_id;
            EXECUTE IMMEDIATE 'EXPLAIN PLAN SET STATEMENT_ID = '''
                              || l_stmt_id || ''' FOR ' || p_query;
        EXCEPTION
            WHEN OTHERS THEN l_stmt_id := NULL;
        END;

        -- Rule 1: SELECT *
        rule_select_star(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 2: Full Table Scan (needs plan)
        IF l_stmt_id IS NOT NULL THEN
            rule_full_table_scan(l_stmt_id, l_query_log_id, l_triggered);
            IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;
        ELSE
            l_rules_total := l_rules_total - 1;
        END IF;

        -- Rule 3: Missing Indexes (filter + join keys)
        rule_missing_indexes(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 4: Function on Indexed Column (precision rewrite)
        rule_function_on_column(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 5: Subquery → JOIN
        rule_subquery_to_join(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 6: Unnecessary DISTINCT (now detects DISTINCT + GROUP BY)
        rule_unnecessary_distinct(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 7: Cartesian Join (needs plan)
        IF l_stmt_id IS NOT NULL THEN
            rule_cartesian_join(p_query, l_stmt_id, l_query_log_id, l_triggered);
            IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;
        ELSE
            l_rules_total := l_rules_total - 1;
        END IF;

        -- Rule 8: Table Context Summary
        rule_table_context_summary(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 9: Aggregate / Sort on Unindexed Column
        rule_aggregate_index_hint(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 10: High Plan Cost (needs plan)
        IF l_stmt_id IS NOT NULL THEN
            rule_high_cost_plan(l_stmt_id, l_query_log_id, l_triggered);
            IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;
        ELSE
            l_rules_total := l_rules_total - 1;
        END IF;

        -- Rule 11 (NEW): Implicit Type Conversion (needs plan)
        IF l_stmt_id IS NOT NULL THEN
            rule_implicit_type_conversion(l_stmt_id, l_query_log_id, l_triggered);
            IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;
        ELSE
            l_rules_total := l_rules_total - 1;
        END IF;

        -- Rule 12 (NEW): Literal Instead of Bind
        rule_literal_instead_of_bind(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 13 (NEW): Stale Statistics
        rule_stale_statistics(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        -- Rule 14 (NEW): LIKE with Leading Wildcard
        rule_like_leading_wildcard(p_query, l_query_log_id, l_triggered);
        IF l_triggered THEN l_rules_hit := l_rules_hit + 1; END IF;

        COMMIT;

        l_elapsed_ms := EXTRACT(SECOND FROM (SYSTIMESTAMP - l_start)) * 1000;

        p_report := build_json_report(
            p_query, l_query_log_id, l_elapsed_ms,
            l_plan_json, l_rules_total, l_rules_hit
        );

    EXCEPTION
        WHEN OTHERS THEN
            p_report := build_error_response('Unexpected error in APPLY_RULES: ' || SQLERRM);
            BEGIN ROLLBACK; EXCEPTION WHEN OTHERS THEN NULL; END;
    END apply_rules;

    -- ========================================================================
    -- GET_RULE_RESULTS (Public)
    -- ========================================================================
    PROCEDURE get_rule_results (
        p_query_id  IN  NUMBER,
        p_result    OUT SYS_REFCURSOR
    ) IS
    BEGIN
        OPEN p_result FOR
            SELECT
                qrr.result_id, qrr.query_log_id, qrr.rule_name, r.category,
                qrr.severity, qrr.context_info,
                qrr.index_recommendation, qrr.optimized_fragment,
                qrr.triggered_at
            FROM   query_rule_results qrr
            JOIN   optimization_rules r ON r.rule_id = qrr.rule_id
            WHERE  qrr.query_log_id = p_query_id
            ORDER BY
                CASE qrr.severity WHEN 'HIGH' THEN 1 WHEN 'MEDIUM' THEN 2 ELSE 3 END,
                qrr.triggered_at;
    END get_rule_results;

END rule_engine_pkg;
/

PROMPT >> RULE_ENGINE_PKG body compiled (10 rules: 7 enhanced + 3 new).
SHOW ERRORS PACKAGE BODY rule_engine_pkg
