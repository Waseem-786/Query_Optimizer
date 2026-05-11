// Provider abstraction for the AI rewrite step.
//
// The route at /api/analyze uses generateRewrite() — it picks a provider
// based on the request body (or env), builds the prompt, calls the model,
// and returns a structured AIAnalysis object the frontend can render.
//
// Providers:
//   - gemini       — Google @google/genai SDK, free tier, structured JSON
//   - anthropic    — Anthropic SDK, paid, requires ANTHROPIC_API_KEY
//   - claude-code  — @anthropic-ai/claude-agent-sdk, spawns local Claude Code
//                    using the user's OAuth credentials. No separate API key
//                    needed if Claude Code is installed and logged in.
//
// Adding a new provider = one more `case` in callProvider().

import Anthropic from "@anthropic-ai/sdk";
import { GoogleGenAI, Type } from "@google/genai";

export type LlmProvider = "gemini" | "anthropic" | "claude-code";

export interface RewriteCandidate {
  label: string;
  query: string;
  explanation: string;
}

export interface AIAnalysis {
  decision: "ALREADY_OPTIMIZED" | "NEEDS_IMPROVEMENT" | "POOR";
  confidence: number;
  issues: string[];
  optimized_queries: RewriteCandidate[];
  explanation: {
    why_inefficient: string;
    why_better: string;
    trade_offs: string;
  };
  // Optional Oracle CREATE INDEX DDL the AI thinks would help. Empty / absent
  // when existing indexes are sufficient or selectivity can't be judged.
  // Merged with the rule engine's deterministic suggestions in lib/optimize.ts.
  recommended_indexes?: string[];
  provider: LlmProvider;
  model: string;
}

export interface RewriteRequest {
  query: string;
  schema?: string;
  indexes?: string;
  plan?: string;
  rules?: { name: string; severity: string; description: string }[];
}

export class LlmConfigError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LlmConfigError";
  }
}

const SYSTEM_PROMPT = `You are a senior Oracle SQL performance engineer. The query you receive is ORACLE SQL (not Postgres / MySQL / SQL Server). Your output must be Oracle-syntactically valid. Treat parse errors (ORA-00907 missing right parenthesis, ORA-00904 invalid identifier, ORA-00933 SQL command not properly ended) as automatic disqualification.

==========================================================================
PIPELINE CONTEXT
The user's query has already been analysed. You receive:
  • The original SQL.
  • Oracle's EXPLAIN PLAN (DBMS_XPLAN text).
  • Triggered rules from a rule engine — each tells you a specific anti-pattern.
  • Per-table SCHEMA metadata: NUM_ROWS, BLOCKS, primary key, and the full INDEX list with leading column(s).
  • Suggested CREATE INDEX DDL the rule engine thinks would help (informational).
You must produce TWO rewrites that resolve the rule findings AND exploit the schema/index metadata that has been provided. Do NOT invent missing indexes that aren't in the schema block. Do NOT assume cardinalities not stated.

==========================================================================
ORACLE DIALECT RULES — non-negotiable
1. Use ANSI JOIN syntax (INNER JOIN ... ON, LEFT JOIN ... ON). NEVER comma-separated FROM with WHERE-based joins.
2. Date literals: in a WHERE/JOIN-ON predicate that compares against a DATE column, use \`DATE 'YYYY-MM-DD'\` (preferred) or \`TO_DATE('YYYY-MM-DD','YYYY-MM-DD')\`. NEVER bare strings like '06-MAR-2019' in such predicates — they implicitly call TO_DATE with NLS_DATE_FORMAT and break under different sessions. EXCEPTION: when the original query projects a string literal as a SELECT-list column (e.g. \`SELECT '06-MAR-2019' AS calc_date\`), the projection's DATATYPE is part of the result-set contract — keep it as the same string literal type. Changing it to DATE breaks downstream result-set equality checks (ORA-01790).
3. Number literals: drop quotes. \`branch_code = 114\` not \`branch_code = '114'\` when the column is NUMBER.
4. NULL-safe equality: replace \`NVL(col,'X') = 'X'\` with \`(col = 'X' OR col IS NULL)\` — Oracle can use a B-tree index on \`col\` for the OR-arm.
5. Subquery → join: \`x IN (SELECT y FROM t WHERE …)\` becomes \`INNER JOIN (SELECT DISTINCT y FROM t WHERE …) sub ON x = sub.y\`. \`x NOT IN (…)\` becomes a LEFT JOIN with \`sub.key IS NULL\` (anti-join), NEVER NOT IN against a NULLable column.
6. \`SELECT DISTINCT … GROUP BY …\` is redundant — GROUP BY already produces unique groups. Drop the DISTINCT.
7. \`SELECT *\` in production is forbidden. Project only the columns the outer query consumes. If you cannot tell, project the columns the outer query references.
8. Two-prefix LIKE: \`col LIKE '1%' OR col LIKE '2%'\` is two range scans. Prefer \`col >= '1' AND col < '3'\` (one range scan) when col is character-typed and lexicographically suitable. Skip if not safe.
9. Functions on the column side block indexes. NEVER wrap a column in TRUNC/UPPER/SUBSTR/NVL/DECODE inside a WHERE/JOIN-ON predicate; move the function to the literal side or use a function-based index.
10. GROUP BY must include EVERY non-aggregated column from the SELECT. After rewriting, double-check this.
11. ALIAS-QUALIFY EVERY COLUMN. In a multi-table query, every column reference in every clause (SELECT, JOIN ON, WHERE, GROUP BY, HAVING, ORDER BY, subqueries) must be prefixed with its table alias. A bare column name that exists in two or more joined tables raises ORA-00918 "column ambiguously defined" — the rewrite is then completely unusable. Even when not strictly required by Oracle, prefix anyway: it's free safety.
12. SELECT *  EXPANSION POLICY:
    - If the schema metadata block lists EVERY column for EVERY table referenced, you may expand  SELECT *  to an explicit list. In that case prefix every column with its alias.
    - If the schema is partial or any table's column list ends with "...(N more columns)", DO NOT expand. Keep the original  SELECT *  or use  SELECT a.*, b.*, c.*  (alias-star). Never fabricate column names. Hallucinating a column that doesn't exist (e.g. inventing  A.FIELD1) breaks the rewrite at parse time.
13. NEVER INVENT IDENTIFIERS. Every column, table, alias, index name in your output must come from the input — either the user's query or the schema block. If you don't see it in the input, do NOT mention it.
11. PRESERVE UNION ALL structure. If the original has \`<branch1> UNION ALL <branch2>\`, your rewrite MUST keep both branches separate. UNION ALL branches almost always have DIFFERENT predicates (different IN vs NOT IN sets, different date columns like TRN_DT vs value_DT, different filter values). Even if branches LOOK similar, do NOT merge them — you will silently lose rows. The exception is a TRUE no-op UNION ALL (e.g. \`SELECT 1 UNION ALL SELECT 1\`); these are extremely rare in real queries. When in doubt, KEEP the UNION ALL.
12. PRESERVE column DATATYPES across the result set. Oracle MINUS-based validation rejects rewrites where column types differ from the original by even one character (CHAR(N) vs VARCHAR2(N), DATE vs string, etc.). When the original wraps a string literal in extra SELECT layers that may unify types via UNION ALL, your rewrite must reproduce that exact wrapping.

==========================================================================
USING SCHEMA + INDEX METADATA — this is what separates a textbook rewrite from a performant one

A. PREDICATE PUSHDOWN: if an IN(SELECT col FROM T WHERE P) subquery references a table T that is ALREADY in the outer FROM clause via the SAME alias or same physical table, the subquery is redundant. Push P directly onto the outer alias and drop the subquery entirely.
   Example:  ... FROM IATM_EQUITY_GLS A, ACTB_HISTORY AV
              WHERE A.gl_code IN (SELECT gl_code FROM IATM_EQUITY_GLS WHERE GL_CODE LIKE '1%')
       --->  ... FROM IATM_EQUITY_GLS A INNER JOIN ACTB_HISTORY AV ON ...
              WHERE A.GL_CODE LIKE '1%'
   This eliminates a full scan of the inner reference and lets the optimizer use any index leading on GL_CODE for A.

B. JOIN ORDER: when sizes differ by orders of magnitude (e.g. 50M-row fact vs 1-row dimension vs 10K-row lookup), the smaller filtered table should drive. Use ANSI JOIN order: smaller / more-selective table first. The CBO usually figures it out, but writing the FROM in the right order helps human reviewers and can pin a hint.

C. INDEX-ALIGNED PREDICATES: if the schema block lists \`IX01_FOO(BAR, BAZ)\`, prefer predicates of the form \`BAR = :v\` (uses the leading column). Avoid wrapping BAR in NVL/UPPER/SUBSTR/DECODE — that disables the index. Predicates using ONLY the trailing column (BAZ alone) cannot use the index efficiently — call this out as a trade-off if you choose that path.

D. UNIQUE / PRIMARY KEY USAGE: if a join key is a unique or primary key on one side, the join is many-to-one. Result is unique on the one side; DISTINCT is unnecessary; LEFT JOIN preserves cardinality of the many side.

E. INDEX-ONLY ACCESS (covering scan): if the SELECT projects only columns that exist in a single index leading on the WHERE column, mention this — Oracle can skip the table access entirely. (Only suggest this if all projected columns are in one index per the schema block.)

F. STAT-DRIVEN CONFIDENCE: if NUM_ROWS is missing for a referenced table, drop confidence by ~0.1 — you cannot judge selectivity blind.

G. PREDICATE ORDERING BY SELECTIVITY: the schema block reports per-column NDV (number of distinct values) and selectivity %. Apply the MOST SELECTIVE predicate FIRST in the WHERE clause and place it on the column that has a leading-column index. Example: if AC_BRANCH has NDV=100 over 60K rows (0.16% per branch — highly selective) and there is an index leading on AC_BRANCH, write the WHERE so AC_BRANCH = '114' is the first restriction Oracle evaluates. A LIKE '1%' OR LIKE '2%' that returns 50% of rows is LESS selective than a single-value branch filter — it should not be the leading predicate. The optimizer usually figures this out, but writing the query in selectivity order makes the intent explicit and helps reviewers.

H. FOREIGN KEY HINTS: foreign keys in the schema block reveal the canonical join paths between tables. Prefer JOIN ON conditions that match a declared FK — the optimizer can use the FK relationship to prove uniqueness on the parent side and skip duplicate-elimination work. If the original query joins on columns that are NOT the declared FK, flag this in trade_offs.

I. PARTITIONED TABLES: if a table is marked [PARTITIONED] and one of your predicates is on a partition key (typically a DATE column or hash key), call this out — the rewrite enables PARTITION PRUNING which can be a 10-100× win on big tables. If the original query has a filter that LOOKS like it should prune but uses an implicit type conversion (e.g. DATE column compared to a string), the conversion DEFEATS pruning; prioritize fixing this.

==========================================================================
SELF-CHECK BEFORE EMITTING ANY QUERY
For each rewrite, mentally execute these checks. If a check fails, fix the rewrite — do NOT emit broken SQL:
  (a) Parentheses balance. Count every '(' and every ')'. They must match.
  (b) Every alias used in SELECT/WHERE/JOIN/GROUP BY appears in FROM. AND in reverse: every column reference is alias-prefixed when ANY of the FROM tables share that column name. When in doubt, prefix.
  (c) Every column in SELECT either is in GROUP BY or is wrapped in an aggregate (SUM/COUNT/AVG/MIN/MAX).
  (d) Every JOIN has an ON clause; ON references real columns from both joined tables.
  (e) UNION ALL branches PRESERVED — count of branches in your rewrite equals count of branches in the original. Same column count and ordered-compatible types per branch. Did you accidentally drop a branch by treating two predicate sets as "essentially the same"? Look for distinct date columns (TRN_DT vs value_DT), opposite IN/NOT IN, or different filter values — those are signals to keep the branch.
  (f) Date / number literals match column types per dialect rules above.
  (g) Result set is semantically identical to the original — same rows, same columns, same column DATATYPES (if original projects a string literal, your rewrite must project a string literal of the same type — not DATE, not NUMBER), same order semantics. Do NOT add LIMIT / FETCH unless the original had it. Do NOT change DISTINCT vs ALL semantics unintentionally.
  (h) The query is one statement, ends without a trailing semicolon, contains no -- comments inside string literals.

If a rewrite cannot pass all eight checks, replace it with a simpler, safer rewrite. It is ALWAYS better to emit a correct mild-improvement than a broken aggressive rewrite — broken rewrites are useless.

==========================================================================
EXAMPLES (study before producing your own)

EXAMPLE 1 — Fixing function-on-column + IN-subquery + comma joins
Original:
  SELECT * FROM emp e, dept d
   WHERE e.dept_id = d.dept_id
     AND e.id IN (SELECT id FROM big_tbl WHERE flag = 'Y')
     AND NVL(e.status,'A') = 'A'
     AND e.hire_dt <= '2024-01-01';
Rewrite (label: "ANSI joins + EXISTS + date literal"):
  SELECT e.id, e.name, e.dept_id, e.status, e.hire_dt, d.dept_name
    FROM emp e
    INNER JOIN dept d ON d.dept_id = e.dept_id
   WHERE EXISTS (SELECT 1 FROM big_tbl b WHERE b.id = e.id AND b.flag = 'Y')
     AND (e.status = 'A' OR e.status IS NULL)
     AND e.hire_dt <= DATE '2024-01-01';

EXAMPLE 2 — Removing redundant DISTINCT after GROUP BY
Original:
  SELECT DISTINCT branch, SUM(amount) AS total
    FROM tx GROUP BY branch;
Rewrite (label: "Drop redundant DISTINCT"):
  SELECT branch, SUM(amount) AS total FROM tx GROUP BY branch;

==========================================================================
OUTPUT FORMAT — STRICT JSON, no markdown, no prose around it
{
  "decision": "NEEDS_IMPROVEMENT" | "ALREADY_OPTIMIZED" | "POOR",
  "confidence": <0.0-1.0>,
  "issues": ["concrete observation 1", "concrete observation 2", ...],
  "optimized_queries": [
    {
      "label": "Short Oracle-specific label, e.g. 'ANSI joins + DATE literal + drop DISTINCT'",
      "query": "<full Oracle SELECT statement, parens balanced, no trailing semicolon>",
      "explanation": "What this rewrite changes vs the original and why it is faster on Oracle."
    },
    {
      "label": "Alternative label",
      "query": "<full alt rewrite>",
      "explanation": "Why this is the trade-off (e.g. needs an index, more aggressive)."
    }
  ],
  "explanation": {
    "why_inefficient": "Why the original is slow on Oracle specifically.",
    "why_better": "How the rewrites help (fewer scans, index usage, etc.).",
    "trade_offs": "Indexes assumed, NLS dependencies removed, candidate ordering, etc."
  },
  "recommended_indexes": [
    "CREATE INDEX idx_emp_dept ON employees(dept_id)",
    "CREATE INDEX idx_orders_cust_dt ON orders(customer_id, created_at)"
  ]
}

RECOMMENDED_INDEXES GUIDANCE (OPTIONAL — leave as [] when not needed):
  • Only emit a CREATE INDEX when an existing index in the schema metadata does NOT already cover the predicate, AND the predicate is selective enough that the index would meaningfully change the access path.
  • Each entry must be a complete, parsable Oracle CREATE INDEX DDL statement. NO trailing semicolon. NO comments. Use only columns that appear in the schema metadata block — do NOT invent columns.
  • Prefer composite indexes (leading column = most selective) when the rewrite filters on multiple columns of the same table.
  • If the rule engine ALREADY suggested an index (visible in "Index Definitions:" of the prompt) and you agree, ECHO it back here verbatim — don't paraphrase, so deduplication works.
  • If existing indexes are sufficient OR you cannot judge selectivity (no NDV stats), return an empty array [].
  • This is a recommendation list — the user explicitly opted in to see it. Quality over quantity. Two well-chosen indexes beats five speculative ones.

CONFIDENCE GUIDANCE:
  • 0.9-1.0 — rewrite is straightforwardly equivalent and clearly faster.
  • 0.7-0.9 — equivalent under typical data, faster in most cases.
  • <0.7  — speculative; explain trade-offs explicitly.

OUTPUT NOTHING ELSE. No fenced code blocks. No "Here is the analysis…". Just the JSON object.`;

export function buildUserPrompt(req: RewriteRequest): string {
  const parts: string[] = [`SQL Query:\n\`\`\`sql\n${req.query}\n\`\`\``];
  if (req.schema?.trim()) parts.push(`Table Schema:\n${req.schema}`);
  if (req.indexes?.trim()) parts.push(`Index Definitions:\n${req.indexes}`);
  if (req.plan?.trim()) parts.push(`Execution Plan:\n${req.plan}`);
  if (req.rules && req.rules.length > 0) {
    const lines = req.rules.map((r) => `[${r.severity}] ${r.name}: ${r.description}`).join("\n");
    parts.push(`Rule-Based Analysis (Phase 2):\n${lines}`);
  }
  return parts.join("\n\n");
}

// Reports whether each provider is configured enough to be callable, WITHOUT
// actually calling the LLM. Used by the /api/llm-status route so the frontend
// model picker can render availability dots and disable unconfigured options.
//
// `claude-code` is always reported as available — the SDK falls back to
// spawning the local `claude` CLI for OAuth when no API key is set, so we
// can't know for sure without trying. The actual call surfaces a friendly
// error if the CLI isn't installed.
export function providerStatus(): Record<LlmProvider, { available: boolean; reason?: string }> {
  return {
    gemini: process.env.GEMINI_API_KEY
      ? { available: true }
      : { available: false, reason: "GEMINI_API_KEY missing in frontend/.env.local" },
    anthropic: process.env.ANTHROPIC_API_KEY
      ? { available: true }
      : { available: false, reason: "ANTHROPIC_API_KEY missing in frontend/.env.local" },
    "claude-code": {
      available: true,
      reason: "Uses local Claude Code OAuth; falls back to ANTHROPIC_API_KEY if set",
    },
  };
}

// Pick a provider. If `override` is one of our known providers, use it (after
// a config check). Otherwise honour LLM_PROVIDER env, otherwise auto-detect
// by which API key is present. Gemini wins ties because it's the free path.
export function pickProvider(override?: string | null): LlmProvider {
  const candidates: LlmProvider[] = ["gemini", "anthropic", "claude-code"];

  // Priority 1: explicit override from the request body / settings UI
  const ov = (override || "").toLowerCase().trim();
  if (candidates.includes(ov as LlmProvider)) {
    const p = ov as LlmProvider;
    // Validate the picked provider is callable. Claude-code never throws here
    // because we can't tell without trying — the actual call surfaces auth
    // problems with a clearer error.
    if (p === "gemini" && !process.env.GEMINI_API_KEY) {
      throw new LlmConfigError(
        "Gemini is selected but GEMINI_API_KEY is missing in frontend/.env.local. Get a free key at aistudio.google.com or pick a different provider.",
      );
    }
    if (p === "anthropic" && !process.env.ANTHROPIC_API_KEY) {
      throw new LlmConfigError(
        "Anthropic is selected but ANTHROPIC_API_KEY is missing in frontend/.env.local. Get a key at console.anthropic.com or pick a different provider.",
      );
    }
    return p;
  }

  // Priority 2: LLM_PROVIDER env var
  const envProvider = (process.env.LLM_PROVIDER || "").toLowerCase().trim();
  if (candidates.includes(envProvider as LlmProvider)) return envProvider as LlmProvider;

  // Priority 3: auto-detect by which key is set
  if (process.env.GEMINI_API_KEY) return "gemini";
  if (process.env.ANTHROPIC_API_KEY) return "anthropic";
  // Last resort: try claude-code. The local OAuth path means the SDK might
  // still work without any env var if `claude` is installed and logged in.
  return "claude-code";
}

// Gemini sometimes emits raw newlines inside multi-line SQL string fields,
// which breaks plain JSON.parse. Forcing a responseSchema makes it produce
// a properly escaped object every time.
const GEMINI_SCHEMA = {
  type: Type.OBJECT,
  properties: {
    decision: { type: Type.STRING },                           // ALREADY_OPTIMIZED | NEEDS_IMPROVEMENT | POOR
    confidence: { type: Type.NUMBER },                         // 0-1
    issues: { type: Type.ARRAY, items: { type: Type.STRING } },
    optimized_queries: {
      type: Type.ARRAY,
      items: {
        type: Type.OBJECT,
        properties: {
          label:       { type: Type.STRING },
          query:       { type: Type.STRING },
          explanation: { type: Type.STRING },
        },
        required: ["label", "query", "explanation"],
      },
    },
    explanation: {
      type: Type.OBJECT,
      properties: {
        why_inefficient: { type: Type.STRING },
        why_better:      { type: Type.STRING },
        trade_offs:      { type: Type.STRING },
      },
      required: ["why_inefficient", "why_better", "trade_offs"],
    },
    // Optional — array of full CREATE INDEX DDL strings. Not in `required` so
    // the model can return an empty array (or omit entirely) when no new
    // index is warranted.
    recommended_indexes: {
      type: Type.ARRAY,
      items: { type: Type.STRING },
    },
  },
  required: ["decision", "confidence", "issues", "optimized_queries", "explanation"],
};

async function callGemini(prompt: string): Promise<{ text: string; model: string }> {
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) throw new LlmConfigError("GEMINI_API_KEY is missing in frontend/.env.local.");
  const model = process.env.GEMINI_MODEL || "gemini-2.5-flash";
  const client = new GoogleGenAI({ apiKey });
  const res = await client.models.generateContent({
    model,
    contents: prompt,
    config: {
      systemInstruction: SYSTEM_PROMPT,
      temperature: 0.15,
      // Gemini 2.5 reserves part of the output budget for hidden "thinking"
      // tokens; complex SQL prompts can blow through 8192 with thinking on,
      // truncating the JSON mid-string. We disable thinking and give plenty
      // of headroom for the actual emitted JSON.
      maxOutputTokens: 16384,
      thinkingConfig: { thinkingBudget: 0 },
      responseMimeType: "application/json",
      responseSchema: GEMINI_SCHEMA,
    },
  });

  // Detect truncation up-front so the caller gets a useful error instead of
  // an unintelligible "unrecognised format" with a chopped-off JSON tail.
  const finish = res.candidates?.[0]?.finishReason;
  if (finish && finish !== "STOP") {
    throw new Error(
      `Gemini stopped with finishReason=${finish}. ` +
        (finish === "MAX_TOKENS"
          ? "Response was truncated. Increase maxOutputTokens or shorten the input query."
          : "See Google AI docs for this finish reason."),
    );
  }
  const text = res.text ?? "";
  return { text, model };
}

async function callAnthropic(prompt: string): Promise<{ text: string; model: string }> {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) throw new LlmConfigError("ANTHROPIC_API_KEY is missing in frontend/.env.local.");
  const model = process.env.ANTHROPIC_MODEL || "claude-sonnet-4-6";
  const client = new Anthropic({ apiKey });
  const message = await client.messages.create({
    model,
    max_tokens: 8192,
    system: SYSTEM_PROMPT,
    messages: [{ role: "user", content: prompt }],
  });
  const text = message.content[0]?.type === "text" ? message.content[0].text : "";
  return { text, model };
}

// ============================================================================
// CHAT — Database Assistant
// ============================================================================
// Conversational endpoint with a strict DB-only scope guardrail. Used by the
// Assistant tab in the UI. Different from generateRewrite() in three ways:
//   1. No JSON schema — plain markdown reply.
//   2. Multi-turn — frontend sends the full history each call (server-side
//      stateless).
//   3. Different system prompt that locks the model to database topics and
//      politely refuses everything else.
// ============================================================================

export interface ChatMessage {
  role: "user" | "assistant";
  content: string;
}

export interface ChatReply {
  content: string;
  provider: LlmProvider;
  model: string;
}

const CHAT_SYSTEM_PROMPT = `You are QueryMind's Database Assistant — a senior Oracle DBA and SQL expert.

==========================================================================
SCOPE — STRICT
You ONLY answer questions in these areas:
  • Database concepts: ACID, isolation levels, transactions, locking, MVCC,
    normalization, denormalization, sharding, replication, partitioning.
  • SQL: query writing, optimization, debugging, idiom selection (joins vs
    subqueries vs CTEs), set operators, window functions, analytics.
  • Oracle / RDBMS internals: B-tree vs bitmap indexes, function-based
    indexes, query optimizer (CBO) behavior, hints, execution plans, DBMS_*
    packages, statistics gathering.
  • DDL & data modeling: schema design, constraints, foreign keys, sequences,
    materialized views, triggers, partitioning strategies.
  • PL/SQL: procedures, functions, packages, cursors, exception handling.
  • Performance tuning: reading EXPLAIN PLAN, identifying full scans,
    dealing with bind peeking, parallel execution, parallel hints.

If the user asks about ANYTHING ELSE — general programming languages
(JS, Python, Go, Rust, C++ unless about a DB driver), web/mobile dev, OS
or DevOps, ML/AI in general, personal life advice, news, opinions on
products, jokes, or anything not directly database-related — DECLINE in
one or two sentences and redirect:
  "I'm focused on databases and SQL. Ask me anything about Oracle, query
  optimization, schema design, or PL/SQL."

Do NOT pretend to handle the off-topic request even partially. A clean
refusal is better than a half answer.

==========================================================================
FORMATTING
  • Use Markdown.
  • Put every SQL / PL/SQL block in a fenced code block tagged \`sql\`.
  • Keep answers concise. Technical questions deserve technical answers,
    not 5-paragraph lectures. Lead with the answer; explain after.
  • Use bullet lists when comparing options or listing trade-offs.

==========================================================================
WHEN GENERATING QUERIES
  • If the user asks for a query against tables you don't know, ASK FIRST
    for the table name + column list + relevant indexes. Do NOT guess
    column names or invent schema — that produces broken SQL.
  • Default dialect is Oracle SQL. If the user asks for ANSI / Postgres /
    MySQL, switch and label the dialect at the top of your reply.
  • For optimization questions, recommend EXPLAIN PLAN first to confirm
    the diagnosis, then suggest the fix.
  • Always note assumptions (indexes you assumed exist, NLS settings, etc.)
    in a final "Assumptions" section.

==========================================================================
TONE
Direct, technical, professional. You are talking to a developer or DBA,
not a beginner. Skip the pleasantries. No emojis.`;

function mapHistoryToGemini(messages: ChatMessage[]): { role: string; parts: { text: string }[] }[] {
  // Gemini expects role "user" | "model" (NOT "assistant").
  // It also requires the conversation to alternate strictly user → model →
  // user → model and to end with the user's last message — which is exactly
  // what the frontend sends.
  return messages.map((m) => ({
    role: m.role === "assistant" ? "model" : "user",
    parts: [{ text: m.content }],
  }));
}

async function callGeminiChat(messages: ChatMessage[]): Promise<{ text: string; model: string }> {
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) throw new LlmConfigError("GEMINI_API_KEY is missing in frontend/.env.local.");
  const model = process.env.GEMINI_MODEL || "gemini-2.5-flash";
  const client = new GoogleGenAI({ apiKey });
  const res = await client.models.generateContent({
    model,
    contents: mapHistoryToGemini(messages),
    config: {
      systemInstruction: CHAT_SYSTEM_PROMPT,
      temperature: 0.4,
      maxOutputTokens: 8192,
      // No structured JSON for chat — we want natural Markdown.
      // Disable thinking budget so the entire output budget goes to the reply.
      thinkingConfig: { thinkingBudget: 0 },
    },
  });

  const finish = res.candidates?.[0]?.finishReason;
  if (finish && finish !== "STOP") {
    throw new Error(
      `Gemini stopped with finishReason=${finish}. ` +
        (finish === "MAX_TOKENS"
          ? "Reply was truncated — try a more focused question."
          : "Try again or rephrase the question."),
    );
  }
  return { text: res.text ?? "", model };
}

async function callAnthropicChat(messages: ChatMessage[]): Promise<{ text: string; model: string }> {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) throw new LlmConfigError("ANTHROPIC_API_KEY is missing in frontend/.env.local.");
  const model = process.env.ANTHROPIC_MODEL || "claude-sonnet-4-6";
  const client = new Anthropic({ apiKey });
  const message = await client.messages.create({
    model,
    max_tokens: 8192,
    system: CHAT_SYSTEM_PROMPT,
    messages: messages.map((m) => ({ role: m.role, content: m.content })),
  });
  const text = message.content[0]?.type === "text" ? message.content[0].text : "";
  return { text, model };
}

// ============================================================================
// CLAUDE CODE — uses @anthropic-ai/claude-agent-sdk
// ============================================================================
// The agent SDK spawns the local `claude` CLI binary, which authenticates via
// the user's existing Claude Code OAuth credentials (~/.claude/...) OR falls
// back to ANTHROPIC_API_KEY if set. Great for local dev where the user
// already has a Claude Code subscription — no separate API key needed.
//
// We disable all built-in tools (Read/Bash/etc.) and cap maxTurns=1 so this
// behaves like a single-shot LLM call rather than an agentic loop. Output
// flows through the result message's `result` string field.
//
// Dynamic import lets us keep the SDK out of the bundle when this provider
// isn't selected, and gives a clean error if the package or CLI is missing.

async function runClaudeCodeQuery(
  prompt: string,
  systemPrompt: string,
): Promise<{ text: string; model: string }> {
  let querySdk: typeof import("@anthropic-ai/claude-agent-sdk").query;
  try {
    ({ query: querySdk } = await import("@anthropic-ai/claude-agent-sdk"));
  } catch {
    throw new LlmConfigError(
      "@anthropic-ai/claude-agent-sdk is not installed. Run `npm install @anthropic-ai/claude-agent-sdk` in frontend/.",
    );
  }

  const model = process.env.CLAUDE_CODE_MODEL || "sonnet";
  const messages = querySdk({
    prompt,
    options: {
      systemPrompt,
      model,
      // No tools — this is a one-shot LLM call, not an agent.
      tools: [],
      maxTurns: 1,
    },
  });

  let resultText = "";
  let errorReason: string | null = null;
  try {
    for await (const m of messages) {
      if (m.type === "result") {
        if (m.subtype === "success") {
          resultText = m.result ?? "";
        } else {
          errorReason = `Claude Code ${m.subtype} (${m.errors?.join("; ") || "no detail"})`;
        }
        break;
      }
    }
  } catch (err) {
    const raw = err instanceof Error ? err.message : String(err);
    // The CLI not being installed is the most common failure here — give a
    // clearer message than the SDK's raw ENOENT.
    if (/ENOENT|spawn.*claude|not found/i.test(raw)) {
      throw new LlmConfigError(
        "Claude Code CLI is not installed or not in PATH. Install it from claude.com/code and run `claude login`, or pick a different AI provider.",
      );
    }
    throw new Error(`Claude Code SDK error: ${raw}`);
  }

  if (errorReason) throw new Error(errorReason);
  if (!resultText) {
    throw new Error("Claude Code returned no result. Check `claude login` status or pick a different provider.");
  }
  return { text: resultText, model: `claude-code/${model}` };
}

async function callClaudeCode(prompt: string): Promise<{ text: string; model: string }> {
  return runClaudeCodeQuery(prompt, SYSTEM_PROMPT);
}

async function callClaudeCodeChat(messages: ChatMessage[]): Promise<{ text: string; model: string }> {
  // Single-prompt mode — concatenate the history into one user prompt with
  // explicit role markers. The model handles multi-turn context fine when
  // it's presented this way; we avoid the SDK's session machinery so each
  // request stays stateless (matching the existing /api/chat contract).
  const flat = messages
    .map((m) => `${m.role === "user" ? "USER" : "ASSISTANT"}: ${m.content}`)
    .join("\n\n");
  return runClaudeCodeQuery(flat, CHAT_SYSTEM_PROMPT);
}

export async function generateChatReply(
  messages: ChatMessage[],
  providerOverride?: string | null,
): Promise<ChatReply> {
  if (!Array.isArray(messages) || messages.length === 0) {
    throw new Error("At least one message is required.");
  }
  if (messages[messages.length - 1].role !== "user") {
    throw new Error("Last message must be from the user.");
  }
  const provider = pickProvider(providerOverride);
  const { text, model } =
    provider === "gemini"      ? await callGeminiChat(messages)     :
    provider === "anthropic"   ? await callAnthropicChat(messages)  :
    /* claude-code */            await callClaudeCodeChat(messages);
  return { content: text.trim(), provider, model };
}

export async function generateRewrite(
  req: RewriteRequest,
  providerOverride?: string | null,
): Promise<AIAnalysis> {
  const provider = pickProvider(providerOverride);
  const prompt = buildUserPrompt(req);

  const { text, model } =
    provider === "gemini"    ? await callGemini(prompt)    :
    provider === "anthropic" ? await callAnthropic(prompt) :
    /* claude-code */          await callClaudeCode(prompt);

  // Strip accidental markdown fences and isolate the JSON object.
  const cleaned = text.replace(/^```(?:json)?\s*/i, "").replace(/\s*```\s*$/i, "").trim();
  const match = cleaned.match(/\{[\s\S]*\}/);
  if (!match) {
    throw new Error(
      `AI (${provider}/${model}) returned an unrecognised format. First 200 chars: ${text.slice(0, 200)}`,
    );
  }

  let parsed: Omit<AIAnalysis, "provider" | "model">;
  try {
    parsed = JSON.parse(match[0]);
  } catch (e) {
    throw new Error(
      `AI (${provider}/${model}) returned invalid JSON: ${e instanceof Error ? e.message : String(e)}`,
    );
  }

  return { ...parsed, provider, model };
}

// ============================================================================
// CHAT — STREAMING variant
// ----------------------------------------------------------------------------
// generateChatReplyStream yields incremental events the route handler can
// forward to the browser as the model emits tokens. Each event is one of:
//   { type: "meta",  provider, model }   — once, at the start
//   { type: "delta", text }              — many, as tokens arrive
//   { type: "done"  }                    — once, when finished
//   { type: "error", message }           — instead of "done" on failure
//
// The non-streaming generateChatReply() above stays available for callers
// that just want the final string; the route uses this one so the UI can
// render tokens as they arrive (ChatGPT / Claude style).
// ============================================================================

export type ChatStreamEvent =
  | { type: "meta";  provider: LlmProvider; model: string }
  | { type: "delta"; text: string }
  | { type: "done" }
  | { type: "error"; message: string; code?: "LLM_CONFIG" | "RATE_LIMIT" };

export async function* generateChatReplyStream(
  messages: ChatMessage[],
  providerOverride?: string | null,
): AsyncGenerator<ChatStreamEvent, void, void> {
  if (!Array.isArray(messages) || messages.length === 0) {
    yield { type: "error", message: "At least one message is required." };
    return;
  }
  if (messages[messages.length - 1].role !== "user") {
    yield { type: "error", message: "Last message must be from the user." };
    return;
  }

  let provider: LlmProvider;
  try {
    provider = pickProvider(providerOverride);
  } catch (err) {
    if (err instanceof LlmConfigError) {
      yield { type: "error", message: err.message, code: "LLM_CONFIG" };
      return;
    }
    yield { type: "error", message: err instanceof Error ? err.message : String(err) };
    return;
  }

  // Resolve the model name before streaming starts so the meta event has it.
  // Each provider falls back to a sensible default when no env override is set.
  const model =
    provider === "gemini"
      ? (process.env.GEMINI_MODEL || "gemini-2.5-flash")
      : provider === "anthropic"
      ? (process.env.ANTHROPIC_MODEL || "claude-sonnet-4-6")
      : `claude-code/${process.env.CLAUDE_CODE_MODEL || "sonnet"}`;
  yield { type: "meta", provider, model };

  try {
    const tokenStream =
      provider === "gemini"      ? streamGeminiChat(messages)     :
      provider === "anthropic"   ? streamAnthropicChat(messages)  :
      /* claude-code */            streamClaudeCodeChat(messages);
    for await (const text of tokenStream) {
      if (text) yield { type: "delta", text };
    }
    yield { type: "done" };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const isRateLimit = /429|quota|rate.?limit|RESOURCE_EXHAUSTED/i.test(msg);
    yield {
      type: "error",
      message: isRateLimit
        ? "The free-tier rate limit was exceeded. Wait ~1 minute (or check your daily quota at aistudio.google.com) and try again."
        : msg,
      code: isRateLimit ? "RATE_LIMIT" : undefined,
    };
  }
}

// --- Gemini streaming ---
async function* streamGeminiChat(messages: ChatMessage[]): AsyncGenerator<string, void, void> {
  const apiKey = process.env.GEMINI_API_KEY;
  if (!apiKey) throw new LlmConfigError("GEMINI_API_KEY is missing in frontend/.env.local.");
  const model = process.env.GEMINI_MODEL || "gemini-2.5-flash";
  const client = new GoogleGenAI({ apiKey });
  const stream = await client.models.generateContentStream({
    model,
    contents: mapHistoryToGemini(messages),
    config: {
      systemInstruction: CHAT_SYSTEM_PROMPT,
      temperature: 0.4,
      maxOutputTokens: 8192,
      thinkingConfig: { thinkingBudget: 0 },
    },
  });
  for await (const chunk of stream) {
    const t = chunk.text;
    if (t) yield t;
  }
}

// --- Anthropic streaming ---
async function* streamAnthropicChat(messages: ChatMessage[]): AsyncGenerator<string, void, void> {
  const apiKey = process.env.ANTHROPIC_API_KEY;
  if (!apiKey) throw new LlmConfigError("ANTHROPIC_API_KEY is missing in frontend/.env.local.");
  const model = process.env.ANTHROPIC_MODEL || "claude-sonnet-4-6";
  const client = new Anthropic({ apiKey });
  const stream = client.messages.stream({
    model,
    max_tokens: 8192,
    system: CHAT_SYSTEM_PROMPT,
    messages: messages.map((m) => ({ role: m.role, content: m.content })),
  });
  for await (const event of stream) {
    if (
      event.type === "content_block_delta" &&
      event.delta.type === "text_delta" &&
      event.delta.text
    ) {
      yield event.delta.text;
    }
  }
}

// --- Claude Code streaming ---
// Reuses the same prompt-flattening as the non-streaming path (concatenate
// USER:/ASSISTANT: turns) so server-side scope guard stays identical. The SDK
// emits `stream_event` envelopes wrapping Anthropic's raw deltas when
// includePartialMessages: true is set.
async function* streamClaudeCodeChat(messages: ChatMessage[]): AsyncGenerator<string, void, void> {
  let querySdk: typeof import("@anthropic-ai/claude-agent-sdk").query;
  try {
    ({ query: querySdk } = await import("@anthropic-ai/claude-agent-sdk"));
  } catch {
    throw new LlmConfigError(
      "@anthropic-ai/claude-agent-sdk is not installed. Run `npm install @anthropic-ai/claude-agent-sdk` in frontend/.",
    );
  }
  const flat = messages
    .map((m) => `${m.role === "user" ? "USER" : "ASSISTANT"}: ${m.content}`)
    .join("\n\n");
  const model = process.env.CLAUDE_CODE_MODEL || "sonnet";

  let sawAnyText = false;
  try {
    const q = querySdk({
      prompt: flat,
      options: {
        systemPrompt: CHAT_SYSTEM_PROMPT,
        model,
        tools: [],
        maxTurns: 1,
        includePartialMessages: true,
      },
    });
    for await (const m of q) {
      if (m.type === "stream_event") {
        const ev = m.event;
        if (
          ev.type === "content_block_delta" &&
          ev.delta.type === "text_delta" &&
          ev.delta.text
        ) {
          sawAnyText = true;
          yield ev.delta.text;
        }
      } else if (m.type === "result") {
        // If the SDK didn't emit partial deltas (older Claude Code build),
        // fall back to emitting the final text in one chunk so the user
        // still sees a reply.
        if (!sawAnyText && m.subtype === "success" && m.result) {
          yield m.result;
        }
        if (m.subtype !== "success") {
          throw new Error(
            `Claude Code ${m.subtype}` +
              (m.errors?.length ? `: ${m.errors.join("; ")}` : ""),
          );
        }
        break;
      }
    }
  } catch (err) {
    const raw = err instanceof Error ? err.message : String(err);
    if (/ENOENT|spawn.*claude|not found/i.test(raw)) {
      throw new LlmConfigError(
        "Claude Code CLI is not installed or not in PATH. Install it from claude.com/code and run `claude login`, or pick a different AI provider.",
      );
    }
    throw err;
  }
}
