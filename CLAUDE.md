# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

AI-powered SQL Query Optimizer with two independent layers:

- **Backend:** Oracle PL/SQL package (`QUERY_ANALYZER_PKG`) — analyzes queries via `EXPLAIN PLAN`, never executes them
- **Frontend:** Next.js 16 / React 19 / TypeScript chat UI (`frontend/`)

Phase 3 connects the frontend to the Claude API for AI-powered query analysis. The Oracle backend and the AI bridge are still independent (no direct Oracle→Claude link yet).

## Commands

### Frontend

```bash
cd frontend
npm run dev      # Dev server at http://localhost:3000
npm run build    # Production build
npm run lint     # ESLint
```

### Oracle Backend (SQL*Plus or SQL Developer)

```sql
-- Install all database objects (run in order)
@scripts/install.sql           -- Phase 1
@scripts/install_phase2.sql    -- Phase 2 (requires Phase 1)
@scripts/install_phase4.sql    -- Phase 4 (requires Phase 1 + 2)

-- Load test data then run test suites
@test/01_setup_sample_data.sql
@test/02_test_analyze_query.sql        -- 7 functional tests (Phase 1)
@test/03_test_error_handling.sql       -- 9 error handling tests (Phase 1)
@test/04_test_rule_engine.sql          -- Phase 2 rule engine tests
@test/05_test_validation_engine.sql    -- 8 functional tests (Phase 4)

-- Uninstall
@sql/04_drop_all.sql
```

**Prerequisites:** Oracle Database 12c+ (Oracle XE works); `SET SERVEROUTPUT ON SIZE UNLIMITED` before running package calls.

## Architecture

### Oracle Backend (`sql/`)

The core is `QUERY_ANALYZER_PKG` (spec: `02_create_package_spec.sql`, body: `03_create_package_body.sql`):

```
ANALYZE_QUERY(p_query, p_report OUT CLOB)
  → validate_query()           -- rejects NULL, non-SELECT, DML/DDL
  → EXPLAIN PLAN FOR <query>   -- dynamic SQL; generates plan without executing
  → DBMS_XPLAN.DISPLAY()       -- fetches plan text
  → PARSE_PLAN()               -- extracts scan type, cost, cardinality, join type, filters
  → INSERT into QUERY_PLAN_LOG -- audit trail
  → returns JSON CLOB report
```

Output is always JSON — either `{"status":"SUCCESS", "analysis":{...}}` or `{"status":"ERROR", "message":"..."}`. See README.md for the full schema.

`GET_ANALYSIS_HISTORY(p_limit, p_result OUT SYS_REFCURSOR)` fetches the audit log.

### Frontend (`frontend/app/page.tsx`)

Single React component (~1200 lines) with two modes toggled by `activeMode`:

- **SQL Optimizer mode** — multi-turn context collection (schema → indexes → execution plan → data), then Phase 2 rule evaluation + Phase 3 AI analysis
- **Database Assistant mode** — free-form Q&A, sample query generation, concept explanations

State is split into two message arrays (`optMessages`, `asstMessages`). `sessionContext` accumulates attachments before `finalizeAnalysis()` (async) runs Phase 2 rules client-side then calls `/api/analyze` for AI results.

## Next.js Version Warning

This project uses **Next.js 16.2.3 with React 19** — breaking changes exist vs. prior versions. Before writing any frontend code, read the relevant guide in `frontend/node_modules/next/dist/docs/`. Heed all deprecation notices. (See `frontend/AGENTS.md`.)

## Phase 2 — Rule Engine (`sql/05–08`, `scripts/install_phase2.sql`)

**New Oracle objects:**
- `OPTIMIZATION_RULES` — catalogue of 7 rules with severity/category/recommendation
- `QUERY_RULE_RESULTS` — one row per triggered rule per query (FK → `QUERY_PLAN_LOG`)
- `RULE_ENGINE_PKG` — package with `APPLY_RULES` and `GET_RULE_RESULTS`

**The 7 rules:** SELECT_STAR_DETECTED (MEDIUM), FULL_TABLE_SCAN_DETECTED (HIGH), MISSING_INDEX_ON_FILTER (HIGH), FUNCTION_ON_INDEXED_COLUMN (MEDIUM), SUBQUERY_CANDIDATE_FOR_JOIN (MEDIUM), UNNECESSARY_DISTINCT (LOW), CARTESIAN_JOIN_DETECTED (HIGH).

**`APPLY_RULES` flow:**
1. Validates SELECT-only input
2. Calls `QUERY_ANALYZER_PKG.ANALYZE_QUERY` (Phase 1) to create a `QUERY_PLAN_LOG` row if no `p_query_id` supplied
3. Runs `EXPLAIN PLAN` independently for plan-dependent rules (Rules 2 & 7)
4. Evaluates all 7 rules via private procedures; each calls `persist_result()` on trigger
5. Commits, then calls `build_json_report()` for JSON CLOB output

**Frontend (Phase 2 UI):** The frontend simulates the same 7 rules in TypeScript (`applyPhase2Rules` in `page.tsx`) for instant feedback before the API bridge exists. The `RuleCard` component renders each triggered rule with collapsible details, severity badge, index DDL, and a rewrite fragment.

## Phase 3 — AI-Powered Analysis (`frontend/app/api/analyze/route.ts`)

**New objects:**
- `frontend/app/api/analyze/route.ts` — Next.js App Router POST handler; calls `claude-sonnet-4-6` via `@anthropic-ai/sdk`
- `frontend/.env.local` — holds `ANTHROPIC_API_KEY` (not committed)

**Flow in `finalizeAnalysis` (async):**
1. Phase 1/2 run synchronously (client-side, instant)
2. `fetch('/api/analyze', { method: 'POST', body: JSON.stringify({ query, schema, indexes, plan, rules }) })`
3. API route calls Claude with a fixed SQL expert system prompt
4. Returns `AIAnalysis` JSON: `decision`, `confidence`, `issues[]`, `optimized_queries[]`, `explanation`
5. `AIAnalysisPanel` renders the result — decision badge + confidence bar, issues list, tabbed optimized queries with explanations, collapsible AI explanation

**Environment setup:** copy `frontend/.env.local` and replace the placeholder with a real key from console.anthropic.com.

## Phase 4 — Validation & Benchmark Engine (`sql/09–11`, `scripts/install_phase4.sql`)

**New Oracle objects:**
- `QUERY_BENCHMARK` — one row per query per benchmark run (FK → `QUERY_PLAN_LOG`)
- `VALIDATION_ENGINE_PKG` — package with `VALIDATE_AND_BENCHMARK` and `GET_BENCHMARK_RESULTS`

**`VALIDATE_AND_BENCHMARK` flow:**
1. Validates original query (SELECT-only)
2. For each optimized candidate: policy check → symmetric MINUS comparison vs original → timing
3. Timing uses `SELECT COUNT(*) FROM (<query>)` executed 1–5 times; avg/min/max captured
4. All results persisted to `QUERY_BENCHMARK` via `persist_benchmark()`
5. Winner selected by lowest `avg_exec_ms`; decision is `ORIGINAL_FASTEST`, `OPTIMIZED_SELECTED`, or `NO_VALID_QUERY`
6. Returns structured JSON with `decision`, `winner`, `speedup_factor`, `reasoning`, and a `benchmarks[]` array

**Result-set comparison:** `compare_result_sets` uses `SELECT COUNT(*) FROM ((A MINUS B) UNION ALL (B MINUS A))`. A count of 0 means identical sets.

**Caller pattern:**
```sql
DECLARE
    l_queries validation_engine_pkg.query_list_t;
    l_result  CLOB;
BEGIN
    l_queries(1) := 'SELECT id, name FROM employees WHERE dept_id = 10';
    l_queries(2) := 'SELECT /*+ INDEX(e idx_dept) */ id, name FROM employees e WHERE dept_id = 10';
    validation_engine_pkg.validate_and_benchmark(
        p_original_query    => 'SELECT * FROM employees WHERE dept_id = 10',
        p_optimized_queries => l_queries,
        p_iterations        => 3,
        p_result            => l_result
    );
    DBMS_OUTPUT.PUT_LINE(SUBSTR(l_result, 1, 4000));
END;
```

## Roadmap

| Phase | Status |
|-------|--------|
| Phase 1 — DB-native analysis engine | Complete |
| Phase 2 — Rule-based optimization + index recommendations | Complete |
| Phase 3 — AI-powered query analysis (Claude API bridge) | Complete |
| Phase 4 — Validation engine + result comparison | Complete |
