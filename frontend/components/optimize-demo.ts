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

export type OptimizeResult = {
  rules: RuleHit[];
  plan: PlanRow[];
  planTree?: PlanNode[];
  rewrite: string;
  benchmark: Benchmark;
  summary: string;
};

