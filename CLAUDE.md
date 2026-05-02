# CLAUDE.md

Guidance for Claude Code (claude.ai/code) when working in this repository.

## Project Overview

AI-powered SQL Query Optimizer with three layers, all wired live end-to-end:

- **Oracle backend** — three PL/SQL packages (`QUERY_ANALYZER_PKG`, `RULE_ENGINE_PKG`, `VALIDATION_ENGINE_PKG`). Analysis is non-destructive: `EXPLAIN PLAN`, set comparison via `MINUS`, and timing via `SELECT COUNT(*) FROM (...)`. Never executes the user's query at scale.
- **Next.js bridge** — Route Handlers in `frontend/app/api/` that talk to Oracle via `oracledb` (thin mode) and to the LLM provider via the `@google/genai` or `@anthropic-ai/sdk` SDK.
- **Next.js 16 / React 19 / TypeScript UI** — `frontend/components/` with a sidebar (collapsible to a 56 px rail), a SQL editor, and a tabbed results panel (Plan / Rules / Rewrite / Benchmark).

The full pipeline runs from a single click: Oracle EXPLAIN PLAN → rule engine → schema/index gathering → AI rewrite → MINUS validation → timing benchmark → UI.

## Commands

### Frontend

```bash
cd frontend
npm run dev      # Dev server at http://localhost:3000
npm run build    # Production build
npm run lint     # ESLint
```

### Oracle backend (SQL*Plus or SQL Developer)

```sql
@scripts/install.sql           -- Phase 1
@scripts/install_phase2.sql    -- Phase 2 (requires Phase 1)
@scripts/install_phase4.sql    -- Phase 4 (requires Phase 1 + 2)

@test/01_setup_sample_data.sql
@test/02_test_analyze_query.sql        -- Phase 1 functional
@test/03_test_error_handling.sql       -- Phase 1 errors
@test/04_test_rule_engine.sql          -- Phase 2
@test/05_test_validation_engine.sql    -- Phase 4

@sql/04_drop_all.sql                   -- Uninstall
```

**Prereqs:** Oracle DB 12c+; `SET SERVEROUTPUT ON SIZE UNLIMITED` before package calls.

### Helper scripts (Node, against a live DB)

`frontend/scripts/` has `oracledb`-based deployers and probes used during this project's bug-hunt sessions:

```bash
node scripts/install-phase1.mjs        <user> <pwd> <host:port/service>
node scripts/install-rule-engine.mjs   <user> <pwd> <host:port/service>
node scripts/install-validation-engine.mjs <user> <pwd> <host:port/service>
node scripts/check-plan.mjs            <user> <pwd> <host:port/service>
node scripts/probe-phase1.mjs          <user> <pwd> <host:port/service>
```

Use these to recompile a single package against an already-running database without re-running the full SQL*Plus install.

## Architecture

### Oracle backend (`sql/`)

```
QUERY_ANALYZER_PKG (Phase 1)        sql/02–03
  ANALYZE_QUERY(p_query, p_report OUT CLOB)
    → validate_query()              -- rejects NULL, non-SELECT, DML/DDL
    → EXPLAIN PLAN FOR <query>      -- dynamic SQL
    → DBMS_XPLAN.DISPLAY()          -- plan text
    → PARSE_PLAN()                  -- scan type / cost / cardinality / joins / filters
    → INSERT into QUERY_PLAN_LOG    -- audit trail
    → returns JSON CLOB

RULE_ENGINE_PKG (Phase 2)           sql/05–08
  APPLY_RULES(p_query, p_report OUT CLOB)
    → calls Phase 1 first; bails if Phase 1 status = ERROR
    → runs 14 rules (7 enhanced + 3 deep + 4 precision)
    → persists per-rule rows in QUERY_RULE_RESULTS
    → returns JSON with rule_summary + triggered_rules[]

VALIDATION_ENGINE_PKG (Phase 4)     sql/09–11
  VALIDATE_AND_BENCHMARK(p_original_query, p_optimized_queries, p_iterations, p_result OUT CLOB)
    → policy check + symmetric MINUS comparison vs original
    → SELECT COUNT(*) FROM (<query>) timing, 1–5 iterations
    → persists QUERY_BENCHMARK rows
    → winner = lowest avg_exec_ms; decision = ORIGINAL_FASTEST | OPTIMIZED_SELECTED | NO_VALID_QUERY
```

Output is always a JSON CLOB — `{"status":"SUCCESS",…}` or `{"status":"ERROR","message":"…"}`. Phase 2 returns `{"rule_summary":{…}, "triggered_rules":[…]}`. Phase 4 returns `{"decision":"…", "winner":"…", "speedup_factor":…, "benchmarks":[…]}`.

### Next.js Route Handlers (`frontend/app/api/`)

| Route | Calls | Purpose |
|---|---|---|
| `oracle/test-connection` | `oracledb.getConnection` + `SELECT USER, DB_NAME` | Used by ConnectionModal's "Test connection" button |
| `oracle/analyze` | `RULE_ENGINE_PKG.APPLY_RULES` | Phase 1 + 2 in one round trip |
| `oracle/plan-tree` | `EXPLAIN PLAN` + reads `PLAN_TABLE` directly | Returns hierarchical nodes for the flowchart |
| `oracle/schema` | `ALL_TABLES`, `ALL_INDEXES`, `ALL_TAB_COL_STATISTICS`, … | Per-table rows / blocks / PK / FK / indexes / per-column NDV. Fed to the LLM as grounding context |
| `oracle/benchmark` | `VALIDATION_ENGINE_PKG.VALIDATE_AND_BENCHMARK` | Phase 4 |
| `analyze` | `generateRewrite` in `lib/llm.ts` | AI rewrite. Returns `AIAnalysis` |
| `chat` | `generateChatReply` in `lib/llm.ts` | Database Assistant chat (multi-turn, stateless route) |

`lib/oracle.ts` centralises connection handling: `openConnection`, `safeClose`, `readClob`, `parseOracleJson`, and an `OracleRouteError` with status-code routing for clean 503 vs 400 responses.

`lib/llm.ts` picks `gemini` or `anthropic` based on env (`LLM_PROVIDER` override, otherwise auto-detect by which key is set; Gemini wins when both are present because it's the free path). Two prompt sets:
- `SYSTEM_PROMPT` for `generateRewrite` — strict Oracle dialect rules (A–I), self-check checklist, structured-JSON output schema
- `CHAT_SYSTEM_PROMPT` for `generateChatReply` — DB-only scope guardrail; off-topic questions get a polite refusal

Both routes detect 429 / quota / `RESOURCE_EXHAUSTED` errors and return a friendly `code: "RATE_LIMIT"` payload instead of the raw SDK JSON.

### Frontend UI (`frontend/`)

Top-level entry: `app/page.tsx` (~250 lines). Owns:
- Connection state (sessionStorage `querymind.connection.v2`)
- Optimize history (sessionStorage `querymind.history.v1`, capped at 30 entries with the full `OptimizeResult`)
- Sidebar collapse state (sessionStorage `querymind.sidebar.collapsed.v1`)
- Race-condition guard via `runIdRef` — newer Optimize runs invalidate older awaited responses
- Pre-flight checks: empty editor, comment-only content, `{your_table}`-style placeholders all short-circuit before the network call

Components:
- `Sidebar.tsx` — two layouts (full 280 px / rail 56 px) inside a single `<aside>` that animates `width` 220 ms; logo doubles as the toggle. History list + search hide on the rail.
- `QueryEditor.tsx` — textarea + transparent-text overlay for SQL highlighting; gutter; `useShortcutKeyLabel()` hook chooses ⌘ for Mac and Ctrl elsewhere; sample buttons confirm before overwriting user edits.
- `ResultsPanel.tsx` — Plan / Rules / Rewrite / Benchmark tabs. Plan tab has a Flowchart/Table view toggle and a Fullscreen modal portaled to `document.body`. `Stat` pill renders an arrow only when `before !== after`.
- `PlanFlowchart.tsx` — SVG hierarchical tree with subtree-width centering and orthogonal connectors; colour-coded nodes (Root, Index access, Full scan, Join, Sort/aggregate, Pipeline).
- `ConnectionModal.tsx` — re-syncs form state with `current` prop on open; closes on Esc.
- `ErrorModal.tsx` — centered, portal-rendered, body-scroll-locked, Esc/click-outside dismiss.
- `ChatPanel.tsx` — wraps `/api/chat` calls; persists conversation to `querymind.chat.v1`; receives `clearSignal` from page so the sidebar's "New chat" button can reset it.

### Phase 2 — 14 rules

Catalogue of 14 rules (originally 7, expanded to 14 across the precision-tuning sessions):

**Enhanced (7):** SELECT_STAR_DETECTED · FULL_TABLE_SCAN_DETECTED · MISSING_INDEX_ON_FILTER · FUNCTION_ON_INDEXED_COLUMN · SUBQUERY_CANDIDATE_FOR_JOIN · UNNECESSARY_DISTINCT · CARTESIAN_JOIN_DETECTED

**Deep-analysis (3):** AGGREGATE_INDEX_HINT · NESTED_VIEW_INEFFICIENCY · TABLE_CONTEXT_SUMMARY

**Precision (4):** HIGH_COST_PLAN · IMPLICIT_TYPE_CONVERSION · STALE_STATISTICS · OR_CHAIN_INSTEAD_OF_IN

`FULL_TABLE_SCAN_DETECTED` skips DUAL and tiny tables (<= 256 rows, <= 2 blocks) — a full scan there is the optimal access path, so flagging it is noise.

### Phase 3 — AI rewrite

`lib/optimize.ts` orchestrates the round trip:
1. POST `/api/oracle/analyze` → Phase 1 + 2 results
2. POST `/api/oracle/plan-tree` → flowchart nodes
3. POST `/api/oracle/schema` for every `FROM` / `JOIN` table the regex extracts → per-column NDV, indexes, FKs
4. POST `/api/analyze` with the schema + rules + plan as grounding → AI rewrites
5. POST `/api/oracle/benchmark` with the AI candidates → Phase 4

Each step is best-effort: a failure earlier in the chain leaves later steps with their graceful empty states (e.g. AI failure → Rewrite tab shows "AI rewrite failed" with the friendly message, Benchmark tab shows "No benchmark data").

### Phase 4 — Validation + benchmark

`compare_result_sets` has three paths in [sql/11_create_validation_package_body.sql](sql/11_create_validation_package_body.sql):
- **STRICT** — `SELECT COUNT(*) FROM ((A MINUS B) UNION ALL (B MINUS A))`
- **ROW_COUNT** — fallback when MINUS fails (typically `ORA-00918` "column ambiguously defined" from `SELECT *` on joined tables); compares row counts only — weaker but actionable
- **FAILED** — both paths errored; candidate is rejected

The `BenchTab` UI surfaces this via per-row badges: `Identical` (green) / `Row count only` (warn) / `Differs` (red). Row counts come from Phase 4's `result_row_count`, NOT the optimizer's plan-cardinality estimate (which often diverges by orders of magnitude).

## Conventions

### BUGS.md is the running log

Every bug found and fixed in this project lives in [BUGS.md](BUGS.md) at the repo root. The format is:

```
## N. <Title>
- **Severity** — High | Medium | Low
- **Area** — Frontend / state | Backend / PL-SQL | Backend / API | …
- **Date fixed** — YYYY-MM-DD
- **Status** — ✅ Fixed | 🟡 In progress | 🔴 Open | ⚪ Withdrawn
- **Repro** — what the user did and what went wrong
- **Root cause** — why it broke
- **Fix** — what changed and why this approach
- **Files** — clickable links to the changed files
- **Verified** — how the fix was validated (Playwright run, recompile, etc.)
```

Numbers are **monotonic and never reused**. Append at the bottom; never renumber. When fixing a bug, add an entry. The convention is also recorded in `MEMORY.md` so future sessions follow it.

### sessionStorage keys

| Key | Purpose | Capped at |
|---|---|---|
| `querymind.connection.v2` | Oracle creds (per tab) | n/a |
| `querymind.history.v1` | Optimize results with full `OptimizeResult` | 30 entries |
| `querymind.chat.v1` | Database Assistant turns | 100 messages |
| `querymind.sidebar.collapsed.v1` | Rail vs full sidebar | n/a |

Per-tab (sessionStorage, not localStorage) so opening a new tab gives a fresh session.

### Race-condition guard

When the user re-runs Optimize while the previous request is in flight, the older response would otherwise overwrite the newer state. Pattern in `runOptimize` in `app/page.tsx`:

```tsx
const myRunId = ++runIdRef.current;
// … awaits …
if (myRunId !== runIdRef.current) return;  // newer run won
```

## Next.js version warning

This project uses **Next.js 16.2.3 with React 19** — breaking changes vs the public training corpus. Before writing frontend code, read the relevant guide in `frontend/node_modules/next/dist/docs/`. Heed deprecation notices. (See `frontend/AGENTS.md`.)

## Roadmap

| Phase | Status |
|---|---|
| Phase 1 — DB-native analysis | Complete |
| Phase 2 — Rule engine (14 rules) + index recommendations | Complete |
| Phase 3 — AI rewrite (Gemini default, Anthropic optional) | Complete |
| Phase 4 — Validation + benchmark engine | Complete |
| Bridge — full UI ↔ Oracle ↔ AI pipeline live | Complete |
