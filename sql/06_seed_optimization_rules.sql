-- ============================================================================
-- AI-Powered SQL Query Optimizer — Phase 2
-- Script: 06_seed_optimization_rules.sql
-- Purpose: Seed OPTIMIZATION_RULES with the 7 core rule definitions
-- Safe to re-run: clears existing seed rows first.
-- ============================================================================

DELETE FROM query_rule_results;
DELETE FROM optimization_rules;

-- ============================================================================
-- Rule 1 — SELECT * (STRUCTURE / MEDIUM)
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'SELECT_STAR_DETECTED',
    'STRUCTURE', 'MEDIUM',
    'Query uses SELECT * which retrieves every column in the table, including columns '
 || 'not needed by the application. This inflates I/O, network transfer, buffer cache '
 || 'usage, and prevents Oracle from using covering (index-only) scans.',
    'Explicitly list only the columns your application consumes. '
 || 'Example: replace  SELECT * FROM orders  with  SELECT id, status, amount FROM orders. '
 || 'This reduces row width, enables index-only access paths, and makes SELECT intent clear.'
);

-- ============================================================================
-- Rule 2 — Full Table Scan (SCAN / HIGH)
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'FULL_TABLE_SCAN_DETECTED',
    'SCAN', 'HIGH',
    'The execution plan contains a TABLE ACCESS FULL operation. Oracle reads every '
 || 'allocated block of the segment regardless of how many rows satisfy the predicate. '
 || 'On large tables this causes heavy I/O and degrades concurrent query performance.',
    'Add a B-tree index on the column(s) referenced in WHERE and JOIN predicates. '
 || 'Verify optimizer statistics are current: '
 || 'EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, ''table_name''); '
 || 'For very large tables, consider range or list partitioning so scans are pruned to '
 || 'relevant partitions only.'
);

-- ============================================================================
-- Rule 3 — Missing Index on Filter Column (SCAN / HIGH)
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'MISSING_INDEX_ON_FILTER',
    'SCAN', 'HIGH',
    'One or more columns referenced in WHERE predicates have no corresponding index '
 || 'entry in USER_IND_COLUMNS. Without an index Oracle must perform a full or partial '
 || 'table scan to locate matching rows, even when the predicate is highly selective.',
    'Create a B-tree index on each unindexed filter column. '
 || 'For composite predicates prefer a composite index ordered by selectivity '
 || '(most selective column first). '
 || 'Generated CREATE INDEX DDL is available in the index_recommendation field. '
 || 'After creation, gather fresh statistics to let the optimizer discover the new index.'
);

-- ============================================================================
-- Rule 4 — Function on Indexed Column (PERFORMANCE / MEDIUM)
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'FUNCTION_ON_INDEXED_COLUMN',
    'PERFORMANCE', 'MEDIUM',
    'A scalar function (UPPER, LOWER, TRUNC, TO_DATE, TO_NUMBER, SUBSTR, NVL, etc.) '
 || 'wraps a column inside the WHERE clause. Because the stored index values differ from '
 || 'the function-transformed comparand, Oracle cannot use a standard B-tree index on '
 || 'that column and falls back to a full table or index full scan.',
    'Option 1 — Create a Function-Based Index (FBI) that mirrors the transformation: '
 || 'CREATE INDEX idx_name ON table_name (UPPER(column_name)); '
 || 'The query predicate must then match the FBI expression exactly. '
 || 'Option 2 — Rewrite the predicate to avoid applying a function to the column side; '
 || 'e.g. replace TRUNC(order_date) = :dt with '
 || 'order_date >= TRUNC(:dt) AND order_date < TRUNC(:dt) + 1.'
);

-- ============================================================================
-- Rule 5 — Subquery Candidate for JOIN Rewrite (STRUCTURE / MEDIUM)
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'SUBQUERY_CANDIDATE_FOR_JOIN',
    'STRUCTURE', 'MEDIUM',
    'The query contains a subquery inside IN() or EXISTS(). Uncorrelated IN subqueries '
 || 'may be executed once and materialised, while correlated variants can execute once per '
 || 'outer row. Both patterns can prevent Oracle from choosing cost-optimal join methods '
 || 'such as hash joins or merge joins available to explicit JOIN syntax.',
    'Rewrite IN(SELECT ...) as an explicit INNER JOIN: '
 || 'replace  WHERE id IN (SELECT ref_id FROM t2 WHERE cond)  with '
 || 'INNER JOIN t2 ON t1.id = t2.ref_id AND cond. '
 || 'For NOT IN, prefer NOT EXISTS or LEFT JOIN ... WHERE t2.key IS NULL, '
 || 'which handle NULLs predictably and allow better join strategies.'
);

-- ============================================================================
-- Rule 6 — Unnecessary DISTINCT (PERFORMANCE / LOW)
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'UNNECESSARY_DISTINCT',
    'PERFORMANCE', 'LOW',
    'SELECT DISTINCT forces a sort-and-deduplicate step across the entire result set '
 || 'before rows are returned. When joins are performed exclusively on primary key or '
 || 'unique-constrained columns the result is already unique, making DISTINCT a '
 || 'wasted sort pass that consumes CPU and temp tablespace.',
    'Verify whether duplicates can actually appear in the result. '
 || 'If all join conditions use primary or unique key columns, remove DISTINCT — '
 || 'the result is guaranteed unique by the key constraint. '
 || 'If duplicates do appear, investigate the root cause: a missing join condition '
 || 'or an unintended many-to-many relationship is a common culprit. '
 || 'Fixing the root cause is preferable to masking it with DISTINCT.'
);

-- ============================================================================
-- Rule 7 — Cartesian Join (JOIN / HIGH)
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'CARTESIAN_JOIN_DETECTED',
    'JOIN', 'HIGH',
    'A Cartesian product was detected — either the execution plan shows MERGE JOIN '
 || 'CARTESIAN, or multiple tables appear in the FROM clause without join predicates '
 || 'linking them. A Cartesian join between tables of M and N rows produces M×N output '
 || 'rows. On non-trivial tables this can exhaust temp tablespace and run indefinitely.',
    'Add an explicit ON or USING join condition for every table pair. '
 || 'Prefer ANSI JOIN syntax (INNER JOIN, LEFT JOIN) over comma-separated FROM lists: '
 || 'it forces you to write the join condition inline and makes omissions obvious. '
 || 'If a true cross join is intended, document it explicitly with the CROSS JOIN keyword. '
 || 'Review the query for missing WHERE predicates linking each table alias.'
);

-- ============================================================================
-- Rule 8 — Table Context Summary (STRUCTURE / LOW)
--   Always-on informational rule. Emits per-table size, index, and
--   primary-key data so downstream consumers (AI, frontend) get the full
--   schema picture without making extra round-trips.
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'TABLE_CONTEXT_SUMMARY',
    'STRUCTURE', 'LOW',
    'Snapshot of every table referenced by the query: row count, block count, '
 || 'existing indexes, and primary-key columns sourced from USER_TABLES, '
 || 'USER_INDEXES, USER_IND_COLUMNS, and USER_CONSTRAINTS.',
    'No action required. This rule provides schema context for the AI rewriter '
 || 'and human reviewers. Verify statistics are current with '
 || 'DBMS_STATS.GATHER_TABLE_STATS so the row/block counts reflect reality.'
);

-- ============================================================================
-- Rule 9 — Aggregate / Sort on Unindexed Column (PERFORMANCE / MEDIUM)
--   Detects GROUP BY and ORDER BY columns that are not the leading column of
--   any index. Sorting an unindexed column forces a full sort pass.
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'AGGREGATE_INDEX_HINT',
    'PERFORMANCE', 'MEDIUM',
    'Columns referenced in GROUP BY or ORDER BY are not the leading column of '
 || 'any existing index. Without a usable index Oracle must perform a full '
 || 'in-memory sort (or temp-tablespace sort if the data exceeds PGA), which '
 || 'consumes CPU and may spill to disk on large datasets.',
    'Add an index on the GROUP BY / ORDER BY column, ordered to match the sort. '
 || 'Composite indexes covering both the WHERE filter and the GROUP BY column '
 || 'enable index-only sorted access. For aggregations with a fixed grouping '
 || 'set, consider a materialized view with REFRESH FAST ON COMMIT.'
);

-- ============================================================================
-- Rule 10 — High Plan Cost (SCAN / HIGH)
--   Fires when the optimizer estimates a total cost above a threshold. Cost
--   is unitless but a useful relative indicator of expensive plans.
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'HIGH_COST_PLAN',
    'SCAN', 'HIGH',
    'The optimizer-estimated cost of this plan exceeds the threshold (1000). '
 || 'High cost typically indicates one or more of: full table scans, large '
 || 'sorts, hash joins on big inputs, missing indexes, or stale statistics. '
 || 'Cost is a unitless I/O+CPU estimate produced by the cost-based optimizer.',
    'Inspect the execution plan top-down. The line with the highest individual '
 || 'cost is usually the bottleneck. Common fixes: add an index on the WHERE '
 || 'predicate, narrow the result early with a more selective predicate, '
 || 'or refresh table statistics. Consider partition pruning for very large '
 || 'tables.'
);

-- ============================================================================
-- Rule 11 — Implicit Type Conversion (PERFORMANCE / HIGH)
--   Detects when the optimizer injects INTERNAL_FUNCTION() or SYS_OP_C2C()
--   into a predicate, indicating a silent datatype coercion (DATE↔VARCHAR,
--   NUMBER↔VARCHAR, NCHAR↔CHAR). These coercions disable B-tree access on the
--   coerced column AND make results NLS-dependent.
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'IMPLICIT_TYPE_CONVERSION',
    'PERFORMANCE', 'HIGH',
    'The execution plan shows an implicit datatype conversion injected into a '
 || 'predicate (INTERNAL_FUNCTION or SYS_OP_C2C around an indexed column). '
 || 'This typically happens when a DATE column is compared to a string literal, '
 || 'a NUMBER column to a quoted value, or NCHAR to CHAR. The conversion '
 || 'disables index access on the wrapped column and the comparison silently '
 || 'depends on NLS_DATE_FORMAT / NLS_NUMERIC_CHARACTERS, which can produce '
 || 'wrong results or ORA-01843 / ORA-01722 in another session.',
    'Match datatypes explicitly on the literal side. '
 || 'Replace  WHERE trn_dt <= ''07-FEB-2020''  with  '
 || 'WHERE trn_dt <= TO_DATE(''2020-02-07'',''YYYY-MM-DD'')  '
 || 'or use ANSI date literals: WHERE trn_dt <= DATE ''2020-02-07''. '
 || 'For numbers, drop the quotes: branch_code = 114 (not ''114''). '
 || 'Once the literal type matches the column, the optimizer can use the index.'
);

-- ============================================================================
-- Rule 12 — Literal Instead of Bind (PERFORMANCE / LOW)
--   Detects WHERE col = '<literal>'  or  WHERE col = <number>  patterns
--   where the column has an index but the literal is hardcoded — preventing
--   cursor sharing and inflating the shared pool with near-duplicate plans.
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'LITERAL_INSTEAD_OF_BIND',
    'PERFORMANCE', 'LOW',
    'A WHERE predicate compares an indexed column to a hardcoded literal '
 || 'instead of a bind variable. Each distinct literal creates a fresh entry '
 || 'in the cursor cache and forces a hard parse, inflating shared-pool '
 || 'memory and CPU on high-frequency queries. Literal-driven plans also '
 || 'expose the application to SQL injection when concatenated dynamically.',
    'Replace literals with bind variables. '
 || 'In application code use parameterised queries: '
 || '  EXECUTE IMMEDIATE ''... WHERE branch_code = :1'' USING p_branch; '
 || 'In ad-hoc tools enable CURSOR_SHARING=FORCE only as a last resort — '
 || 'fixing the application is preferable. Bind variables let Oracle re-use '
 || 'one cursor across thousands of executions.'
);

-- ============================================================================
-- Rule 13 — Stale or Missing Statistics (SCAN / MEDIUM)
--   Reads ALL_TABLES.LAST_ANALYZED for every table referenced. Fires when any
--   table has NULL stats or LAST_ANALYZED older than 30 days. Stale stats are
--   the #1 cause of bad plans on otherwise healthy queries.
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'STALE_STATISTICS',
    'SCAN', 'MEDIUM',
    'One or more tables referenced by the query have NULL or stale optimizer '
 || 'statistics (LAST_ANALYZED is NULL or older than 30 days). The cost-based '
 || 'optimizer makes cardinality estimates from these stats; when they are '
 || 'wrong, it picks the wrong join order, the wrong access path, or the wrong '
 || 'join method — sometimes by orders of magnitude.',
    'Refresh statistics for each flagged table: '
 || 'EXEC DBMS_STATS.GATHER_TABLE_STATS(USER, ''<table_name>'', cascade=>TRUE); '
 || 'For high-churn tables, schedule a nightly job or enable Oracle''s '
 || 'automatic stats job (DEFAULT). For very large partitioned tables, prefer '
 || 'INCREMENTAL stats so partition-level changes do not trigger a full '
 || 'gather: DBMS_STATS.SET_TABLE_PREFS(USER,''<tbl>'',''INCREMENTAL'',''TRUE'').'
);

-- ============================================================================
-- Rule 14 — LIKE with Leading Wildcard (PERFORMANCE / HIGH)
--   Predicates of the form  col LIKE '%foo'  or  col LIKE '%foo%'  cannot use
--   a B-tree index — the leading character is unknown so the index range is
--   the entire column. Forces a full scan on the table.
-- ============================================================================
INSERT INTO optimization_rules (rule_name, category, severity, description, recommendation)
VALUES (
    'LIKE_LEADING_WILDCARD',
    'PERFORMANCE', 'HIGH',
    'A WHERE predicate uses LIKE with a wildcard ( % or _ ) at the start of '
 || 'the pattern. B-tree indexes are sorted left-to-right by leading '
 || 'character; with the leading character unknown the optimizer must scan '
 || 'the entire column. On large tables this becomes a full table scan even '
 || 'when an index exists.',
    'Pin the leading character whenever possible: '
 || 'replace  LIKE ''%foo''  with an indexed reverse-key search or store '
 || 'pre-reversed values; replace  LIKE ''%foo%''  with Oracle Text (CONTEXT '
 || 'or CTXCAT index) for substring search; or split the column so the '
 || 'searchable prefix lives in its own indexed column. For two-prefix cases '
 || '(LIKE ''1%'' OR LIKE ''2%'') prefer  BETWEEN ''1'' AND ''3''  which keeps '
 || 'a single index range scan.'
);

COMMIT;

PROMPT >> 14 optimization rules seeded into OPTIMIZATION_RULES (7 core + 3 deep + 4 precision).
