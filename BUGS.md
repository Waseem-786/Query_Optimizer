# Bug log — Query_Optimizer

Running log of every issue found and fixed in this project. New entries are appended at the bottom; numbers are monotonic and never reused. Status conventions: ✅ Fixed · 🟡 In progress · 🔴 Open · ⚪ Withdrawn.

| Conv | Where to put it |
|---|---|
| Frontend / UX, layout, accessibility | `frontend/...` |
| Frontend / state, race conditions, persistence | `frontend/...` |
| Backend / API routes (Next.js Route Handlers) | `frontend/app/api/...` |
| Backend / PL/SQL packages | `sql/...` |
| Infra / deployment / scripts | `frontend/scripts/...`, `scripts/...` |

---

## 1. Empty-query click was silent
- **Severity** — Medium
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Open editor, clear all text, press `Cmd/Ctrl+Enter`. Old behaviour: nothing happened, no feedback.
- **Root cause** — `runOptimize` early-returned with `if (!sql.trim() || busy) return;` and never surfaced any UI message.
- **Fix** — Show a visible error: `setError("Paste a query into the editor first.")`. The Optimize button is also already disabled when textarea is empty, but the keyboard shortcut bypassed that.
- **Files** — [frontend/app/page.tsx](frontend/app/page.tsx)

## 2. Starter SQL referenced HR tables that don't exist on Flexcube
- **Severity** — High
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Fresh load, click Optimize. Old behaviour: Oracle returned `ORA-00942: table or view does not exist` because the starter referenced `employees` / `departments` (HR schema), which Flexcube DBs don't have.
- **Root cause** — Hard-coded `STARTER_SQL` constant assumed HR schema.
- **Fix** — Replaced with a comment-only placeholder so the user knows to paste their own query.
- **Files** — [frontend/app/page.tsx](frontend/app/page.tsx)

## 3. Sample buttons referenced HR tables
- **Severity** — High
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Click "Slow JOIN", "Subquery → JOIN", or "SELECT *" and then Optimize. Same `ORA-00942`.
- **Root cause** — Same root cause as #2 — `SAMPLES` array used HR tables.
- **Fix** — Replaced sample SQL with **schema-agnostic anti-pattern templates** that use `{your_table}` / `{your_col}` placeholders. Each illustrates one anti-pattern the rule engine targets.
- **Files** — [frontend/components/QueryEditor.tsx](frontend/components/QueryEditor.tsx)

## 4. Default `activeId="h1"` highlighted a fake history entry
- **Severity** — Low
- **Area** — Frontend / state
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Fresh load. "Slow employee search" was highlighted in the sidebar but pointed to nothing real.
- **Root cause** — `useState<string | null>("h1")` plus seeded fake `HistoryItem` objects.
- **Fix** — `activeId` defaults to `null`. (Combined with #5.)
- **Files** — [frontend/app/page.tsx](frontend/app/page.tsx)

## 5. Sidebar shipped with three fake history items
- **Severity** — Medium
- **Area** — Frontend / state
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Fresh load. Sidebar showed "Slow employee search", "How do partitioned indexes work?", "Recent orders join cleanup" — none real.
- **Root cause** — Hard-coded seed array in `Home`.
- **Fix** — Empty `[]` seed. Real entries appear only after a real Optimize call.
- **Files** — [frontend/app/page.tsx](frontend/app/page.tsx)

## 6. Race condition — stale optimize response could overwrite fresh state
- **Severity** — High
- **Area** — Frontend / concurrency
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Click Optimize, immediately edit the SQL while the request is in flight. When the original response arrived, it overwrote the editor's "current" state — leaving the user looking at a Plan that no longer matched the SQL in the editor.
- **Root cause** — `runOptimize` had no way to detect that a newer run had started after the awaited request.
- **Fix** — Added a `runIdRef = useRef(0)` counter. Every call `++runIdRef.current` and captures `myRunId`. After the await: `if (myRunId !== runIdRef.current) return;` — newest run wins, stale responses are dropped.
- **Files** — [frontend/app/page.tsx](frontend/app/page.tsx)

## 7. Connection state lost on page refresh / HMR
- **Severity** — High
- **Area** — Frontend / state
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Connect, refresh page (or trigger HMR rebuild). Old behaviour: connection gone, sidebar shows "No connection".
- **Root cause** — Connection lived only in React state.
- **Fix** — Persist to `sessionStorage` under `querymind.connection.v2` on connect; restore on mount via `useEffect`. SessionStorage is per-tab and clears on tab close, matching the modal's "credentials kept for this session only" copy.
- **Files** — [frontend/app/page.tsx](frontend/app/page.tsx)

## 8. Chat Panel returned a hardcoded fake answer
- **Severity** — High
- **Area** — Frontend / honesty
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Switch to Assistant tab, ask anything. Every question got the same canned response about `UPPER()`.
- **Root cause** — `send()` returned a hardcoded message after a 900ms fake delay; no LLM backend call.
- **Fix** — Replaced with an honest "not yet wired to LLM backend" message + pointer to the working Optimize tab.
- **Files** — [frontend/components/ChatPanel.tsx](frontend/components/ChatPanel.tsx)

## 9. History click only highlighted — never restored the saved query/result
- **Severity** — High
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Run an Optimize, then click that history entry. Old behaviour: highlight changed, nothing else loaded.
- **Root cause** — `onSelect={setActiveId}` only updated the highlight; `HistoryItem` carried no SQL or result data.
- **Fix** — Extended history items to carry `sql` + `result` (the full `OptimizeResult`). New `selectHistory(id)` callback restores both. Clicking a prior entry now reloads the editor *and* the Plan / Rules / Rewrite / Benchmark tabs.
- **Files** — [frontend/app/page.tsx](frontend/app/page.tsx)

## 10. "Demo mode (no DB)" footer was misleading
- **Severity** — Low
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Disconnect, look at editor footer. Old text said "Demo mode (no DB)" — the site has no demo mode anymore.
- **Root cause** — Stale label from earlier prototype.
- **Fix** — Changed to `"Disconnected — connect to run analysis"`.
- **Files** — [frontend/components/QueryEditor.tsx](frontend/components/QueryEditor.tsx)

## 11. Inline error banner was too easy to miss
- **Severity** — Medium
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Submit a query that fails (e.g. `select * from employee_temp`). Old behaviour: a thin red strip appeared at the top of the right pane, partially under the tab bar — hard to see at smaller widths.
- **Root cause** — Error rendered as a static banner inside the result-pane column, not as a global notification.
- **Fix** — New [components/ErrorModal.tsx](frontend/components/ErrorModal.tsx). Centered popup, portal-rendered to `document.body` (so ancestor transforms can't clip it), max-width 460 px, dark backdrop, body-scroll lock, Esc/click-outside dismiss. Shows error message + the offending query in a "Details" block + a "Common causes" hint.
- **Files** — [frontend/components/ErrorModal.tsx](frontend/components/ErrorModal.tsx) (new), [frontend/app/page.tsx](frontend/app/page.tsx)

## 12. Rule engine returned SUCCESS even when Phase 1 errored
- **Severity** — High
- **Area** — Backend / PL-SQL
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — `select * from employee_temp` (table doesn't exist). Old behaviour: phantom result `"SUCCESS · 1 finding · 13 ms · No execution plan available"` — looks like the analysis worked but it didn't.
- **Root cause** — `RULE_ENGINE_PKG.APPLY_RULES` called `query_analyzer_pkg.analyze_query`, which logged status='ERROR' to `query_plan_log` and never raised. APPLY_RULES then ignored the row's status and continued running text-only rules (e.g. `SELECT_STAR_DETECTED`) against the raw SQL — emitting findings for a query that hadn't even parsed.
- **Fix** — In `APPLY_RULES`, after `analyze_query` returns, read `status` + `error_message` from the just-inserted `query_plan_log` row. If `status='ERROR'`, immediately call `build_error_response(...)` and `RETURN`, so the route propagates a 400 with the real Oracle error to the frontend (where the new ErrorModal shows it cleanly).
- **Files** — [sql/08_create_rule_engine_body.sql](sql/08_create_rule_engine_body.sql)

---

<!-- Append new entries below. Numbering continues; never reuse. -->

## 13. Assistant tab was honest-but-empty (refused to answer); now wired to Gemini with DB-only scope
- **Severity** — Medium
- **Area** — Frontend / Backend
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed (supersedes the partial fix in #8)
- **Repro** — Open Assistant tab, ask any question. After bug #8 the panel honestly said "not yet wired" — useful as a placeholder but the feature was effectively dead.
- **Root cause** — `ChatPanel.send()` had no real LLM path; we hadn't built one yet.
- **Fix** — Three pieces:
  1. Added `generateChatReply(messages)` to [frontend/lib/llm.ts](frontend/lib/llm.ts) with a strict DB-only system prompt. Scope: SQL, RDBMS concepts, Oracle internals, query optimization, indexing, PL/SQL, schema design. Anything else (general programming, OS, web dev, personal advice) → polite refusal: *"I'm focused on databases and SQL. Ask me anything about Oracle, query optimization, schema design, or PL/SQL."* Format rules: Markdown, SQL in fenced ` ```sql ` blocks, concise technical answers. Both Gemini and Anthropic backends supported via the existing `pickProvider()` selector.
  2. New [frontend/app/api/chat/route.ts](frontend/app/api/chat/route.ts) — stateless POST endpoint. Caps history at the last 30 turns. Detects 429/quota errors and returns a friendlier "rate limit exceeded — wait a minute" message instead of raw SDK JSON.
  3. [frontend/components/ChatPanel.tsx](frontend/components/ChatPanel.tsx) — `send()` now calls `/api/chat` with the full message history; renders the reply; gracefully shows backend errors in the assistant slot.
- **Files** — [frontend/lib/llm.ts](frontend/lib/llm.ts), [frontend/app/api/chat/route.ts](frontend/app/api/chat/route.ts), [frontend/components/ChatPanel.tsx](frontend/components/ChatPanel.tsx)
- **Verified** — In-scope DB question returns a properly formatted reply with SQL fenced block in ~3.5 s. Off-scope verification deferred (Gemini daily free quota was exhausted at test time); guardrail prompt is locked in server-side and not bypassable from the client.

## 14. Chat conversation + optimize history were lost on page reload
- **Severity** — Medium
- **Area** — Frontend / state
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Send a few chat messages OR run a few Optimize calls. Refresh the page. Old behaviour: everything gone.
- **Root cause** — Both lived in React state only — same problem as connection persistence (see #7).
- **Fix** — Wired sessionStorage on both:
  - Chat: `querymind.chat.v1`. `loadStoredChat()` on mount; auto-save on every `messages` change (capped at last 100 turns); empty array removes the storage key entirely. New **Clear** button in the panel header to reset both UI and storage.
  - Optimize history: `querymind.history.v1`. Same pattern: load on mount, save on change (capped at last 30 entries since each can be tens of KB — the full `OptimizeResult` lives in the entry).
  - sessionStorage (per-tab, clears on tab close) chosen for consistency with the existing connection persistence (#7) and to match the modal's "credentials kept for this session only" copy.
- **Files** — [frontend/components/ChatPanel.tsx](frontend/components/ChatPanel.tsx), [frontend/app/page.tsx](frontend/app/page.tsx)
- **Verified** — Planted a chat message, reloaded, message restored. Same for optimize history. Clear button removes both from UI and storage.

## 15. Connection modal opened with empty fields even when a connection was saved
- **Severity** — High
- **Area** — Frontend / state
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Connect to Oracle (so the connection footer reads "Connected FLEXCUBE@…"), then click that footer to edit. Old behaviour: every input field was blank, only placeholder text visible. To save anything you had to retype the whole connection.
- **Root cause** — `useState<ConnectionInfo>({ user: current?.user ?? "", … })` runs the initializer once at first mount. When the page restored `current` from sessionStorage *after* mount, the form state was never re-synced, so the modal kept showing the empty defaults forever.
- **Fix** — Added a `useEffect([open, current])` in [ConnectionModal](frontend/components/ConnectionModal.tsx) that resets `form` to the latest `current` every time the modal opens. Editing now starts from the saved values.
- **Files** — [frontend/components/ConnectionModal.tsx](frontend/components/ConnectionModal.tsx)
- **Verified** — Reopened modal in Playwright; fields show `FLEXCUBE / 172.20.3.77 / 1521 / FCUBS` instead of placeholders.

## 16. Connection modal didn't close on Escape
- **Severity** — Low
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Open the connection modal, press Esc. Old behaviour: modal stayed open. ErrorModal and PlanFlowchartModal both close on Esc, so the inconsistency was confusing.
- **Root cause** — No keyboard handler was attached. Backdrop click and the X button worked; Escape was simply not wired.
- **Fix** — Added the same `useEffect` Esc-listener pattern used in ErrorModal: registers `keydown` on mount, removes on unmount, ignores when `open=false`.
- **Files** — [frontend/components/ConnectionModal.tsx](frontend/components/ConnectionModal.tsx)
- **Verified** — Esc dismisses the modal in Playwright.

## 17. AI rewrite tab dumped raw Gemini quota JSON when free-tier limit was hit
- **Severity** — Medium
- **Area** — Backend / API
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Run an Optimize after Gemini's daily free-tier quota is exhausted. Old behaviour: the Rewrite tab showed something like `{"error":{"code":429,"message":"You exceeded your current quota..."}` literally dumped into the SQL preview.
- **Root cause** — `/api/analyze` (unlike `/api/chat`, fixed in #13) had no special handling for 429/quota errors — it just stringified the SDK exception and returned 500.
- **Fix** — Added the same regex check (`/429|quota|rate.?limit|RESOURCE_EXHAUSTED/i`) used by `/api/chat`. Now returns HTTP 429 with `code: "RATE_LIMIT"` and a friendly message ("AI rewrite hit the free-tier rate limit. Wait ~1 minute…"). The Rewrite tab's `noRewrite` detector already converts that into a clean empty state.
- **Files** — [frontend/app/api/analyze/route.ts](frontend/app/api/analyze/route.ts)

## 18. Summary stat pill showed `(−0%)` for unchanged values and could render `(--X%)` on regression
- **Severity** — Low
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Run any query whose Phase 4 benchmark didn't pick a faster candidate (so before == after for cost/time). Old behaviour: pill rendered `Cost 2 → 2 (−0%)` — the `−0%` is meaningless visual noise. Worse, if `after > before` (a regression), the formula `(before-after)/before*100` produced a negative pct and the literal "−" prefix in JSX gave `(−−5%)`. Division-by-zero (`before=0`) would have rendered `(NaN%)` if Phase 4 reported zero.
- **Root cause** — The `Stat` helper unconditionally hard-coded `−` and never branched on the four cases (same / improvement / regression / zero baseline).
- **Fix** — Rewrote `Stat` to compute a `trend` of `improved` / `regressed` / `unchanged`, choose the pill colour from that, and only render a `pctText` for the first two cases. Regression now shows `(+P%)` in red with a 180°-rotated arrow; unchanged shows the values without any percentage.
- **Files** — [frontend/components/ResultsPanel.tsx](frontend/components/ResultsPanel.tsx)
- **Verified** — `SELECT * FROM dual` now displays `Cost 2 → 2` and `Time 106.18ms → 106.18ms` cleanly, no trailing percentage.

## 19. False-positive HIGH FULL TABLE SCAN finding on `DUAL` and other tiny tables
- **Severity** — Medium
- **Area** — Backend / PL-SQL
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Optimize `SELECT * FROM dual`. Old behaviour: the rule engine emitted `FULL_TABLE_SCAN_DETECTED` at HIGH severity with the recommendation "Add a B-tree index on the column(s) referenced in WHERE/JOIN predicates" — wholly absurd advice for the canonical 1-row singleton table.
- **Root cause** — `RULE_ENGINE_PKG.rule_full_table_scan` walked every `TABLE ACCESS FULL` row in PLAN_TABLE without filtering for tables where a full scan is genuinely cheapest. DUAL always full-scans (it's a single-block segment); tiny lookup tables (<256 rows, ≤2 blocks) are also better off full-scanning than indexed.
- **Fix** — In [sql/08_create_rule_engine_body.sql](sql/08_create_rule_engine_body.sql), added two `CONTINUE` guards in the FOR loop:
  1. Skip `UPPER(object_name) = 'DUAL'` outright.
  2. After `get_table_metrics`, skip rows where `actual_rows ≤ 256` AND `blocks ≤ 2`.
  When ALL rows are skipped, `p_triggered` stays FALSE so the rule doesn't fire at all (vs. firing with an empty context, which would trigger persist_result with no actionable content). Constant `c_tiny_table_threshold` is named so the reasoning behind 256 is greppable later.
  Recompiled the package against the live DB via `frontend/scripts/install-rule-engine.mjs`.
- **Files** — [sql/08_create_rule_engine_body.sql](sql/08_create_rule_engine_body.sql)
- **Verified** — Re-running `SELECT * FROM dual` now reports `1 finding(s) (0 high · 1 medium · 0 low)` — only the SELECT * rule fires, not FTS.

## 20. "New chat" sidebar button did nothing in chat mode
- **Severity** — Medium
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Switch to the Assistant tab, hold a conversation, click "New chat" in the sidebar. Old behaviour: nothing happened. The sibling "New query" button worked correctly in Optimize mode, so the chat-mode dead button looked broken.
- **Root cause** — `onNew` in [page.tsx](frontend/app/page.tsx) only reset state when `mode === "optimize"`. The chat path had no equivalent because chat messages live inside `ChatPanel`, not in the parent.
- **Fix** — Added a `chatClearSignal` counter in `Home`. `onNew` increments it when `mode === "chat"`. `ChatPanel` receives the counter as a prop and runs `clearChat()` (clear messages + remove `querymind.chat.v1` from sessionStorage) when it changes — guarded by an `initialClearSignalRef` so the first render doesn't accidentally wipe storage we just restored.
- **Files** — [frontend/app/page.tsx](frontend/app/page.tsx), [frontend/components/ChatPanel.tsx](frontend/components/ChatPanel.tsx)
- **Verified** — Planted two messages in storage, reloaded, switched to Assistant (messages restored), clicked "New chat" — UI returned to the empty state and `sessionStorage.getItem("querymind.chat.v1")` returned `null`.

## 21. Plan cost in the summary banner disagreed with the cost shown in the flowchart
- **Severity** — Medium
- **Area** — Frontend / data
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Optimize any query and compare the top banner ("Cost X → X") with the ROOT node in the flowchart. Old behaviour: numbers disagreed — e.g. banner showed 20 while the flowchart said 2 for `SELECT * FROM dual`. Two cost sources, neither labelled which was authoritative.
- **Root cause** — The banner read `data.plan_analysis.cost` (parsed by Phase 1 PL/SQL inside `QUERY_ANALYZER_PKG`), while the flowchart pulled directly from PLAN_TABLE via `/api/oracle/plan-tree`. The PL/SQL parser sometimes picked an inner-step cost instead of the SELECT STATEMENT root.
- **Fix** — In [optimize.ts](frontend/lib/optimize.ts), reorder the cost source: prefer `plan[0]?.cost` (the parsed DBMS_XPLAN root row, which we already use for the table-view rendering), fall back to `plan_analysis.cost` only when parsing failed. Same change for `rowsEst`. Both surfaces now read from the same authoritative source.
- **Files** — [frontend/lib/optimize.ts](frontend/lib/optimize.ts)
- **Verified** — Banner now shows "Cost 2 → 2" matching the flowchart's "cost 2" for `SELECT * FROM dual`.

## 22. Sample-button click silently overwrote the user's typed query
- **Severity** — Low
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Type a real query into the editor, then click any "Try" sample button. Old behaviour: the typed query was wiped instantly with no warning.
- **Root cause** — The handler was a one-liner: `onClick={() => onChange(s.sql)}`.
- **Fix** — Added `applySample` in [QueryEditor.tsx](frontend/components/QueryEditor.tsx) that detects whether the editor holds non-comment user content (anything beyond blank lines + `--` lines = "user content"). If so, prompt with `window.confirm("Replace your current query with the \"<label>\" sample? Your edit will be lost.")` before overwriting; otherwise replace silently. The starter comment placeholder doesn't trigger the prompt.
- **Files** — [frontend/components/QueryEditor.tsx](frontend/components/QueryEditor.tsx)

## 23. Sample queries with `{your_table}` placeholders triggered late Oracle errors
- **Severity** — Medium
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Click any "Try" sample (Function on indexed column / Subquery → JOIN / SELECT *), then immediately click Optimize without editing. Old behaviour: the request travelled all the way to Oracle, ate ~2 s, and came back with `ORA-00903: invalid table name` from the curly-brace placeholders. The user got a generic Oracle error and had to figure out the placeholder needed swapping.
- **Root cause** — Samples ship with `{your_table}` / `{your_col}` so they're schema-agnostic (Fix #3), but nothing detected the unfilled placeholders before the round-trip.
- **Fix** — Two-part:
  1. Editor footer pill in [QueryEditor.tsx](frontend/components/QueryEditor.tsx): when the editor body matches `/\{[a-z_][a-z0-9_]*\}/`, render a warn-coloured "Replace {placeholders} before running" pill with a tooltip explaining the ORA-00903 reason.
  2. Pre-flight check in `runOptimize` in [page.tsx](frontend/app/page.tsx): scan for the same regex and short-circuit with the ErrorModal naming each placeholder, before calling `/api/oracle/analyze`. Saves a round-trip and gives an actionable message.
- **Files** — [frontend/components/QueryEditor.tsx](frontend/components/QueryEditor.tsx), [frontend/app/page.tsx](frontend/app/page.tsx)
- **Verified** — Loaded "Function on indexed column" sample, clicked Optimize — ErrorModal appeared instantly with "Replace the sample placeholders {your_table}, {your_col} with real names from your schema before running." No network call.

## 24. Plan tab "Before / After" toggle leaked hardcoded HR-schema demo data
- **Severity** — High
- **Area** — Frontend / honesty
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Run any Optimize against the Flexcube DB, switch to the Plan tab, click "After". Old behaviour: the table view rendered the hardcoded `PLAN_AFTER` constant from `optimize-demo.ts` — a pretend rewrite plan referencing `EMPLOYEES`, `DEPARTMENTS`, `IDX_EMP_UNAME` from the Oracle HR sample schema, which the connected DB doesn't even have. Looked like a legitimate optimized plan; was a screenshot from a tutorial.
- **Root cause** — A leftover from the pre-backend prototype. `ResultsPanel.PlanTab` was passed `plan={showAfter ? PLAN_AFTER_DEMO : result.plan}` and we never deleted the demo path after the real backend was wired. We don't currently fetch a plan-tree for the AI rewrite candidate, so there is no honest "After" plan to show.
- **Fix** — Removed the entire Before/After toggle from [ResultsPanel.tsx](frontend/components/ResultsPanel.tsx) (`showAfter`/`setShowAfter` state, the two toggle buttons, the `plan={showAfter ? … : …}` prop). PlanTab now always renders the actual current-query plan. Stripped the dead `PLAN_AFTER_DEMO`, `fakeOptimize`, `RULES`, `PLAN_BEFORE`, `PLAN_AFTER`, and `REWRITE` exports from [optimize-demo.ts](frontend/components/optimize-demo.ts) (the file is now types-only, with a header comment explaining why). Lint passes; `tsc --noEmit` clean.
- **Files** — [frontend/components/ResultsPanel.tsx](frontend/components/ResultsPanel.tsx), [frontend/components/optimize-demo.ts](frontend/components/optimize-demo.ts)
- **Verified** — Plan tab now only shows "Flowchart / Table" toggle (no "Before / After"). Fullscreen flowchart and PlanSummary still work.

## 25. Welcome screen feature cards were faded out, unreadable in corners
- **Severity** — High
- **Area** — Frontend / CSS
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Open Optimize tab without a result (welcome state). The four feature cards (Execution plan / Rule analysis / AI rewrite / Benchmark) sat in a 2×2 grid below the heading. The bottom-left card was nearly invisible — text faded to ~10% opacity — and the bottom-right was noticeably dimmer than the heading. The user couldn't read what each tab does.
- **Root cause** — `.bg-grid-fade` was applying `mask-image: radial-gradient(ellipse at 50% 0%, black 0%, transparent 70%)` directly to the parent `<div>`. CSS masks affect the entire element including its children, so the foreground heading + paragraph + cards inherited the same fade — peaking at the top-center, fading to fully transparent in the bottom corners. The intent was to fade the *grid pattern backdrop only*, not the content.
- **Fix** — Restructured `.bg-grid` and `.bg-grid-fade` in [globals.css](frontend/app/globals.css). The grid pattern now lives on a `::before` pseudo-element (`position: absolute; inset: 0; z-index: -1`); the radial mask is applied to that pseudo-element only. The parent uses `position: relative; isolation: isolate` so the negative-z pseudo stays inside its own stacking context. Foreground children are unaffected and render at full opacity.
- **Files** — [frontend/app/globals.css](frontend/app/globals.css)
- **Verified** — Welcome screen cards are now sharp and fully legible; the grid backdrop still fades softly toward the edges (intended decorative effect retained).

## 26. Sidebar took 280 px of fixed width with no way to reclaim it
- **Severity** — Medium (UX)
- **Area** — Frontend / layout
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — On a narrow laptop screen the editor + results split into two ~480 px columns. Plan flowcharts with several joined tables, long benchmark candidate tables, and AI-rewrite SQL with long lines all wrapped or scrolled horizontally because the 280 px sidebar couldn't be reclaimed. The user had no way to focus on the work area.
- **Root cause** — Not a bug per se — the sidebar was always rendered at full width. Missing affordance.
- **Fix** — Sidebar now collapses to a 56 px icon-only rail when the user clicks the QueryMind logo (or the brand text). The rail keeps the most-used controls reachable (logo-toggle, mode switch, new query/chat, theme toggle, connection status with live indicator). History list + search hide — they need text width that just isn't available at 56 px. Click the logo on the rail to expand back. State persists per-tab in `sessionStorage` (`querymind.sidebar.collapsed.v1`) so a reload doesn't undo the user's choice.
- **Files** — [frontend/components/Sidebar.tsx](frontend/components/Sidebar.tsx), [frontend/app/page.tsx](frontend/app/page.tsx)
- **Verified** — Toggled both directions in Playwright; reloaded with the rail active and confirmed it stayed collapsed; the editor + welcome cards reflow into the freed 224 px and the textarea no longer line-wraps the starter comment.

## 27. Comment-only query wasted a round-trip and got a technical Oracle error
- **Severity** — Low (UX)
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Click Optimize without editing the starter `-- Paste a slow Oracle SELECT here…` comment (or any editor content that's only `--` / `/* … */` comments). Old behaviour: the request travelled to Oracle, ate ~150 ms, and came back with `Oracle: Only SELECT queries are supported in Phase 2` — a technical error message that doesn't tell the user what to do next.
- **Root cause** — `runOptimize` only checked `!sql.trim()`. It treated comment-only content as valid input.
- **Fix** — Added a comment-stripping pre-flight check in [page.tsx](frontend/app/page.tsx) `runOptimize`: regex out `/* … */` blocks, then drop everything from `--` to end-of-line per row, trim. If the residue is empty, surface a friendly ErrorModal — *"The editor only contains comments. Paste a SELECT statement before running."* — and skip the API call.
- **Files** — [frontend/app/page.tsx](frontend/app/page.tsx)
- **Verified** — Clicked Optimize on the unmodified starter; ErrorModal appeared instantly with the new copy. No network request fired.

## 28. Editor's keyboard-shortcut hint showed `⌘` on non-Mac platforms
- **Severity** — Low (i18n / UX)
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Open the app on Windows or Linux. The editor toolbar showed `⌘ ↵ to optimize` even though the actual shortcut on those platforms is Ctrl+Enter (the `onKeyDown` handler accepts both `metaKey` and `ctrlKey`, so the behaviour was right; only the label lied).
- **Root cause** — Hard-coded `⌘` glyph in the toolbar JSX.
- **Fix** — Added `useShortcutKeyLabel()` hook in [QueryEditor.tsx](frontend/components/QueryEditor.tsx). It defaults to `Ctrl` (the SSR fallback, matching the eventual Windows/Linux render — avoids hydration mismatch), then in a `useEffect` checks `navigator.platform` / `userAgent` and switches to `⌘` for Mac/iOS. Toolbar uses `cmdKey` instead of the literal symbol.
- **Files** — [frontend/components/QueryEditor.tsx](frontend/components/QueryEditor.tsx)
- **Verified** — Windows render now shows `Ctrl ↵ to optimize`. Mac users still see `⌘ ↵`.

## 29. Summary stat pill kept a "trending down" arrow when before/after were equal
- **Severity** — Low (visual)
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Run a query whose Phase 4 benchmark didn't change cost/time (most queries — Phase 4 only runs when the AI produces rewrites). Even with #18's pill colour fix, the down-trend arrow icon remained, hinting at improvement that wasn't there.
- **Root cause** — The `<IcTrendingDown>` was rendered unconditionally inside `Stat`.
- **Fix** — Wrapped the arrow in `{trend !== "unchanged" && (...)}` so it only renders for `improved` (down-arrow) or `regressed` (rotated 180°). Unchanged pills now show just the label and values.
- **Files** — [frontend/components/ResultsPanel.tsx](frontend/components/ResultsPanel.tsx)
- **Verified** — `SELECT * FROM dual` summary pill now reads `Cost 2 → 2` and `Time 126.46ms → 126.46ms` cleanly with no arrow icon.

## 30. Sidebar history rows had no hover tooltip — duplicates were indistinguishable
- **Severity** — Low (UX)
- **Area** — Frontend / UX
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Run the same query twice. Both history rows showed identical truncated titles ("SELECT * FROM dual") and the only differentiator was `Xm ago` in tiny dim text. Hovering didn't reveal more detail.
- **Root cause** — No `title` attribute on the row.
- **Fix** — In [Sidebar.tsx](frontend/components/Sidebar.tsx), built a multi-line tooltip per history row: full title, preview, and absolute timestamp (`new Date(h.ts).toLocaleString()`). Rendered as a native `title` attribute so hover works without extra components. Delete button got its own `title` too.
- **Files** — [frontend/components/Sidebar.tsx](frontend/components/Sidebar.tsx)

## 31. Sidebar collapse was instant — no transition, ignored OS reduce-motion
- **Severity** — Low (UX / accessibility)
- **Area** — Frontend / animation
- **Date fixed** — 2026-05-02
- **Status** — ✅ Fixed
- **Repro** — Click the QueryMind logo: the sidebar snapped between 56 px and 280 px with a hard width jump and the inner content swapped instantly — disorienting on a wide screen. Users with `prefers-reduced-motion: reduce` had no relief from `fade-up` / `pulse-dot` animations elsewhere either.
- **Fix** — Two parts:
  1. Restructured [Sidebar.tsx](frontend/components/Sidebar.tsx) so a single `<aside>` owns the width and transitions it (`width 220ms ease-out`); inside, the rail and full layouts are separate components keyed off `collapsed` so React mounts a fresh subtree on toggle and the existing `fade-up` keyframe gives the new content a soft entrance. `overflow-hidden` on the aside prevents the wider layout from spilling during the resize.
  2. Added a global `@media (prefers-reduced-motion: reduce)` block in [globals.css](frontend/app/globals.css) that clamps every animation/transition duration to 0.01 ms, disables `fade-up` and `pulse-dot`, and forces `scroll-behavior: auto`. Users with the OS preference set get instant transitions everywhere.
- **Files** — [frontend/components/Sidebar.tsx](frontend/components/Sidebar.tsx), [frontend/app/globals.css](frontend/app/globals.css)
- **Verified** — `getComputedStyle(aside)` reports `transition-property: width`, `duration: 0.22s`, `timing-function: cubic-bezier(0, 0, 0.2, 1)`. Width animates 280 → 56 over the duration; content cross-fades via `fade-up`.

## 32. `notify()` called inside a `setMessages` updater triggered a React warning and silently dropped the parent state update
- **Severity** — High (correctness)
- **Area** — Frontend / state
- **Date fixed** — 2026-05-11
- **Status** — ✅ Fixed
- **Repro** — Send any chat. Dev console emits *"Cannot update a component (`Home`) while rendering a different component (`ChatPanel`). To locate the bad setState() call inside `ChatPanel`, follow the stack trace…"*. Worse, the final `notify(finalized)` that should persist the assistant's reply to history sometimes drops on the floor — chat history ends up with the user message but no assistant content.
- **Root cause** — `send()` was finalising the assistant message inside a `setMessages((all) => { const finalized = …; notify(finalized); return finalized; })` updater. Updater functions run during React's render phase; calling parent `setState` (via `onMessagesChangeRef.current?.(…)`) during render is the classic "set state during render" violation. React rejects the call and warns.
- **Fix** — In [ChatPanel.tsx](frontend/components/ChatPanel.tsx) `send()`, replaced the `setMessages((all) => …)` pattern with a local `let currentMessages` variable that we keep in sync manually, plus an `applyAssistantMutation` helper. Each stream delta updates `currentMessages` AND calls `setMessages(currentMessages)` (a regular value-form setter, not an updater function). At the end of the stream we have `currentMessages` already computed, so `notify(currentMessages)` runs outside any React render lifecycle.
- **Files** — [frontend/components/ChatPanel.tsx](frontend/components/ChatPanel.tsx)
- **Verified** — Sent a chat, checked sessionStorage: history entry has BOTH the user message and the full assistant content. No more React warning in the dev console.

## 33. Orphan stream after chat-switch corrupted the wrong chat
- **Severity** — Critical
- **Area** — Frontend / async / data integrity
- **Date fixed** — 2026-05-11
- **Status** — ✅ Fixed
- **Repro** — Open the Database Assistant. Send a message that triggers a long response. While the stream is still arriving, click another chat in the sidebar. The new chat (the one you switched away from) keeps streaming in the background. When it finishes, its assistant message gets persisted under the *currently active* chat's id — **overwriting an unrelated conversation's reply**.
- **Root cause** — Two compounding issues:
  1. The fetch had no `AbortController`. Unmounting `ChatPanel` (via the `chatLoadKey` remount key) didn't cancel the in-flight HTTP read; the async `send()` continued to completion in the JS event loop.
  2. The parent's `handleChatMessagesChange` callback routed history updates via `activeIdRef.current` — the *currently active* chat. So the orphan's final `notify(finalized)` landed on whichever chat the user had selected by that point, not the original one.
- **Fix** — Two changes:
  1. `ChatPanel` now creates an `AbortController` per `send()`. An unmount-cleanup `useEffect` aborts it; `clearChat` also aborts it. The fetch's read loop throws `AbortError` on cancellation, which we swallow without notifying the parent (so the orphan can't post a misleading "Network error" against the original chat).
  2. Added a `chatIdRef` to `ChatPanel`. Either seeded from `initialChatId` (when restoring a chat from history) or minted on the first `send()`. The `notify(...)` signature is now `(chatId, messages)` — the chatId is captured in the closure, so the parent always routes to THIS chat's history entry, even if the user has since switched away.
  3. `page.tsx` `handleChatMessagesChange` was rewritten to upsert by `chatId` rather than reading `activeIdRef`. The old `activeIdRef` plumbing is gone.
- **Files** — [frontend/components/ChatPanel.tsx](frontend/components/ChatPanel.tsx), [frontend/app/page.tsx](frontend/app/page.tsx)
- **Verified** — Planted a pristine "B-tree" chat in history. Started a new chat with a long-essay prompt, immediately clicked the B-tree entry (≤30 ms after submit). Waited 20 s for the orphan stream to land. The B-tree chat's content is unchanged; the abandoned "essay" chat shows only the user message (per #34 below).

## 34. Aborted chat persisted an empty assistant placeholder
- **Severity** — Low (UX)
- **Area** — Frontend / state
- **Date fixed** — 2026-05-11
- **Status** — ✅ Fixed
- **Repro** — Send a chat, switch chats before the first delta arrives. The aborted chat shows up in history with `messages = [user, empty-assistant]`. Click it later: the user message renders, but the assistant bubble is completely empty — looks broken.
- **Root cause** — The user-submission `notify(nextMessages)` fires immediately after appending `[user, placeholder({content: "", streaming: true})]`. The notify helper strips `streaming: true` but keeps the empty-content bubble. If the stream gets aborted (via #33's fix), the chat persists in that intermediate "user + empty bubble" state.
- **Fix** — `notify()` in [ChatPanel.tsx](frontend/components/ChatPanel.tsx) now also filters out assistant messages with empty `content` BEFORE handing off to the parent. Empty assistant bubbles only matter inside the *running* ChatPanel for the typing indicator UX; persisting them is just noise. Real "(empty reply)" responses go through a different code path that fills the content first.
- **Files** — [frontend/components/ChatPanel.tsx](frontend/components/ChatPanel.tsx)
- **Verified** — Repeated the abort test from #33. The aborted chat's persisted state is `messages: [user]` — single message, no placeholder. Clicking it shows just the user's question, ready for a follow-up.

## 35. Deleting the active chat from the sidebar left a "ghost" pane
- **Severity** — Medium
- **Area** — Frontend / state
- **Date fixed** — 2026-05-11
- **Status** — ✅ Fixed
- **Repro** — Open a chat from the sidebar, then hover the same entry and click its trash button. The entry disappears from the sidebar — but ChatPanel keeps rendering the deleted conversation. Worse, if the user then types a follow-up message, `chatIdRef` in ChatPanel still holds the deleted id, so the next `notify` resurrects the entry under that id.
- **Root cause** — `onDelete` was `(id) => setHistory((h) => h.filter((x) => x.id !== id))`. It removed the entry but didn't touch `activeId` or `chatLoadKey`, so ChatPanel's `key` never changed → no remount → stale internal state.
- **Fix** — In [page.tsx](frontend/app/page.tsx), the delete handler now checks whether the deleted id was active. If so it resets the panel: `setActiveId(null)`, plus `setChatLoadKey(n => n + 1)` (chat mode) to remount ChatPanel with empty state, or `setSql/setResult/setError` resets (optimize mode).
- **Files** — [frontend/app/page.tsx](frontend/app/page.tsx)
- **Verified** — Planted a chat, clicked it to load, clicked its delete button. Sidebar shows "No items"; ChatPanel returns to the welcome state; sessionStorage history is `[]`.
