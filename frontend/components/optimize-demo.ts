// Type definitions for the OptimizeResult pipeline.
//
// Originally this file also hosted a fakeOptimize() generator + a hardcoded
// PLAN_AFTER demo plan. Those were removed once the real backend was wired —
// the PLAN_AFTER constant was leaking HR-schema fake data into the Plan tab's
// "After" toggle (Bug #24). The toggle is gone too; only types remain.

export type RuleSeverity = "high" | "medium" | "low";

export type RuleHit = {
  id: string;
  title: string;
  severity: RuleSeverity;
  detail: string;
  fix: string;
};

export type PlanRow = {
  id: number;
  op: string;          // operation, e.g. "TABLE ACCESS FULL"
  obj?: string;        // object name
  cost: number;
  rows: number;
  time: string;        // formatted time, e.g. "00:00:01"
  bytes?: string;
  depth: number;
};

export type BenchmarkDecision = "ORIGINAL_FASTEST" | "OPTIMIZED_SELECTED" | "NO_VALID_QUERY";

export type ResultsMatch = "YES" | "NO" | "ROW_COUNT" | "N/A";

export type BenchmarkCandidate = {
  label: string;
  avg_ms: number | null;
  min_ms: number | null;
  max_ms: number | null;
  results_match: ResultsMatch;
  is_valid: "Y" | "N";
  validation_msg: string;
};

export type BenchmarkMeta = {
  decision: BenchmarkDecision;
  winner: string;
  speedup_factor: number;
  reasoning: string;
  iterations_run: number;
  candidates: BenchmarkCandidate[];
  error?: string;
};

export type Benchmark = {
  before: { ms: number; cost: number; rows: number };
  after:  { ms: number; cost: number; rows: number };
  meta?: BenchmarkMeta;
};

export type PlanNode = {
  id: number;
  parent_id: number | null;
  depth: number;
  position: number | null;
  operation: string;
  options: string | null;
  object_owner: string | null;
  object_name: string | null;
  object_type: string | null;
  cost: number | null;
  cardinality: number | null;
  bytes: number | null;
  cpu_cost: number | null;
  io_cost: number | null;
  partition_start: string | null;
  partition_stop: string | null;
  access_predicates: string | null;
  filter_predicates: string | null;
  projection: string | null;
  time: number | null;
  qblock_name: string | null;
};

// Structured AI insights from /api/analyze, separated from the rewrite SQL
// so the Rewrite tab can stay pure-code and the Recommendation tab can
// render diagnosis + rationale + trade-offs as proper UI sections.
// Optional because the AI call is best-effort — Phase 1/2/4 still produce
// useful output when this step fails.
export type AiAnalysisSummary = {
  decision: "ALREADY_OPTIMIZED" | "NEEDS_IMPROVEMENT" | "POOR";
  confidence: number;                  // 0.0 - 1.0
  issues: string[];                    // what's wrong with the original
  explanation: {
    why_inefficient: string;
    why_better: string;
    trade_offs: string;
  };
  // Optional list of full Oracle `CREATE INDEX …` DDL strings. Merged from
  // (a) the rule engine's deterministic MISSING_INDEX_ON_FILTER / AGGREGATE_
  // INDEX_HINT output and (b) anything the AI emitted in
  // `recommended_indexes`. Deduplicated by normalised DDL text. Empty /
  // absent when no index would meaningfully change the access path.
  recommended_indexes?: string[];
  candidate_label: string;             // e.g. "ANSI joins + DATE literal"
  provider: string;                    // "gemini" | "anthropic" | "claude-code"
  model: string;
};

export type OptimizeResult = {
  rules: RuleHit[];
  plan: PlanRow[];
  planTree?: PlanNode[];
  rewrite: string;
  aiAnalysis?: AiAnalysisSummary;
  benchmark: Benchmark;
  summary: string;
};

