import type {
  OptimizeResult,
  PlanRow,
  RuleHit,
  RuleSeverity,
  BenchmarkMeta,
  BenchmarkDecision,
  PlanNode,
} from "@/components/optimize-demo";
import type { ConnectionInfo } from "@/components/ConnectionModal";

interface OracleTriggeredRule {
  rule_name: string;
  category: string;
  severity: "HIGH" | "MEDIUM" | "LOW";
  description: string;
  recommendation: string;
  context: string;
  index_recommendation: string | null;
  optimized_fragment: string | null;
}

interface OracleAnalyzeResponse {
  status?: string;
  message?: string;
  query_log_id?: number | null;
  query?: string;
  rule_summary?: {
    total_rules_evaluated: number;
    rules_triggered: number;
    high_severity: number;
    medium_severity: number;
    low_severity: number;
  };
  triggered_rules?: OracleTriggeredRule[];
  plan_analysis?: {
    cost?: number;
    rows?: number;
  } | null;
  raw_plan?: string;
  execution_time_ms?: number;
  error?: string;
}

const sevMap: Record<"HIGH" | "MEDIUM" | "LOW", RuleSeverity> = {
  HIGH: "high",
  MEDIUM: "medium",
  LOW: "low",
};

function ruleTitle(name: string): string {
  return name
    .toLowerCase()
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

function mapTriggered(rules: OracleTriggeredRule[]): RuleHit[] {
  return rules.map((r, i) => {
    const detail =
      r.context && r.context.trim().length > 0
        ? `${r.description}\n\nContext: ${r.context}`
        : r.description;
    const fixParts: string[] = [];
    if (r.recommendation) fixParts.push(r.recommendation);
    if (r.optimized_fragment) fixParts.push(r.optimized_fragment);
    if (r.index_recommendation) fixParts.push(r.index_recommendation);
    return {
      id: `${r.rule_name}-${i}`,
      title: ruleTitle(r.rule_name),
      severity: sevMap[r.severity] ?? "low",
      detail,
      fix: fixParts.join("\n\n") || "No specific fix available.",
    };
  });
}

// Parse DBMS_XPLAN.DISPLAY text into PlanRow[].
//
// Typical layout (column widths vary):
//   ----------------------------------------
//   | Id  | Operation        | Name | Cost ...
//   ----------------------------------------
//   |  0 | SELECT STATEMENT  |       | 5 (0)| 00:00:01 |
//   |* 1 |  TABLE ACCESS FULL| EMPLO | 3 (0)| 00:00:01 |
//
// Depth is inferred from leading spaces inside the Operation cell.
export function parsePlan(rawPlan: string): PlanRow[] {
  if (!rawPlan) return [];
  const lines = rawPlan.split(/\r?\n/);
  const rows: PlanRow[] = [];

  // Locate header to figure out column boundaries
  let headerIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (/\|\s*Id\s*\|/.test(lines[i])) {
      headerIdx = i;
      break;
    }
  }
  if (headerIdx === -1) return [];

  const header = lines[headerIdx];
  // Indices of '|' characters define column boundaries
  const sep: number[] = [];
  for (let i = 0; i < header.length; i++) {
    if (header[i] === "|") sep.push(i);
  }
  // Headers between separators
  const headers = sep
    .slice(0, -1)
    .map((s, i) => header.substring(s + 1, sep[i + 1]).trim().toLowerCase());

  const colIndex = (name: string) => headers.findIndex((h) => h.includes(name));
  const idCol = colIndex("id");
  const opCol = colIndex("operation");
  const nameCol = colIndex("name");
  const costCol = colIndex("cost");
  const rowsColIdx = colIndex("rows");
  const timeColIdx = colIndex("time");

  for (let i = headerIdx + 1; i < lines.length; i++) {
    const line = lines[i];
    if (!line.includes("|")) continue;
    if (/^[-]+$/.test(line.replace(/\s/g, ""))) continue;
    const cells = sep
      .slice(0, -1)
      .map((s, k) => line.substring(s + 1, sep[k + 1]));
    if (cells.length === 0) continue;

    const idCell = (cells[idCol] || "").replace(/\*/g, "").trim();
    const id = parseInt(idCell, 10);
    if (Number.isNaN(id)) continue;

    const opCellRaw = cells[opCol] || "";
    const opTrim = opCellRaw.trim();
    if (!opTrim) continue;

    // Depth = leading spaces inside operation cell ÷ 1 (DBMS_XPLAN uses 1 space per level)
    const leading = opCellRaw.length - opCellRaw.replace(/^\s+/, "").length;
    const depth = Math.max(0, leading - 1);

    const nameCell = ((nameCol >= 0 ? cells[nameCol] : "") || "").trim();
    const costRaw = ((costCol >= 0 ? cells[costCol] : "") || "").trim();
    const rowsRaw = ((rowsColIdx >= 0 ? cells[rowsColIdx] : "") || "").trim();
    const timeRaw = ((timeColIdx >= 0 ? cells[timeColIdx] : "") || "").trim();

    // Cost cells often look like "5 (0)" — strip the percentage
    const costMatch = costRaw.match(/^[\d,]+/);
    const cost = costMatch ? parseInt(costMatch[0].replace(/,/g, ""), 10) : 0;
    const rowsNum = parseInt(rowsRaw.replace(/,/g, ""), 10);

    rows.push({
      id,
      op: opTrim,
      obj: nameCell || undefined,
      cost: Number.isNaN(cost) ? 0 : cost,
      rows: Number.isNaN(rowsNum) ? 0 : rowsNum,
      time: timeRaw || "—",
      depth,
    });
  }

  return rows;
}

export interface OptimizeError {
  kind: "connection" | "oracle" | "network";
  message: string;
}

interface TableSchemaMeta {
  name: string;
  owner: string | null;
  rows: number | null;
  blocks: number | null;
  avg_row_len: number | null;
  last_analyzed: string | null;
  partitioned: boolean;
  primary_key: string[];
  unique_keys: string[][];
  foreign_keys: {
    name: string;
    columns: string[];
    references_table: string;
    references_columns: string[];
  }[];
  indexes: { name: string; unique: boolean; columns: string[] }[];
  columns: {
    name: string;
    type: string;
    nullable: boolean;
    num_distinct: number | null;
    num_nulls: number | null;
    density: number | null;
  }[];
}

// Pull table identifiers after FROM / JOIN. Strips reserved keywords that
// can sit in those positions (DUAL, LATERAL, etc.). Best-effort only — the
// schema endpoint validates that each name actually exists in ALL_TABLES.
function extractTableNames(query: string): string[] {
  const out = new Set<string>();
  const RESERVED = new Set(["SELECT", "DUAL", "LATERAL", "TABLE", "XMLTABLE"]);
  const re = /\b(?:FROM|JOIN)\s+([A-Za-z][A-Za-z0-9_$#]*)/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(query)) !== null) {
    const ident = m[1].toUpperCase();
    if (!RESERVED.has(ident)) out.add(ident);
  }
  return Array.from(out);
}

// Renders the schema payload as a compact, LLM-readable text block. The LLM
// reads this verbatim — the format mirrors the table summary block the rule
// engine was supposed to emit, so the SYSTEM_PROMPT's "schema metadata"
// guidance applies cleanly.
function formatSchemaForLlm(tables: TableSchemaMeta[]): string {
  if (tables.length === 0) return "";
  return tables
    .map((t) => {
      const rows = t.rows != null ? t.rows.toLocaleString() : "<no stats>";
      const blocks = t.blocks != null ? t.blocks.toLocaleString() : "<no stats>";
      const arl = t.avg_row_len != null ? `${t.avg_row_len} bytes` : "<no stats>";
      const stale = t.last_analyzed ? `last analyzed ${t.last_analyzed}` : "stats never gathered";
      const pk = t.primary_key.length > 0 ? t.primary_key.join(", ") : "<none>";
      const ukLines = t.unique_keys.length
        ? t.unique_keys.map((u) => `--                ${u.join(", ")}`).join("\n")
        : "--                <none>";
      const fkLines = t.foreign_keys.length
        ? t.foreign_keys
            .map(
              (f) =>
                `--     ${f.name}: (${f.columns.join(", ")}) -> ${f.references_table}(${f.references_columns.join(", ")})`,
            )
            .join("\n")
        : "--     <none>";
      const idxLines = t.indexes.length
        ? t.indexes
            .map(
              (i) =>
                `--     ${i.unique ? "UNIQUE   " : "NONUNIQUE"} ${i.name}(${i.columns.join(", ")})`,
            )
            .join("\n")
        : "--     <none>";

      // Column rendering — include type + null + selectivity (NDV) so the
      // LLM can pick the most-selective predicate first.
      const colLines = t.columns
        .slice(0, 30)
        .map((c) => {
          const sel =
            c.num_distinct != null && t.rows && t.rows > 0
              ? ` ndv=${c.num_distinct.toLocaleString()} (${((c.num_distinct / t.rows) * 100).toFixed(2)}% selectivity)`
              : "";
          const nul = c.nullable ? " NULL" : " NOT NULL";
          return `--     ${c.name.padEnd(28)} ${c.type}${nul}${sel}`;
        })
        .join("\n");
      const colTail =
        t.columns.length > 30 ? `\n--     ... (${t.columns.length - 30} more columns)` : "";

      return [
        `-- ============================================`,
        `-- TABLE: ${t.owner ? `${t.owner}.` : ""}${t.name}${t.partitioned ? "  [PARTITIONED]" : ""}`,
        `--   Rows:        ${rows}`,
        `--   Blocks:      ${blocks}`,
        `--   Avg row len: ${arl}`,
        `--   Stats:       ${stale}`,
        `--   Primary key: ${pk}`,
        `--   Unique keys:`,
        ukLines,
        `--   Foreign keys:`,
        fkLines,
        `--   Indexes:`,
        idxLines,
        `--   Columns (name | type | nullability | selectivity):`,
        colLines + colTail,
      ].join("\n");
    })
    .join("\n");
}

export async function optimizeQuery(
  connection: ConnectionInfo,
  query: string,
): Promise<{ result: OptimizeResult; logId: number | null } | { error: OptimizeError }> {
  let res: Response;
  try {
    res = await fetch("/api/oracle/analyze", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        connection: {
          host: connection.host,
          port: connection.port,
          serviceName: connection.service,
          user: connection.user,
          password: connection.password,
        },
        query,
      }),
    });
  } catch (err) {
    return {
      error: {
        kind: "network",
        message: err instanceof Error ? err.message : "Network error",
      },
    };
  }

  let data: OracleAnalyzeResponse;
  try {
    data = (await res.json()) as OracleAnalyzeResponse;
  } catch (err) {
    return {
      error: {
        kind: "network",
        message: err instanceof Error ? err.message : "Bad JSON response",
      },
    };
  }

  if (!res.ok) {
    return {
      error: {
        kind: res.status === 503 ? "connection" : "oracle",
        message: data.error || data.message || `HTTP ${res.status}`,
      },
    };
  }

  const triggered = data.triggered_rules ?? [];
  const rules = mapTriggered(triggered);
  const plan = parsePlan(data.raw_plan ?? "");
  const summary = (() => {
    const high = data.rule_summary?.high_severity ?? 0;
    const medium = data.rule_summary?.medium_severity ?? 0;
    const low = data.rule_summary?.low_severity ?? 0;
    // Severity sum is the row count in QUERY_RULE_RESULTS — the meaningful
    // "findings" number. The separate rules_triggered counter only tells how
    // many rule procedures fired (rules that emit multiple rows would be
    // under-counted), so we ignore it for the summary.
    const total = high + medium + low;
    if (total === 0) {
      return "Oracle analysis complete. No optimization rules triggered for this query.";
    }
    return `Oracle analysis complete in ${data.execution_time_ms ?? "?"} ms — ${total} finding(s) (${high} high · ${medium} medium · ${low} low).`;
  })();

  // Prefer the parsed-plan root row's cost over `plan_analysis.cost`. The
  // PL/SQL `plan_analysis` field has historically reported a non-root cost
  // (e.g. an inner step) and disagreed with the flowchart's root, so the
  // summary banner showed one number while the flowchart showed another.
  // `plan[0]` is the SELECT STATEMENT root from DBMS_XPLAN.DISPLAY — the
  // canonical "plan cost" Oracle reports.
  const cost = plan[0]?.cost ?? data.plan_analysis?.cost ?? 0;
  const rowsEst = plan[0]?.rows ?? data.plan_analysis?.rows ?? 0;

  // Phase 3 — AI rewrite. We run this after Oracle's analysis so the LLM has
  // the rule findings + plan + schema/index metadata as grounding context.
  // Failure here is non-fatal: the user still gets the Oracle analysis even
  // if the LLM call fails.
  //
  // We forward THREE kinds of context to the LLM, in addition to the query:
  //   1. The rule findings (what anti-patterns the engine detected).
  //   2. A "schema" block built from TABLE_CONTEXT_SUMMARY rule fragments —
  //      one per referenced table, with rows / blocks / PK / index list.
  //      This is the ground truth the LLM needs to reason about predicate
  //      pushdown, join ordering, and which existing indexes to leverage.
  //   3. An "indexes" block aggregating any CREATE INDEX DDL the rule engine
  //      suggested (from MISSING_INDEX_ON_FILTER / AGGREGATE_INDEX_HINT).
  const ruleSummaries = triggered.map((r) => ({
    name: r.rule_name,
    severity: r.severity,
    description:
      r.context && r.context.trim().length > 0
        ? `${r.description} | context: ${r.context}`
        : r.description,
  }));

  // Fetch structured plan tree (id + parent_id + predicates per node) so the
  // UI can render a flowchart instead of just the DBMS_XPLAN text. Best-effort.
  let planTree: PlanNode[] | undefined;
  try {
    const ptRes = await fetch("/api/oracle/plan-tree", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        connection: {
          host: connection.host,
          port: connection.port,
          serviceName: connection.service,
          user: connection.user,
          password: connection.password,
        },
        query,
      }),
    });
    if (ptRes.ok) {
      const ptData = (await ptRes.json()) as { nodes?: PlanNode[] };
      planTree = ptData.nodes;
    }
  } catch { /* plan tree is best-effort context for the flowchart */ }

  // Pull live schema metadata for every table the query references. This is
  // independent of (and more reliable than) the rule engine's TABLE_CONTEXT_SUMMARY.
  const tableNames = extractTableNames(query);
  let schemaBlock = "";
  if (tableNames.length > 0) {
    try {
      const schemaRes = await fetch("/api/oracle/schema", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          connection: {
            host: connection.host,
            port: connection.port,
            serviceName: connection.service,
            user: connection.user,
            password: connection.password,
          },
          tables: tableNames,
        }),
      });
      if (schemaRes.ok) {
        const schemaData = (await schemaRes.json()) as { tables?: TableSchemaMeta[] };
        schemaBlock = formatSchemaForLlm(schemaData.tables ?? []);
      }
    } catch { /* schema is best-effort context; AI rewrite still runs */ }
  }

  // Aggregate any CREATE INDEX DDL the rule engine suggested. The AI may
  // choose to use these as new indexes or to align rewrites with existing ones.
  const indexesBlock = triggered
    .filter((r) => r.index_recommendation && r.index_recommendation.trim().length > 0)
    .map((r) => r.index_recommendation)
    .join("\n\n");

  let aiRewrite = "";
  let aiError: string | null = null;
  let aiCandidates: { label: string; query: string; explanation: string }[] = [];
  try {
    const aiRes = await fetch("/api/analyze", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        query,
        plan: data.raw_plan,
        rules: ruleSummaries,
        schema: schemaBlock || undefined,
        indexes: indexesBlock || undefined,
      }),
    });
    const aiData = await aiRes.json();
    if (!aiRes.ok) {
      aiError = aiData.error || `HTTP ${aiRes.status}`;
    } else if (aiData.optimized_queries?.length) {
      aiCandidates = aiData.optimized_queries;
      const best = aiData.optimized_queries[0];
      const explainBlock = aiData.explanation?.why_better
        ? `\n\n-- Why this is better:\n-- ${aiData.explanation.why_better.replace(/\n/g, "\n-- ")}`
        : "";
      const tradeoffBlock = aiData.explanation?.trade_offs
        ? `\n\n-- Trade-offs:\n-- ${aiData.explanation.trade_offs.replace(/\n/g, "\n-- ")}`
        : "";
      aiRewrite = `-- ${best.label} (${aiData.provider}/${aiData.model}, confidence ${Math.round((aiData.confidence ?? 0) * 100)}%)\n${best.query}${explainBlock}${tradeoffBlock}`;
    }
  } catch (e) {
    aiError = e instanceof Error ? e.message : "AI request failed";
  }

  // Phase 4 — validate + benchmark every AI candidate against the original.
  // Same non-fatal pattern: a benchmark failure leaves the rest of the
  // OptimizeResult intact and the BenchTab shows a graceful empty state.
  let benchMeta: BenchmarkMeta | undefined;
  let beforeMs = data.execution_time_ms ?? 0;
  let afterMs  = data.execution_time_ms ?? 0;
  // Default rows to the optimizer's plan estimate (pre-execution guess); when
  // Phase 4 runs, we replace these with the ACTUAL row count it measured.
  let rowsBefore = rowsEst;
  let rowsAfter  = rowsEst;

  if (aiCandidates.length > 0) {
    try {
      const benchRes = await fetch("/api/oracle/benchmark", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          connection: {
            host: connection.host,
            port: connection.port,
            serviceName: connection.service,
            user: connection.user,
            password: connection.password,
          },
          originalQuery: query,
          optimizedQueries: aiCandidates.map((c) => c.query),
          iterations: 3,
        }),
      });
      const benchData = await benchRes.json();
      if (!benchRes.ok) {
        benchMeta = {
          decision: "NO_VALID_QUERY",
          winner: "",
          speedup_factor: 1,
          reasoning: "",
          iterations_run: 0,
          candidates: [],
          error: benchData.error || `HTTP ${benchRes.status}`,
        };
      } else {
        // Map to UI shape. Phase 4 returns a list of benchmarks where index 0
        // is the original (label "ORIGINAL"), followed by each candidate.
        type RawBench = {
          label: string;
          avg_exec_ms: number | null;
          min_exec_ms: number | null;
          max_exec_ms: number | null;
          results_match: "YES" | "NO" | "ROW_COUNT" | "N/A";
          is_valid: "Y" | "N";
          validation_msg: string;
          result_row_count?: number | null;
        };
        const rawBenches: RawBench[] = benchData.benchmarks ?? [];
        const candidates = rawBenches.map((b) => ({
          label: b.label,
          avg_ms: b.avg_exec_ms,
          min_ms: b.min_exec_ms,
          max_ms: b.max_exec_ms,
          results_match: b.results_match,
          is_valid: b.is_valid,
          validation_msg: b.validation_msg,
        }));

        const original    = candidates.find((c: { label: string }) => /original/i.test(c.label));
        const winner      = candidates.find((c: { label: string }) => c.label === benchData.winner);
        const originalRaw = rawBenches.find((b) => /original/i.test(b.label));
        const winnerRaw   = rawBenches.find((b) => b.label === benchData.winner);

        if (original?.avg_ms != null) beforeMs = original.avg_ms;
        if (winner?.avg_ms != null && benchData.decision === "OPTIMIZED_SELECTED") {
          afterMs = winner.avg_ms;
        } else {
          afterMs = beforeMs;
        }

        // Use the ACTUAL row counts measured by Phase 4 when available, not
        // the plan-cardinality estimate. The optimizer's plan rows is a
        // pre-execution guess and frequently diverges from reality by orders
        // of magnitude on joined queries.
        if (originalRaw?.result_row_count != null) {
          rowsBefore = originalRaw.result_row_count;
        }
        if (winnerRaw?.result_row_count != null && benchData.decision === "OPTIMIZED_SELECTED") {
          rowsAfter = winnerRaw.result_row_count;
        } else if (originalRaw?.result_row_count != null) {
          rowsAfter = originalRaw.result_row_count;
        }

        benchMeta = {
          decision: (benchData.decision ?? "NO_VALID_QUERY") as BenchmarkDecision,
          winner: benchData.winner ?? "",
          speedup_factor: benchData.speedup_factor ?? 1,
          reasoning: benchData.reasoning ?? "",
          iterations_run: benchData.iterations_run ?? 0,
          candidates,
        };
      }
    } catch (e) {
      benchMeta = {
        decision: "NO_VALID_QUERY",
        winner: "",
        speedup_factor: 1,
        reasoning: "",
        iterations_run: 0,
        candidates: [],
        error: e instanceof Error ? e.message : "Benchmark request failed",
      };
    }
  }

  const result: OptimizeResult = {
    rules,
    plan,
    planTree,
    rewrite: aiRewrite || (aiError ? `-- AI rewrite unavailable: ${aiError}` : ""),
    benchmark: {
      before: { ms: beforeMs, cost, rows: rowsBefore },
      after:  { ms: afterMs,  cost, rows: rowsAfter  },
      meta:   benchMeta,
    },
    summary,
  };

  return { result, logId: data.query_log_id ?? null };
}
