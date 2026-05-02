-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 4
-- Script: 11_create_validation_package_body.sql
-- Purpose: VALIDATION_ENGINE_PKG package body — validation + benchmark engine
-- ============================================================================

CREATE OR REPLACE PACKAGE BODY validation_engine_pkg
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
    -- PRIVATE: validate_select_only
    -- Sets p_error when the query is NULL, empty, or not SELECT/WITH.
    -- ========================================================================
    PROCEDURE validate_select_only (
        p_query IN  CLOB,
        p_error OUT VARCHAR2
    ) IS
        l_upper VARCHAR2(200);
    BEGIN
        p_error := NULL;
        IF p_query IS NULL OR DBMS_LOB.GETLENGTH(p_query) = 0 THEN
            p_error := 'Query is NULL or empty';
            RETURN;
        END IF;
        l_upper := UPPER(TRIM(DBMS_LOB.SUBSTR(p_query, 200, 1)));
        IF l_upper NOT LIKE 'SELECT%' AND l_upper NOT LIKE 'WITH%' THEN
            p_error := 'Only SELECT / WITH queries are allowed. Got: '
                    || SUBSTR(l_upper, 1, 40);
        END IF;
    END validate_select_only;

    -- ========================================================================
    -- PRIVATE: time_query
    -- Wraps p_query in COUNT(*) and executes it p_iters times.
    -- The COUNT(*) wrapper forces a full scan without needing column definitions,
    -- and the row count is captured on the first execution for free.
    -- Returns avg/min/max in milliseconds and actual row count.
    -- ========================================================================
    PROCEDURE time_query (
        p_query  IN  CLOB,
        p_iters  IN  NUMBER,
        p_avg_ms OUT NUMBER,
        p_min_ms OUT NUMBER,
        p_max_ms OUT NUMBER,
        p_rows   OUT NUMBER,
        p_error  OUT VARCHAR2
    ) IS
        v_start    TIMESTAMP;
        v_interval INTERVAL DAY TO SECOND;
        v_elapsed  NUMBER;
        v_total    NUMBER := 0;
        v_count    NUMBER;
        v_sql      CLOB;
    BEGIN
        p_avg_ms := NULL; p_min_ms := NULL; p_max_ms := NULL;
        p_rows   := 0;    p_error  := NULL;

        v_sql := 'SELECT COUNT(*) FROM (' || p_query || ')';

        -- Row count (pre-timing, single call)
        EXECUTE IMMEDIATE v_sql INTO p_rows;

        -- Timed iterations
        FOR i IN 1..p_iters LOOP
            v_start    := SYSTIMESTAMP;
            EXECUTE IMMEDIATE v_sql INTO v_count;
            v_interval := SYSTIMESTAMP - v_start;
            v_elapsed  := (  EXTRACT(HOUR   FROM v_interval) * 3600
                           + EXTRACT(MINUTE FROM v_interval) * 60
                           + EXTRACT(SECOND FROM v_interval)) * 1000;

            v_total := v_total + v_elapsed;
            IF p_min_ms IS NULL OR v_elapsed < p_min_ms THEN p_min_ms := v_elapsed; END IF;
            IF p_max_ms IS NULL OR v_elapsed > p_max_ms THEN p_max_ms := v_elapsed; END IF;
        END LOOP;

        p_avg_ms := v_total / p_iters;

    EXCEPTION
        WHEN OTHERS THEN
            p_error  := SQLERRM;
            p_avg_ms := NULL; p_min_ms := NULL; p_max_ms := NULL;
    END time_query;

    -- ========================================================================
    -- PRIVATE: compare_result_sets
    -- Strict row-by-row comparison via symmetric MINUS. p_diff = 0 means
    -- the two result sets are identical.
    --
    -- Fallback for SELECT * across multi-table joins:
    --   When MINUS fails with ORA-00918 (column ambiguously defined) or
    --   ORA-00957 (duplicate column name) — typical for queries that project
    --   shared audit columns from joined tables — we cannot do a true MINUS,
    --   but we CAN compare row counts via SELECT COUNT(*) FROM (q). That
    --   gives a weaker "rows-match" verdict and we tag p_match accordingly.
    --
    -- Output:
    --   p_diff  = 0  when result sets are equivalent under the chosen check
    --   p_diff  = -1 when comparison failed entirely
    --   p_match = 'STRICT' when MINUS-equivalence proven
    --           = 'ROW_COUNT' when only row counts could be compared
    --           = 'FAILED' when neither could be checked
    --   p_error = empty on success, error message otherwise
    -- ========================================================================
    PROCEDURE compare_result_sets (
        p_query1 IN  CLOB,
        p_query2 IN  CLOB,
        p_diff   OUT NUMBER,
        p_match  OUT VARCHAR2,
        p_error  OUT VARCHAR2
    ) IS
        v_sql       CLOB;
        v_count1    NUMBER;
        v_count2    NUMBER;
        v_amb_col   EXCEPTION;
        v_dup_col   EXCEPTION;
        PRAGMA EXCEPTION_INIT(v_amb_col, -918);   -- ORA-00918 column ambiguously defined
        PRAGMA EXCEPTION_INIT(v_dup_col, -957);   -- ORA-00957 duplicate column name
    BEGIN
        p_diff  := -1;
        p_match := 'FAILED';
        p_error := NULL;

        -- Try strict MINUS comparison first.
        BEGIN
            v_sql :=
                'SELECT COUNT(*) FROM ('  ||
                '  SELECT * FROM (' || p_query1 || ')' ||
                '  MINUS '                              ||
                '  SELECT * FROM (' || p_query2 || ')' ||
                '  UNION ALL '                          ||
                '  SELECT * FROM (' || p_query2 || ')' ||
                '  MINUS '                              ||
                '  SELECT * FROM (' || p_query1 || ')' ||
                ')';
            EXECUTE IMMEDIATE v_sql INTO p_diff;
            p_match := 'STRICT';
            RETURN;
        EXCEPTION
            WHEN v_amb_col OR v_dup_col THEN
                -- Fall through to row-count comparison.
                NULL;
            WHEN OTHERS THEN
                p_diff  := -1;
                p_match := 'FAILED';
                p_error := 'Comparison error: ' || SQLERRM;
                RETURN;
        END;

        -- Fallback path: count rows on each side and compare. This is a
        -- weaker check (two queries can have the same row count yet return
        -- different rows) but it is always parseable.
        BEGIN
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM (' || p_query1 || ')' INTO v_count1;
            EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM (' || p_query2 || ')' INTO v_count2;
            p_diff  := ABS(v_count1 - v_count2);
            p_match := 'ROW_COUNT';
            -- If counts disagree, surface as comparison "differs" with an
            -- explanatory message but a real diff number.
            IF p_diff > 0 THEN
                p_error := 'Row counts differ: original=' || v_count1
                        || ', candidate=' || v_count2
                        || ' (strict row-by-row check skipped: SELECT * across joined tables produced duplicate column names)';
            ELSE
                p_error := 'Row counts match (' || v_count1
                        || '). Strict row-by-row check skipped: SELECT * across joined tables produced duplicate column names.';
            END IF;
        EXCEPTION
            WHEN OTHERS THEN
                p_diff  := -1;
                p_match := 'FAILED';
                p_error := 'Row-count fallback failed: ' || SQLERRM;
        END;
    END compare_result_sets;

    -- ========================================================================
    -- PRIVATE: persist_benchmark
    -- Inserts one row into QUERY_BENCHMARK and returns the new BENCHMARK_ID.
    -- ========================================================================
    FUNCTION persist_benchmark (
        p_query_log_id  IN NUMBER,
        p_label         IN VARCHAR2,
        p_query         IN CLOB,
        p_is_valid      IN CHAR,
        p_val_msg       IN VARCHAR2,
        p_row_count     IN NUMBER,
        p_results_match IN VARCHAR2,
        p_diff_rows     IN NUMBER,
        p_iter_count    IN NUMBER,
        p_avg_ms        IN NUMBER,
        p_min_ms        IN NUMBER,
        p_max_ms        IN NUMBER
    ) RETURN NUMBER IS
        v_id NUMBER;
    BEGIN
        INSERT INTO query_benchmark (
            query_log_id, query_label, query_text,
            is_valid, validation_msg, result_row_count,
            results_match, diff_row_count, iter_count,
            avg_exec_ms, min_exec_ms, max_exec_ms
        ) VALUES (
            p_query_log_id, p_label, p_query,
            p_is_valid, SUBSTR(p_val_msg, 1, 4000), NVL(p_row_count, 0),
            p_results_match, NVL(p_diff_rows, 0), p_iter_count,
            p_avg_ms, p_min_ms, p_max_ms
        ) RETURNING benchmark_id INTO v_id;
        COMMIT;
        RETURN v_id;
    EXCEPTION
        WHEN OTHERS THEN
            ROLLBACK;
            RETURN -1;
    END persist_benchmark;

    -- ========================================================================
    -- VALIDATE_AND_BENCHMARK  (Public)
    -- Orchestrates validation, comparison, benchmarking, persistence,
    -- and JSON report assembly for the original + all optimized queries.
    -- ========================================================================
    PROCEDURE validate_and_benchmark (
        p_original_query    IN  CLOB,
        p_optimized_queries IN  query_list_t,
        p_iterations        IN  NUMBER  DEFAULT 3,
        p_query_log_id      IN  NUMBER  DEFAULT NULL,
        p_result            OUT CLOB
    ) IS
        -- Internal record for one query's full result set
        TYPE bench_rec IS RECORD (
            label      VARCHAR2(50),
            query      CLOB,
            is_valid   CHAR(1),
            val_msg    VARCHAR2(4000),
            row_count  NUMBER,
            match      VARCHAR2(20),  -- YES | NO | ROW_COUNT | N/A
            diff_rows  NUMBER,
            avg_ms     NUMBER,
            min_ms     NUMBER,
            max_ms     NUMBER,
            bench_id   NUMBER
        );
        TYPE bench_tab IS TABLE OF bench_rec INDEX BY PLS_INTEGER;

        l_entries     bench_tab;
        l_count       PLS_INTEGER := 0;
        l_iters       NUMBER;
        l_error       VARCHAR2(4000);
        l_diff        NUMBER;
        l_match       VARCHAR2(20);
        l_warn_msg    VARCHAR2(4000);

        -- Winner tracking
        l_best_idx    PLS_INTEGER := -1;
        l_best_ms     NUMBER      := NULL;
        l_orig_valid  BOOLEAN     := FALSE;
        l_orig_ms     NUMBER      := 0;

        -- JSON assembly
        l_benchmarks  CLOB := '[';
        l_first       BOOLEAN := TRUE;
        l_decision    VARCHAR2(50);
        l_reasoning   VARCHAR2(4000);
        l_speedup     NUMBER  := 1;
        l_winner      VARCHAR2(50) := 'NONE';
        l_json        CLOB;
        l_head        VARCHAR2(4000);
    BEGIN
        l_iters := LEAST(GREATEST(NVL(p_iterations, 3), 1), 5);

        -- ---------------------------------------------------------------
        -- Step 1: Validate and benchmark the original query
        -- ---------------------------------------------------------------
        l_entries(0).label    := 'ORIGINAL';
        l_entries(0).query    := p_original_query;
        l_entries(0).match    := 'N/A';
        l_entries(0).diff_rows := 0;
        l_count := 1;

        validate_select_only(p_original_query, l_error);
        IF l_error IS NOT NULL THEN
            l_entries(0).is_valid  := 'N';
            l_entries(0).val_msg   := l_error;
            l_entries(0).row_count := 0;
        ELSE
            time_query(p_original_query, l_iters,
                       l_entries(0).avg_ms, l_entries(0).min_ms,
                       l_entries(0).max_ms, l_entries(0).row_count, l_error);
            IF l_error IS NOT NULL THEN
                l_entries(0).is_valid := 'N';
                l_entries(0).val_msg  := 'Execution error: ' || l_error;
            ELSE
                l_entries(0).is_valid := 'Y';
                l_entries(0).val_msg  := 'OK';
                l_orig_valid := TRUE;
                l_orig_ms    := NVL(l_entries(0).avg_ms, 0);
                l_best_idx   := 0;
                l_best_ms    := l_orig_ms;
            END IF;
        END IF;

        -- ---------------------------------------------------------------
        -- Step 2: Validate, compare, and benchmark each optimized query
        -- ---------------------------------------------------------------
        FOR i IN 1..p_optimized_queries.COUNT LOOP
            l_entries(i).label := 'OPTIMIZED_' || i;
            l_entries(i).query := p_optimized_queries(i);
            l_count := l_count + 1;

            -- Policy check
            validate_select_only(p_optimized_queries(i), l_error);
            IF l_error IS NOT NULL THEN
                l_entries(i).is_valid  := 'N';
                l_entries(i).val_msg   := l_error;
                l_entries(i).match     := 'NO';
                l_entries(i).diff_rows := -1;
                l_entries(i).row_count := 0;
                CONTINUE;
            END IF;

            -- Result-set correctness check (only when original executed OK).
            -- compare_result_sets uses MINUS first; on ORA-00918 / 00957 it
            -- falls back to row-count comparison and tags p_match accordingly.
            IF l_orig_valid THEN
                l_warn_msg := NULL;
                compare_result_sets(p_original_query, p_optimized_queries(i),
                                    l_diff, l_match, l_error);

                IF l_match = 'STRICT' THEN
                    -- True row-by-row comparison succeeded
                    l_entries(i).diff_rows := l_diff;
                    IF l_diff = 0 THEN
                        l_entries(i).match := 'YES';
                    ELSE
                        l_entries(i).match    := 'NO';
                        l_entries(i).is_valid := 'N';
                        l_entries(i).val_msg  := 'Result set differs from original ('
                                             || l_diff || ' row(s) differ)';
                        l_entries(i).row_count := 0;
                        CONTINUE;
                    END IF;

                ELSIF l_match = 'ROW_COUNT' THEN
                    -- MINUS could not parse (duplicate column names from
                    -- SELECT * across joined tables). Use row-count fallback.
                    l_entries(i).diff_rows := l_diff;
                    IF l_diff = 0 THEN
                        l_entries(i).match    := 'ROW_COUNT';
                        l_warn_msg            := l_error;  -- informational
                    ELSE
                        l_entries(i).match    := 'NO';
                        l_entries(i).is_valid := 'N';
                        l_entries(i).val_msg  := l_error;  -- "Row counts differ..."
                        l_entries(i).row_count := 0;
                        CONTINUE;
                    END IF;

                ELSE  -- 'FAILED'
                    l_entries(i).is_valid  := 'N';
                    l_entries(i).val_msg   := NVL(l_error, 'Result-set comparison failed');
                    l_entries(i).match     := 'NO';
                    l_entries(i).diff_rows := -1;
                    l_entries(i).row_count := 0;
                    CONTINUE;
                END IF;
            ELSE
                l_entries(i).match     := 'N/A';
                l_entries(i).diff_rows := 0;
            END IF;

            -- Benchmark
            time_query(p_optimized_queries(i), l_iters,
                       l_entries(i).avg_ms, l_entries(i).min_ms,
                       l_entries(i).max_ms, l_entries(i).row_count, l_error);
            IF l_error IS NOT NULL THEN
                l_entries(i).is_valid  := 'N';
                l_entries(i).val_msg   := 'Execution error: ' || l_error;
                l_entries(i).row_count := 0;
            ELSE
                l_entries(i).is_valid := 'Y';
                -- Preserve the row-count-only warning when present, else 'OK'
                l_entries(i).val_msg  := NVL(l_warn_msg, 'OK');
                -- Update winner if faster than current best
                IF l_best_ms IS NULL OR l_entries(i).avg_ms < l_best_ms THEN
                    l_best_ms  := l_entries(i).avg_ms;
                    l_best_idx := i;
                END IF;
            END IF;
        END LOOP;

        -- ---------------------------------------------------------------
        -- Step 3: Persist all benchmark rows to QUERY_BENCHMARK
        -- ---------------------------------------------------------------
        FOR i IN 0..l_count - 1 LOOP
            l_entries(i).bench_id := persist_benchmark(
                p_query_log_id,
                l_entries(i).label,
                l_entries(i).query,
                NVL(l_entries(i).is_valid, 'N'),
                l_entries(i).val_msg,
                NVL(l_entries(i).row_count, 0),
                NVL(l_entries(i).match, 'N/A'),
                NVL(l_entries(i).diff_rows, 0),
                l_iters,
                l_entries(i).avg_ms,
                l_entries(i).min_ms,
                l_entries(i).max_ms
            );
        END LOOP;

        -- ---------------------------------------------------------------
        -- Step 4: Build JSON benchmarks array
        -- ---------------------------------------------------------------
        FOR i IN 0..l_count - 1 LOOP
            IF NOT l_first THEN l_benchmarks := l_benchmarks || ','; END IF;
            l_first := FALSE;
            l_benchmarks := l_benchmarks
                || '{"label":"'         || escape_json(l_entries(i).label) || '",'
                || '"is_valid":"'       || NVL(l_entries(i).is_valid, 'N') || '",'
                || '"validation_msg":"' || escape_json(NVL(l_entries(i).val_msg, '')) || '",'
                || '"result_row_count":' || NVL(TO_CHAR(l_entries(i).row_count), '0') || ','
                || '"results_match":"'  || NVL(l_entries(i).match, 'N/A') || '",'
                || '"diff_row_count":'  || NVL(TO_CHAR(l_entries(i).diff_rows), '0') || ','
                || '"avg_exec_ms":'     || NVL(TO_CHAR(ROUND(l_entries(i).avg_ms, 3)), 'null') || ','
                || '"min_exec_ms":'     || NVL(TO_CHAR(ROUND(l_entries(i).min_ms, 3)), 'null') || ','
                || '"max_exec_ms":'     || NVL(TO_CHAR(ROUND(l_entries(i).max_ms, 3)), 'null') || ','
                || '"benchmark_id":'    || NVL(TO_CHAR(l_entries(i).bench_id), 'null') || '}';
        END LOOP;
        l_benchmarks := l_benchmarks || ']';

        -- ---------------------------------------------------------------
        -- Step 5: Determine decision and reasoning
        -- ---------------------------------------------------------------
        IF l_best_idx = -1 THEN
            l_decision  := 'NO_VALID_QUERY';
            l_reasoning := 'All queries failed validation or result-set verification.';
            l_speedup   := 0;
            l_winner    := 'NONE';
        ELSIF l_best_idx = 0 THEN
            l_decision  := 'ORIGINAL_FASTEST';
            l_reasoning := 'Original query outperformed all valid optimized variants.';
            l_speedup   := 1;
            l_winner    := 'ORIGINAL';
        ELSE
            l_winner    := l_entries(l_best_idx).label;
            l_speedup   := CASE WHEN l_best_ms > 0
                                THEN ROUND(l_orig_ms / l_best_ms, 2)
                                ELSE 1 END;
            l_decision  := 'OPTIMIZED_SELECTED';
            l_reasoning := l_winner
                        || ' is fastest valid query: '
                        || TO_CHAR(l_speedup) || 'x speedup over original ('
                        || TO_CHAR(ROUND(l_orig_ms, 1)) || ' ms → '
                        || TO_CHAR(ROUND(l_best_ms, 1)) || ' ms avg).';
        END IF;

        -- ---------------------------------------------------------------
        -- Step 6: Assemble final JSON report
        -- ---------------------------------------------------------------
        l_head :=
            '{"status":"SUCCESS",'
         || '"version":"'         || c_version || '",'
         || '"decision":"'        || l_decision || '",'
         || '"winner":"'          || escape_json(l_winner) || '",'
         || '"speedup_factor":'   || TO_CHAR(NVL(l_speedup, 0)) || ','
         || '"original_avg_ms":'  || TO_CHAR(ROUND(NVL(l_orig_ms, 0), 3)) || ','
         || '"iterations_run":'   || l_iters || ','
         || '"reasoning":"'       || escape_json(l_reasoning) || '",'
         || '"benchmarks":';

        DBMS_LOB.CREATETEMPORARY(l_json, TRUE);
        DBMS_LOB.WRITEAPPEND(l_json, LENGTH(l_head), l_head);
        DBMS_LOB.APPEND(l_json, l_benchmarks);
        DBMS_LOB.WRITEAPPEND(l_json, 1, '}');

        p_result := l_json;

    EXCEPTION
        WHEN OTHERS THEN
            p_result := build_error_response(
                'Unexpected error in VALIDATE_AND_BENCHMARK: ' || SQLERRM);
            BEGIN ROLLBACK; EXCEPTION WHEN OTHERS THEN NULL; END;
    END validate_and_benchmark;

    -- ========================================================================
    -- GET_BENCHMARK_RESULTS  (Public)
    -- ========================================================================
    PROCEDURE get_benchmark_results (
        p_query_log_id  IN  NUMBER,
        p_result        OUT SYS_REFCURSOR
    ) IS
    BEGIN
        OPEN p_result FOR
            SELECT
                benchmark_id,
                query_label,
                is_valid,
                validation_msg,
                result_row_count,
                results_match,
                diff_row_count,
                iter_count,
                avg_exec_ms,
                min_exec_ms,
                max_exec_ms,
                created_at
            FROM  query_benchmark
            WHERE query_log_id = p_query_log_id
            ORDER BY
                CASE is_valid WHEN 'Y' THEN 1 ELSE 2 END,
                NVL(avg_exec_ms, 99999999);
    END get_benchmark_results;

END validation_engine_pkg;
/

PROMPT >> Package body VALIDATION_ENGINE_PKG created successfully.
