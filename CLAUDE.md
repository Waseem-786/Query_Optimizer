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
| `analyze` | `generateRewrite` in `lib/llm.ts` | AI rewrite. Returns `AIAnalysis` (decision, confidence, issues, optimized_queries, explanation, recommended_indexes) |
| `chat` | `generateChatReplyStream` in `lib/llm.ts` | Database Assistant chat. **Streams** NDJSON events (`meta` / `delta` / `done` / `error`) — UI renders tokens as they arrive |
| `llm-status` | `providerStatus()` in `lib/llm.ts` | Reports which LLM providers are configured. Used by the model-picker UI to render availability dots |

`lib/oracle.ts` centralises connection handling: `openConnection`, `safeClose`, `readClob`, `parseOracleJson`, and an `OracleRouteError` with status-code routing for clean 503 vs 400 responses.

`lib/llm.ts` picks `gemini`, `anthropic`, or `claude-code` based on (1) explicit override from the request body via the UI picker, (2) `LLM_PROVIDER` env, (3) auto-detect by which API key is present. Gemini wins ties because it's the free path. Three prompt sets:
- `SYSTEM_PROMPT` for `generateRewrite` — strict Oracle dialect rules (A–I), self-check checklist, structured-JSON output schema (includes optional `recommended_indexes: string[]`)
- `CHAT_SYSTEM_PROMPT` for chat — DB-only scope guardrail; off-topic questions get a polite refusal
- The same prompts are reused for the streaming chat path (`generateChatReplyStream`)

`claude-code` uses `@anthropic-ai/claude-agent-sdk` which spawns the local `claude` CLI for OAuth — no separate API key needed if Claude Code is installed and logged in. Significantly slower than Gemini (~5 s spawn + minutes of model time) but uses the user's existing subscription.

Both LLM routes detect 429 / quota / `RESOURCE_EXHAUSTED` errors and return a friendly `code: "RATE_LIMIT"` payload instead of the raw SDK JSON.

### Frontend UI (`frontend/`)

Top-level entry: `app/page.tsx`. Owns:
- Connection state (sessionStorage `querymind.connection.v2`)
- Unified history (sessionStorage `querymind.history.v1`, capped at 30 entries). Each entry is either an Optimize run (full `OptimizeResult`) or a chat conversation (`messages[]`). The sidebar filters by current mode.
- LLM provider preference (sessionStorage `querymind.llm.provider.v1`) via the `useLlmProvider()` hook in `lib/use-llm-provider.ts`
- Sidebar collapse state (sessionStorage `querymind.sidebar.collapsed.v1`)
- Current optimize pipeline phase (used to drive the real progress indicator — see below)
- Race-condition guard via `runIdRef` — newer Optimize runs invalidate older awaited responses
- Pre-flight checks: empty editor, comment-only content, `{your_table}`-style placeholders all short-circuit before the network call
- `chatLoadKey` counter — bumped on deliberate chat switches (sidebar click / "New chat"); ChatPanel is keyed off it so React remounts with fresh state. Not bumped during normal first-send, so the new chat doesn't unmount mid-stream.

Components:
- `Sidebar.tsx` — two layouts (full 280 px / rail 56 px) inside a single `<aside>` that animates `width` 220 ms; logo doubles as the toggle. History list + search hide on the rail. The trash icon on an active history row deselects the panel + bumps `chatLoadKey` so the now-deleted chat doesn't keep rendering.
- `QueryEditor.tsx` — textarea + transparent-text overlay for SQL highlighting; gutter; `useShortcutKeyLabel()` hook chooses ⌘ for Mac and Ctrl elsewhere; sample buttons confirm before overwriting user edits.
- `ResultsPanel.tsx` — **five** tabs: Plan / Rules / Rewrite / Recommendation / Benchmark. Plan tab has a Flowchart/Table view toggle and a Fullscreen modal portaled to `document.body`. Rewrite tab shows pure SQL only (no comments, no markdown). Recommendation tab renders the AI's diagnosis (issues), rationale (why_inefficient / why_better), trade-offs, and **Suggested indexes** section with copy-button per DDL. `Stat` pill renders an arrow only when `before !== after`.
- `PlanFlowchart.tsx` — SVG hierarchical tree with subtree-width centering and orthogonal connectors; colour-coded nodes (Root, Index access, Full scan, Join, Sort/aggregate, Pipeline).
- `ConnectionModal.tsx` — re-syncs form state with `current` prop on open; closes on Esc.
- `ErrorModal.tsx` — centered, portal-rendered, body-scroll-locked, Esc/click-outside dismiss.
- `SettingsModal.tsx` — gear-icon modal showing the three providers (Claude Code / Gemini / Anthropic API) with availability dots from `/api/llm-status`. Pairs with the compact `ProviderPicker.tsx` dropdown in the chat header — both consume the same `useLlmProvider()` state.
- `ChatPanel.tsx` — **controlled** message list; parent (`page.tsx`) owns the per-chat `messages[]` and routes updates via `(chatId, messages) => …`. Streams `/api/chat` NDJSON; aborts in-flight fetch on unmount via `AbortController` so switching chats can't corrupt the wrong one. Renders assistant text via `MarkdownRender` (h1–h4, bold/italic, inline + fenced code, GFM tables, lists, links). Mid-stream messages show a blinking accent caret; pre-first-token shows a three-dot typing indicator.
- `MarkdownRender.tsx` — wraps `react-markdown` + `remark-gfm`. Fenced ```` ```sql ```` blocks route through `SqlBlock` so chat SQL gets the same keyword/string highlighting as the Rewrite tab; other languages render as plain `<pre>`. Every fenced block gets a Copy button in its header strip.

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
4. POST `/api/analyze` with the schema + rules + plan as grounding → AI rewrites + `recommended_indexes`
5. POST `/api/oracle/benchmark` with the AI candidates → Phase 4

Each step is best-effort: a failure earlier in the chain leaves later steps with their graceful empty states (e.g. AI failure → Rewrite tab shows "AI rewrite failed" with the friendly message, Benchmark tab shows "No benchmark data").

`optimizeQuery()` accepts an optional `onPhase(phase)` callback that fires before each network call (`"analyze" | "plan-tree" | "schema" | "ai" | "benchmark" | "done"`). The `RunningState` component in `ResultsPanel.tsx` uses this to render a real progress checklist — replaces the old timer-based stub that sprinted through all five steps in 1.5 s while the AI step still had minutes to go.

**Suggested indexes** (Recommendation tab): the AI's `recommended_indexes` field is merged with the rule engine's deterministic DDL output (`MISSING_INDEX_ON_FILTER` / `AGGREGATE_INDEX_HINT`) in `mergeIndexRecs()` — dedupes by normalised text, drops anything that doesn't start with `CREATE [UNIQUE|BITMAP]? INDEX`, caps at 10 entries. Section only renders when the merged list is non-empty.

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
| `querymind.history.v1` | Unified history — Optimize runs (full `OptimizeResult`) AND chat conversations (`messages[]`), distinguished by `mode` | 30 entries total |
| `querymind.llm.provider.v1` | Active LLM provider: `claude-code` \| `gemini` \| `anthropic` | n/a |
| `querymind.sidebar.collapsed.v1` | Rail vs full sidebar | n/a |

Per-tab (sessionStorage, not localStorage) so opening a new tab gives a fresh session. The old `querymind.chat.v1` singleton-chat key was retired when each conversation became its own history entry (Bugs #32–#35).

### Race-condition guard

When the user re-runs Optimize while the previous request is in flight, the older response would otherwise overwrite the newer state. Pattern in `runOptimize` in `app/page.tsx`:

```tsx
const myRunId = ++runIdRef.current;
// … awaits …
if (myRunId !== runIdRef.current) return;  // newer run won
```

A similar pattern exists in `ChatPanel.tsx` but uses a different mechanism: each `send()` creates its own `AbortController`, which the unmount-cleanup effect aborts. Combined with a stable `chatIdRef` per ChatPanel instance, an orphan stream that finishes after the user switched chats can't corrupt the now-active conversation (Bug #33).

## Next.js version warning

This project uses **Next.js 16.2.3 with React 19** — breaking changes vs the public training corpus. Before writing frontend code, read the relevant guide in `frontend/node_modules/next/dist/docs/`. Heed deprecation notices. (See `frontend/AGENTS.md`.)

## Roadmap

| Phase | Status |
|---|---|
| Phase 1 — DB-native analysis | Complete |
| Phase 2 — Rule engine (14 rules) + index recommendations | Complete |
| Phase 3 — AI rewrite + Recommendation tab (Claude Code default, Gemini + Anthropic API optional) | Complete |
| Phase 4 — Validation + benchmark engine | Complete |
| Bridge — full UI ↔ Oracle ↔ AI pipeline live | Complete |
| Streaming chat — NDJSON streaming + markdown rendering | Complete |
| Multi-chat history — each conversation gets its own sidebar entry | Complete |
