# AI-Powered SQL Query Optimizer

End-to-end query tuning workbench for Oracle: paste a slow `SELECT`, get back the execution plan as a flowchart, a rule-based audit, an AI-generated rewrite, and a benchmark that proves the rewrite is faster — all from a single click, against your live database.

The Oracle backend never executes the user's query at scale. Phase 1 + 2 use `EXPLAIN PLAN`, Phase 4 uses `SELECT COUNT(*) FROM (<query>)` so cursors are fetched without materialising row sets.

---

## Table of contents

- [Highlights](#highlights)
- [Architecture](#architecture)
- [Quick start](#quick-start)
- [Frontend](#frontend)
- [Oracle backend](#oracle-backend)
- [API reference](#api-reference)
- [Project structure](#project-structure)
- [Bug log](#bug-log)
- [Roadmap](#roadmap)

---

## Highlights

| Phase | What it does | Where |
|---|---|---|
| **1 — Analysis engine** | `EXPLAIN PLAN` + `DBMS_XPLAN` parsing, JSON output, audit log | `QUERY_ANALYZER_PKG` |
| **2 — Rule engine** | 14 rules (full-scan detection, missing index, function-on-column, implicit conversions, stale stats, OR→IN, …) with severity / category / index DDL recommendations | `RULE_ENGINE_PKG` |
| **3 — AI rewrite** | Gemini (default) or Anthropic. Prompt grounded with your real schema, indexes, FKs, NDV stats, plan, and rule findings | `frontend/lib/llm.ts`, `frontend/app/api/analyze/route.ts` |
| **4 — Validation + benchmark** | Symmetric `MINUS` for set-equality (with `ROW_COUNT` fallback), 1–5 timed iterations, winner selection | `VALIDATION_ENGINE_PKG` |
| **Frontend** | Next.js 16 / React 19 UI: SQL editor, plan flowchart with fullscreen, rule cards, side-by-side rewrite, benchmark with speedup factor, DB-only chat assistant | `frontend/` |

Other features:
- Live Oracle bridge via `oracledb` thin mode — no Oracle Instant Client install required
- Database Assistant tab: free-form Q&A bound to a strict DB-only scope (Oracle internals, SQL idioms, plan reading, indexing, PL/SQL)
- Per-tab session persistence: connection, history, chat, sidebar state all survive reload
- Collapsible 280 px ↔ 56 px sidebar with `prefers-reduced-motion` respect
- Comprehensive error handling: friendly modals, friendly rate-limit messages, race-condition guards, comment-only / placeholder pre-flight checks

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                                User browser                                   │
│  Sidebar │ Editor │ Plan / Rules / Rewrite / Benchmark tabs │ Assistant chat  │
└──────────────────────────────────────────────────────────────────────────────┘
                                       │ fetch
                                       ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                       Next.js Route Handlers (frontend/app/api)              │
│  /api/oracle/analyze  → RULE_ENGINE_PKG.APPLY_RULES (Phase 1 + 2)            │
│  /api/oracle/plan-tree → EXPLAIN PLAN + PLAN_TABLE                           │
│  /api/oracle/schema   → ALL_TABLES / ALL_INDEXES / ALL_TAB_COL_STATISTICS    │
│  /api/oracle/benchmark → VALIDATION_ENGINE_PKG.VALIDATE_AND_BENCHMARK        │
│  /api/analyze         → Gemini / Anthropic (rewrite + structured JSON)       │
│  /api/chat            → Gemini / Anthropic (DB-only chat)                    │
└──────────────────────────────────────────────────────────────────────────────┘
                          │                                     │
                  oracledb (thin)                       Gemini / Anthropic SDK
                          ▼                                     ▼
┌──────────────────────────────────────────┐    ┌────────────────────────────────┐
│             Oracle Database              │    │           LLM provider          │
│  QUERY_ANALYZER_PKG (Phase 1)            │    │  Default: gemini-2.5-flash     │
│  RULE_ENGINE_PKG    (Phase 2 — 14 rules) │    │  Optional: claude-sonnet-4-6   │
│  VALIDATION_ENGINE_PKG (Phase 4)         │    │  Auto-detect via env keys      │
│  Audit tables: QUERY_PLAN_LOG,           │    └────────────────────────────────┘
│                QUERY_RULE_RESULTS,       │
│                QUERY_BENCHMARK           │
└──────────────────────────────────────────┘
```

---

## Quick start

### 1. Install Oracle objects

```sql
sqlplus username/password@//host:port/service

@scripts/install.sql           -- Phase 1
@scripts/install_phase2.sql    -- Phase 2 (depends on Phase 1)
@scripts/install_phase4.sql    -- Phase 4 (depends on 1 + 2)
```

> Tested on Oracle 12c+ and Oracle XE. Set `SET SERVEROUTPUT ON SIZE UNLIMITED` before running PL/SQL blocks.

### 2. Configure the LLM

```bash
cd frontend
cp .env.local.example .env.local   # template included
```

Edit `.env.local` and set **one** of:
- `GEMINI_API_KEY=…` — free at [aistudio.google.com](https://aistudio.google.com), and the default
- `ANTHROPIC_API_KEY=…` — paid; opt in via `LLM_PROVIDER=anthropic`

### 3. Run the dev server

```bash
cd frontend
npm install
npm run dev
```

Open `http://localhost:3000`, click the connection footer (bottom-left of the sidebar), enter your Oracle credentials. They are kept in `sessionStorage` for the tab only.

### 4. Optimize a query

Paste a slow Oracle `SELECT` into the editor and press **`Ctrl/⌘ + Enter`** (or click **Optimize**). The right pane fills with:

- **Plan** — flowchart of the EXPLAIN PLAN tree, with table list, index list, and a quick health check (full-scan count, plan cost, op count). A Fullscreen button opens the flowchart in a portal-rendered modal.
- **Rules** — every triggered rule with severity badge, plain-English context, and a recommendation (often a `CREATE INDEX` DDL).
- **Rewrite** — original / AI rewrite side-by-side. Includes a "why this is better" + "trade-offs" block when the model produced one.
- **Benchmark** — speedup factor, before/after timing bar, per-candidate avg/min/max table, and a result-set match column (Identical / Row count only / Differs / Not tested).

---

## Frontend

```bash
cd frontend
npm run dev      # http://localhost:3000
npm run build    # production build
npm run lint     # ESLint
```

This project uses **Next.js 16.2.3 + React 19** — breaking changes exist vs older Next.js. See [`frontend/AGENTS.md`](frontend/AGENTS.md).

### Key components

| File | Purpose |
|---|---|
| `app/page.tsx` | Top-level state owner: connection, history, sidebar collapse, race-condition guard, pre-flight validation |
| `components/Sidebar.tsx` | Collapsible sidebar (280 px ↔ 56 px rail) with mode toggle, search, history, theme toggle, connection footer |
| `components/QueryEditor.tsx` | SQL editor with syntax-highlight overlay, line numbers, Tab→2-space, platform-aware shortcut hint, sample-button confirmation |
| `components/ResultsPanel.tsx` | Plan / Rules / Rewrite / Benchmark tabs |
| `components/PlanFlowchart.tsx` | SVG hierarchical tree of the plan with subtree-width centering |
| `components/ConnectionModal.tsx` | Oracle credentials + test-connection probe |
| `components/ErrorModal.tsx` | Centered, portal-rendered error dialog |
| `components/ChatPanel.tsx` | Database Assistant chat (DB-only scope) |
| `lib/optimize.ts` | Frontend orchestrator — chains the 5 routes |
| `lib/oracle.ts` | `openConnection`, `safeClose`, `readClob`, `parseOracleJson`, `OracleRouteError` |
| `lib/llm.ts` | Provider abstraction (Gemini / Anthropic), system prompts, structured-JSON schema |

### Helper scripts (Node, against a live DB)

`frontend/scripts/` ships installers that recompile a single PL/SQL package without re-running the whole SQL*Plus install:

```bash
node scripts/install-phase1.mjs            <user> <pwd> <host:port/service>
node scripts/install-rule-engine.mjs       <user> <pwd> <host:port/service>
node scripts/install-validation-engine.mjs <user> <pwd> <host:port/service>
node scripts/check-plan.mjs                <user> <pwd> <host:port/service>
```

---

## Oracle backend

### Direct PL/SQL usage

```sql
-- Phase 1 — analyze a query
DECLARE l_report CLOB;
BEGIN
  query_analyzer_pkg.analyze_query(
    p_query  => 'SELECT * FROM orders WHERE user_id = 10',
    p_report => l_report
  );
  DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 4000));
END;
/

-- Phase 2 — Phase 1 + rule engine in one call
DECLARE l_report CLOB;
BEGIN
  rule_engine_pkg.apply_rules(
    p_query  => 'SELECT * FROM orders WHERE user_id = 10',
    p_report => l_report
  );
  DBMS_OUTPUT.PUT_LINE(SUBSTR(l_report, 1, 4000));
END;
/

-- Phase 4 — validate AI candidates against the original
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
/
```

### Output format (Phase 1 success)

```json
{
  "status": "SUCCESS",
  "version": "1.0.0",
  "execution_time_ms": 42.5,
  "query": "SELECT * FROM orders WHERE user_id = 10",
  "analysis": {
    "scan_type": "FULL TABLE SCAN",
    "cost": 125,
    "rows": 10000,
    "index_used": false,
    "join_type": "NONE",
    "access_path": "TABLE ACCESS FULL",
    "observations": ["Full table scan detected", "Potential missing index on filtered column"]
  }
}
```

Any error path returns `{"status":"ERROR","message":"…"}`.

### Phase 2 rule catalogue (14 rules)

**Enhanced (7):** SELECT_STAR_DETECTED · FULL_TABLE_SCAN_DETECTED · MISSING_INDEX_ON_FILTER · FUNCTION_ON_INDEXED_COLUMN · SUBQUERY_CANDIDATE_FOR_JOIN · UNNECESSARY_DISTINCT · CARTESIAN_JOIN_DETECTED

**Deep-analysis (3):** AGGREGATE_INDEX_HINT · NESTED_VIEW_INEFFICIENCY · TABLE_CONTEXT_SUMMARY

**Precision (4):** HIGH_COST_PLAN · IMPLICIT_TYPE_CONVERSION · STALE_STATISTICS · OR_CHAIN_INSTEAD_OF_IN

`FULL_TABLE_SCAN_DETECTED` skips DUAL and tiny tables (≤ 256 rows, ≤ 2 blocks) — full scan is the optimal access path there, so flagging would be noise.

### Test suites

```sql
@test/01_setup_sample_data.sql
@test/02_test_analyze_query.sql        -- Phase 1 functional (7 cases)
@test/03_test_error_handling.sql       -- Phase 1 errors (9 cases)
@test/04_test_rule_engine.sql          -- Phase 2
@test/05_test_validation_engine.sql    -- Phase 4 (8 cases)
```

Uninstall with `@sql/04_drop_all.sql`.

---

## API reference

| Route | Method | Body | Returns |
|---|---|---|---|
| `/api/oracle/test-connection` | POST | `{host, port, serviceName, user, password}` | `{ok, user, db}` or `{ok:false, error}` |
| `/api/oracle/analyze` | POST | `{connection, query}` | Phase 1 + 2 JSON; `raw_plan` text appended |
| `/api/oracle/plan-tree` | POST | `{connection, query}` | `{nodes: PlanNode[]}` for the flowchart |
| `/api/oracle/schema` | POST | `{connection, tables: string[]}` | `{tables: TableSchemaMeta[]}` |
| `/api/oracle/benchmark` | POST | `{connection, originalQuery, optimizedQueries[], iterations}` | Phase 4 JSON |
| `/api/analyze` | POST | `{query, plan?, rules?, schema?, indexes?}` | `AIAnalysis` (decision, confidence, issues, optimized_queries[], explanation) |
| `/api/chat` | POST | `{messages: ChatMessage[]}` | `{content, provider, model}` |

Any route returns HTTP `429` with `code: "RATE_LIMIT"` and a friendly message when the LLM provider's free-tier quota is exhausted, instead of dumping the raw SDK exception JSON.

---

## Project structure

```
Query_Optimizer/
├── BUGS.md                              # Running log of every bug + fix (#1 onwards)
├── CLAUDE.md                            # Repo guidance for Claude Code
├── README.md                            # This file
│
├── docs/
│   └── phase1_spec.md                   # Phase 1 specification
│
├── sql/                                 # PL/SQL packages + tables
│   ├── 01_create_tables.sql             # QUERY_PLAN_LOG
│   ├── 02_create_package_spec.sql       # QUERY_ANALYZER_PKG spec
│   ├── 03_create_package_body.sql       # QUERY_ANALYZER_PKG body
│   ├── 04_drop_all.sql                  # Cleanup script
│   ├── 05_create_phase2_tables.sql      # OPTIMIZATION_RULES, QUERY_RULE_RESULTS
│   ├── 06_seed_optimization_rules.sql   # Seed the 14-rule catalogue
│   ├── 07_create_rule_engine_spec.sql   # RULE_ENGINE_PKG spec
│   ├── 08_create_rule_engine_body.sql   # RULE_ENGINE_PKG body
│   ├── 09_create_benchmark_table.sql    # QUERY_BENCHMARK
│   ├── 10_create_validation_package_spec.sql   # VALIDATION_ENGINE_PKG spec
│   └── 11_create_validation_package_body.sql   # VALIDATION_ENGINE_PKG body
│
├── scripts/
│   ├── install.sql                      # Phase 1 installer (SQL*Plus)
│   ├── install_phase2.sql               # Phase 2 installer
│   └── install_phase4.sql               # Phase 4 installer
│
├── test/
│   ├── 01_setup_sample_data.sql
│   ├── 02_test_analyze_query.sql
│   ├── 03_test_error_handling.sql
│   ├── 04_test_rule_engine.sql
│   └── 05_test_validation_engine.sql
│
└── frontend/                            # Next.js 16 / React 19 UI
    ├── app/
    │   ├── api/
    │   │   ├── analyze/route.ts         # AI rewrite (Gemini / Anthropic)
    │   │   ├── chat/route.ts            # DB-only assistant chat
    │   │   └── oracle/
    │   │       ├── analyze/route.ts        # Phase 1 + 2
    │   │       ├── benchmark/route.ts      # Phase 4
    │   │       ├── plan-tree/route.ts      # Flowchart nodes
    │   │       ├── schema/route.ts         # Table / index / column metadata
    │   │       └── test-connection/route.ts
    │   ├── globals.css
    │   ├── layout.tsx
    │   └── page.tsx                     # Top-level state owner
    │
    ├── components/                      # See "Frontend" section above
    ├── lib/
    │   ├── llm.ts                       # Provider abstraction + prompts
    │   ├── optimize.ts                  # Frontend orchestrator
    │   └── oracle.ts                    # Connection + CLOB helpers
    └── scripts/                         # Node-based PL/SQL deployers
```

---

## Bug log

Every bug found and fixed lives in [BUGS.md](BUGS.md) at the repo root. Numbers are monotonic and never reused. Format: severity, area, repro, root cause, fix, files, verification. The log is the source of truth for "why does this code look the way it does" — comments in code reference these IDs sparingly to keep the codebase clean.

---

## Roadmap

| Phase | Status |
|---|---|
| **1** — DB-native analysis engine | ✅ Complete |
| **2** — Rule engine (14 rules) + index recommendations | ✅ Complete |
| **3** — AI rewrite (Gemini default, Anthropic optional) | ✅ Complete |
| **4** — Validation + benchmark engine | ✅ Complete |
| **Bridge** — full UI ↔ Oracle ↔ AI pipeline live | ✅ Complete |

---

## License

Internal project.
