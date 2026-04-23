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

COMMIT;

PROMPT >> 7 optimization rules seeded into OPTIMIZATION_RULES.
