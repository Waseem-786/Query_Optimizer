"use client";

import * as React from "react";
import { createPortal } from "react-dom";
import { SqlBlock } from "./SqlBlock";
import { CopyButton } from "./CopyButton";
import {
  IcLayers, IcList, IcSparkles, IcGauge, IcAlert, IcInfo, IcCheck,
  IcChevronDown, IcChevronRight, IcTrendingDown, IcClock, IcX,
} from "./icons";
import type { OptimizeResult, PlanRow, RuleHit, RuleSeverity, PlanNode } from "./optimize-demo";
import { PlanFlowchart, PlanFlowchartLegend } from "./PlanFlowchart";

type Tab = "plan" | "rules" | "rewrite" | "benchmark";

const TABS: { id: Tab; label: string; icon: React.ComponentType<{size?: number; className?: string}> }[] = [
  { id: "plan",      label: "Plan",      icon: IcLayers },
  { id: "rules",     label: "Rules",     icon: IcList },
  { id: "rewrite",   label: "Rewrite",   icon: IcSparkles },
  { id: "benchmark", label: "Benchmark", icon: IcGauge },
];

const sevColor: Record<RuleSeverity, string> = {
  high:   "bg-danger-soft text-danger",
  medium: "bg-warn-soft text-warn",
  low:    "bg-info-soft text-info",
};
const sevIcon: Record<RuleSeverity, React.ComponentType<{size?: number; className?: string}>> = {
  high: IcAlert, medium: IcAlert, low: IcInfo,
};

function fmtMs(ms: number) {
  if (ms < 1000) return `${ms} ms`;
  return `${(ms / 1000).toFixed(2)} s`;
}

export function ResultsPanel({ result, busy, lastQuery }: {
  result: OptimizeResult | null;
  busy: boolean;
  lastQuery: string;
}) {
  const [tab, setTab] = React.useState<Tab>("plan");

  if (busy && !result) return <RunningState />;
  if (!result) return <EmptyState />;

  return (
    <div className="flex flex-col h-full bg-bg">
      {/* Tabs */}
      <div className="flex items-stretch border-b border-default bg-surface shrink-0">
        <div className="flex items-stretch flex-1 min-w-0 overflow-x-auto no-scrollbar">
          {TABS.map((t) => {
            const active = tab === t.id;
            const Icon = t.icon;
            return (
              <button
                key={t.id}
                onClick={() => setTab(t.id)}
                className={`px-3 h-11 flex items-center gap-1.5 text-[12.5px] font-medium border-b-2 transition-colors shrink-0 ${
                  active
                    ? "text-fg border-accent"
                    : "text-muted border-transparent hover:text-fg hover:bg-surface-2"
                }`}
              >
                <Icon size={13} />
                {t.label}
                {t.id === "rules" && (
                  <span className="pill !py-0 !px-1.5 !text-[10.5px]">{result.rules.length}</span>
                )}
              </button>
            );
          })}
        </div>
        <div className="self-center px-2 shrink-0 border-l border-default h-11 flex items-center">
          <CopyButton text={JSON.stringify(result, null, 2)} label="Export" />
        </div>
      </div>

      {/* Summary banner */}
      <div className="px-5 py-3 border-b border-default bg-surface-2/50 shrink-0 fade-up">
        <div className="flex items-start gap-3">
          <div className="w-8 h-8 rounded-lg bg-accent-soft border border-default flex items-center justify-center shrink-0">
            <IcSparkles size={14} className="text-accent" />
          </div>
          <div className="flex-1">
            <div className="text-[12.5px] text-fg leading-relaxed">{result.summary}</div>
            <div className="mt-1.5 flex flex-wrap gap-1.5">
              <Stat label="Cost" before={result.benchmark.before.cost} after={result.benchmark.after.cost} />
              <Stat label="Time" before={result.benchmark.before.ms} after={result.benchmark.after.ms} unit="ms" />
            </div>
          </div>
        </div>
      </div>

      {/* Tab content */}
      <div className="flex-1 overflow-y-auto">
        {tab === "plan" && (
          <PlanTab plan={result.plan} planTree={result.planTree} />
        )}
        {tab === "rules" && <RulesTab rules={result.rules} />}
        {tab === "rewrite" && <RewriteTab original={lastQuery} rewrite={result.rewrite} />}
        {tab === "benchmark" && <BenchTab b={result.benchmark} />}
      </div>
    </div>
  );
}

function Stat({ label, before, after, unit = "" }: {
  label: string; before: number; after: number; unit?: string;
}) {
  // The pill needs to handle four cases cleanly without regressing into
  // visual noise like "(-0%)" or "(--5%)" or "(NaN%)".
  //   • before === after        → "unchanged" (no percentage)
  //   • before > after  > 0     → improvement, "(−P%)"
  //   • before < after          → regression,  "(+P%)"  (NEVER "--P%")
  //   • before === 0            → division-by-zero; show only the values
  const isSame = before === after;
  const isZeroBaseline = before === 0;
  let trend: "improved" | "regressed" | "unchanged" = "unchanged";
  let pctText: string | null = null;
  if (!isSame && !isZeroBaseline) {
    const pct = Math.round(((before - after) / before) * 100);
    if (pct > 0) {
      trend = "improved";
      pctText = `(−${pct}%)`;
    } else if (pct < 0) {
      trend = "regressed";
      pctText = `(+${Math.abs(pct)}%)`;
    }
  }
  const pillColor =
    trend === "improved"  ? "bg-success-soft text-success" :
    trend === "regressed" ? "bg-danger-soft text-danger"   :
                            "bg-surface-2 text-muted";
  return (
    <span className={`pill ${pillColor} border-transparent`}>
      {trend !== "unchanged" && (
        <IcTrendingDown
          size={11}
          className={trend === "regressed" ? "rotate-180" : ""}
        />
      )}
      <span className="text-fg/80">{label}</span>
      <span className="font-mono-app">
        {before.toLocaleString()}{unit} → {after.toLocaleString()}{unit}
      </span>
      {pctText && <span className="opacity-80">{pctText}</span>}
    </span>
  );
}

type PlanView = "flowchart" | "table";

function PlanTab({ plan, planTree }: {
  plan: PlanRow[];
  planTree?: PlanNode[];
}) {
  const [view, setView] = React.useState<PlanView>(planTree && planTree.length > 0 ? "flowchart" : "table");
  const [fullscreen, setFullscreen] = React.useState(false);
  if ((!plan || plan.length === 0) && (!planTree || planTree.length === 0)) {
    return (
      <EmptyTabState
        icon={IcLayers}
        title="No execution plan available"
        body="Oracle did not return a plan for this query. Check the query is a SELECT, the connection is alive, and you have permission to run EXPLAIN PLAN against the referenced tables."
      />
    );
  }
  const maxCost = Math.max(...(plan?.map(p => p.cost) ?? [0]), 1);
  const flowchartAvailable = !!planTree && planTree.length > 0;
  return (
    <div className="p-5 fade-up">
      <div className="flex items-center justify-between mb-3 gap-3 flex-wrap">
        <div className="text-[13px] font-semibold">EXPLAIN PLAN</div>
        <div className="flex items-center gap-2">
          {flowchartAvailable && (
            <div className="bg-surface-2 border border-default rounded-md p-0.5 grid grid-cols-2 text-[11.5px] font-medium">
              <button
                onClick={() => setView("flowchart")}
                className={`px-2.5 py-1 rounded ${view === "flowchart" ? "bg-surface text-fg shadow-sm-app" : "text-muted"}`}
              >
                Flowchart
              </button>
              <button
                onClick={() => setView("table")}
                className={`px-2.5 py-1 rounded ${view === "table" ? "bg-surface text-fg shadow-sm-app" : "text-muted"}`}
              >
                Table
              </button>
            </div>
          )}
        </div>
      </div>

      {view === "flowchart" && flowchartAvailable && (
        <div className="space-y-3">
          <div className="flex items-center justify-between gap-3 flex-wrap">
            <PlanFlowchartLegend />
            <button
              onClick={() => setFullscreen(true)}
              className="btn btn-ghost text-[11.5px] px-2.5 py-1 inline-flex items-center gap-1.5 border border-default rounded-md"
              title="Open full-screen flowchart"
            >
              <IcLayers size={11} />
              Fullscreen
            </button>
          </div>
          <div className="card overflow-auto p-3" style={{ maxHeight: "70vh" }}>
            <PlanFlowchart nodes={planTree!} />
          </div>
          <PlanSummary nodes={planTree!} />
        </div>
      )}

      {fullscreen && flowchartAvailable && (
        <PlanFlowchartModal nodes={planTree!} onClose={() => setFullscreen(false)} />
      )}

      {(view === "table" || !flowchartAvailable) && (
      <>
      <div className="card overflow-x-auto">
        <table className="w-full text-[12.5px] font-mono-app min-w-[560px]">
          <thead className="bg-surface-2 text-muted">
            <tr className="text-left">
              <th className="px-3 py-2 font-medium">Operation</th>
              <th className="px-3 py-2 font-medium">Object</th>
              <th className="px-3 py-2 font-medium text-right w-[110px]">Cost</th>
              <th className="px-3 py-2 font-medium text-right w-[80px]">Rows</th>
              <th className="px-3 py-2 font-medium text-right w-[90px]">Time</th>
            </tr>
          </thead>
          <tbody>
            {plan.map((row) => {
              const isFull = row.op.includes("FULL");
              const isIndex = row.op.includes("INDEX");
              return (
                <tr key={row.id} className="border-t border-default">
                  <td className="px-3 py-2">
                    <span style={{ paddingLeft: `${row.depth * 14}px` }} className="inline-flex items-center gap-1.5">
                      <span className="text-dim">{row.depth > 0 && "└"}</span>
                      <span className={isFull ? "text-warn" : isIndex ? "text-success" : "text-fg"}>
                        {row.op}
                      </span>
                    </span>
                  </td>
                  <td className="px-3 py-2 text-muted">{row.obj ?? "—"}</td>
                  <td className="px-3 py-2 text-right">
                    <div className="inline-flex items-center gap-2 justify-end">
                      <div className="hidden sm:block w-16 h-1 rounded-full bg-surface-2 overflow-hidden">
                        <div
                          className={`h-full ${row.cost / maxCost > 0.5 ? "bg-warn" : "bg-success"}`}
                          style={{ width: `${(row.cost / maxCost) * 100}%` }}
                        />
                      </div>
                      <span className="tabular-nums">{row.cost.toLocaleString()}</span>
                    </div>
                  </td>
                  <td className="px-3 py-2 text-right text-muted tabular-nums">{row.rows.toLocaleString()}</td>
                  <td className="px-3 py-2 text-right text-muted tabular-nums">{row.time}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div className="mt-3 text-[11.5px] text-dim flex items-center gap-3 flex-wrap">
        <span className="inline-flex items-center gap-1.5"><span className="w-2 h-2 rounded-full bg-warn"/> Full scan</span>
        <span className="inline-flex items-center gap-1.5"><span className="w-2 h-2 rounded-full bg-success"/> Index access</span>
        <span className="inline-flex items-center gap-1.5"><span className="w-2 h-2 rounded-full bg-text-muted"/> Other</span>
      </div>
      </>
      )}
    </div>
  );
}

function PlanFlowchartModal({
  nodes,
  onClose,
}: {
  nodes: PlanNode[];
  onClose: () => void;
}) {
  // Close on Escape; lock body scroll while open
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prevOverflow;
    };
  }, [onClose]);

  // Portal to document.body so ancestor transforms (e.g. the fade-up
  // animation on PlanTab) don't trap our position:fixed modal inside the
  // results-panel column. Without this the dialog clips to that column.
  const [mounted, setMounted] = React.useState(false);
  React.useEffect(() => setMounted(true), []);
  if (!mounted) return null;

  return createPortal(
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
    >
      <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={onClose} />
      <div className="relative card shadow-lg-app w-[96vw] h-[94vh] flex flex-col overflow-hidden">
        <div className="flex items-center gap-3 px-5 py-3 border-b border-default shrink-0">
          <IcLayers size={15} className="text-accent" />
          <div className="flex-1">
            <div className="text-[13px] font-semibold">Execution plan — flowchart</div>
            <div className="text-[11.5px] text-muted">
              {nodes.length} operation{nodes.length === 1 ? "" : "s"} · drag to scroll · Esc to close
            </div>
          </div>
          <div className="hidden md:block">
            <PlanFlowchartLegend />
          </div>
          <button onClick={onClose} className="btn btn-ghost btn-icon ml-2" aria-label="Close fullscreen">
            <IcX size={15} />
          </button>
        </div>
        <div className="flex-1 min-h-0 overflow-auto p-4 bg-bg">
          <PlanFlowchart nodes={nodes} />
        </div>
      </div>
    </div>,
    document.body,
  );
}

function PlanSummary({ nodes }: { nodes: PlanNode[] }) {
  // Tabular accompaniment to the flowchart — pulls out the schema objects
  // touched (tables / indexes) plus a quick health-check on which operations
  // dominate the cost.
  const tables = new Set<string>();
  const indexes = new Set<string>();
  let totalCost = 0;
  const opCounts: Record<string, number> = {};
  for (const n of nodes) {
    if (n.cost != null && n.cost > totalCost) totalCost = n.cost; // root cost = max
    const key = (n.operation || "").toUpperCase();
    opCounts[key] = (opCounts[key] || 0) + 1;
    const objType = (n.object_type || "").toUpperCase();
    if (n.object_name) {
      if (objType.includes("INDEX")) indexes.add(n.object_name);
      else if (objType.includes("TABLE") || key.startsWith("TABLE ACCESS")) tables.add(n.object_name);
    }
  }
  const fullScans = nodes.filter((n) => n.operation === "TABLE ACCESS" && (n.options || "") === "FULL");

  return (
    <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
      <div className="card p-3">
        <div className="text-[10.5px] uppercase tracking-wide text-dim font-semibold mb-1.5">
          Tables touched
        </div>
        {tables.size > 0 ? (
          <ul className="text-[12px] font-mono-app space-y-0.5">
            {Array.from(tables).map((t) => (
              <li key={t} className="text-fg">{t}</li>
            ))}
          </ul>
        ) : (
          <div className="text-[12px] text-dim">none</div>
        )}
      </div>
      <div className="card p-3">
        <div className="text-[10.5px] uppercase tracking-wide text-dim font-semibold mb-1.5">
          Indexes used
        </div>
        {indexes.size > 0 ? (
          <ul className="text-[12px] font-mono-app space-y-0.5">
            {Array.from(indexes).map((i) => (
              <li key={i} className="text-success">{i}</li>
            ))}
          </ul>
        ) : (
          <div className="text-[12px] text-dim">none</div>
        )}
      </div>
      <div className="card p-3">
        <div className="text-[10.5px] uppercase tracking-wide text-dim font-semibold mb-1.5">
          Health check
        </div>
        <ul className="text-[12px] space-y-1">
          <li>
            Full table scans: <span className={fullScans.length > 0 ? "text-danger font-semibold" : "text-success"}>{fullScans.length}</span>
            {fullScans.length > 0 && (
              <span className="text-dim"> ({fullScans.map((n) => n.object_name).filter(Boolean).join(", ")})</span>
            )}
          </li>
          <li>Plan cost (root): <span className="text-fg tabular-nums font-mono-app">{totalCost.toLocaleString()}</span></li>
          <li>Total operations: <span className="text-fg tabular-nums">{nodes.length}</span></li>
        </ul>
      </div>
    </div>
  );
}

function RulesTab({ rules }: { rules: RuleHit[] }) {
  if (!rules || rules.length === 0) {
    return (
      <EmptyTabState
        icon={IcCheck}
        title="No rule violations"
        body="The rule engine found no anti-patterns in this query. Verify the analysis actually ran (Oracle returned a SUCCESS status) — if not, check the connection."
      />
    );
  }
  return (
    <div className="p-5 space-y-2.5 fade-up">
      {rules.map((r) => <RuleCard key={r.id} rule={r} />)}
    </div>
  );
}

function RuleCard({ rule }: { rule: RuleHit }) {
  const [open, setOpen] = React.useState(true);
  const Icon = sevIcon[rule.severity];
  return (
    <div className="card overflow-hidden">
      <button
        onClick={() => setOpen(!open)}
        className="w-full px-4 py-3 flex items-center gap-3 text-left hover:bg-surface-2 transition-colors"
      >
        <span className={`pill ${sevColor[rule.severity]} border-transparent uppercase tracking-wide`}>
          <Icon size={11} />
          {rule.severity}
        </span>
        <span className="flex-1 text-[13px] font-medium">{rule.title}</span>
        {open ? <IcChevronDown size={14} className="text-dim" /> : <IcChevronRight size={14} className="text-dim" />}
      </button>
      {open && (
        <div className="px-4 pb-4 pt-1 space-y-2.5 fade-up">
          <p className="text-[12.5px] text-muted leading-relaxed">{rule.detail}</p>
          <div className="flex gap-2 items-start">
            <div className="shrink-0 w-5 h-5 rounded-md bg-success-soft flex items-center justify-center mt-0.5">
              <IcCheck size={11} className="text-success" />
            </div>
            <p className="text-[12.5px] text-fg leading-relaxed flex-1">{rule.fix}</p>
          </div>
        </div>
      )}
    </div>
  );
}

function RewriteTab({ original, rewrite }: { original: string; rewrite: string }) {
  const trimmed = (rewrite ?? "").trim();
  const noRewrite =
    !trimmed ||
    /^--\s*$/.test(trimmed) ||
    /not\s+yet\s+wired|unavailable|not\s+available|not\s+generated/i.test(trimmed);
  // Pull the message after "AI rewrite unavailable:" / "not generated:" if present
  const errorMatch = trimmed.match(/(?:unavailable|not generated|not available):\s*(.+)/i);
  const errorMessage = errorMatch ? errorMatch[1].trim() : null;
  return (
    <div className="grid grid-cols-1 lg:grid-cols-2 gap-px bg-default fade-up h-full">
      <div className="bg-surface flex flex-col">
        <div className="px-4 h-9 border-b border-default flex items-center justify-between shrink-0">
          <div className="text-[11.5px] uppercase tracking-wide text-dim font-semibold">Original</div>
          <CopyButton text={original} />
        </div>
        <div className="overflow-auto p-4 flex-1">
          {original ? (
            <SqlBlock sql={original} />
          ) : (
            <div className="text-[12.5px] text-muted">No query submitted yet.</div>
          )}
        </div>
      </div>
      <div className="bg-surface flex flex-col">
        <div className="px-4 h-9 border-b border-default flex items-center justify-between shrink-0">
          <div className="text-[11.5px] uppercase tracking-wide font-semibold flex items-center gap-1.5">
            <IcSparkles size={11} className="text-accent" />
            <span className="text-gradient-brand">AI rewrite</span>
          </div>
          <CopyButton text={rewrite} />
        </div>
        <div className="overflow-auto p-4 flex-1">
          {noRewrite ? (
            <EmptyTabState
              compact
              icon={IcSparkles}
              title={errorMessage ? "AI rewrite failed" : "AI rewrite not generated"}
              body={
                errorMessage
                  ? errorMessage
                  : "The AI did not return a rewrite. Confirm GEMINI_API_KEY (or ANTHROPIC_API_KEY) is set in frontend/.env.local and that the dev server was restarted."
              }
            />
          ) : (
            <SqlBlock sql={rewrite} />
          )}
        </div>
      </div>
    </div>
  );
}

function BenchTab({ b }: { b: OptimizeResult["benchmark"] }) {
  const meta = b?.meta;

  // Hard-error path: the route returned a payload with an error string.
  if (meta?.error) {
    return (
      <EmptyTabState
        icon={IcGauge}
        title="Benchmark failed"
        body={meta.error}
      />
    );
  }

  // No AI candidates produced → benchmark wasn't even attempted.
  if (!meta && b.before.ms === b.after.ms && b.before.cost === b.after.cost && b.before.rows === b.after.rows) {
    return (
      <EmptyTabState
        icon={IcGauge}
        title="No benchmark data"
        body="The AI did not produce any rewrite candidates, so there was nothing to validate against the original. Check the Rewrite tab."
      />
    );
  }

  // NO_VALID_QUERY = candidates returned different rows or were rejected.
  if (meta?.decision === "NO_VALID_QUERY") {
    return (
      <div className="p-5 space-y-3 fade-up">
        <div className="card p-4 border-l-4 border-warn">
          <div className="text-[13px] font-semibold mb-1">No safe candidate</div>
          <div className="text-[12.5px] text-muted leading-relaxed">
            {meta.reasoning || "All AI rewrites either failed validation or returned a different result set than the original. The original query stays as the winner by default."}
          </div>
        </div>
        {meta.candidates.length > 0 && <CandidateTable candidates={meta.candidates} winner={meta.winner} />}
      </div>
    );
  }

  const speedup = meta?.speedup_factor ?? b.before.ms / Math.max(b.after.ms, 1);
  const iters = meta?.iterations_run ?? 0;
  return (
    <div className="p-5 fade-up space-y-5">
      {meta && (
        <div className="card p-4 border-l-4 border-success">
          <div className="flex items-center gap-2 text-[12.5px] font-semibold mb-1">
            <IcCheck size={13} className="text-success" />
            <span>{meta.decision === "ORIGINAL_FASTEST" ? "Original is the winner" : `Winner: ${meta.winner}`}</span>
          </div>
          {meta.reasoning && (
            <div className="text-[12.5px] text-muted leading-relaxed">{meta.reasoning}</div>
          )}
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
        <BenchCard
          label="Execution time"
          beforeNum={b.before.ms}
          afterNum={b.after.ms}
          beforeText={fmtMs(b.before.ms)}
          afterText={fmtMs(b.after.ms)}
          icon={IcClock}
          accent
          // Lower = better
          direction="lower-better"
        />
        <BenchCard
          label="Optimizer cost"
          beforeNum={b.before.cost}
          afterNum={b.after.cost}
          beforeText={b.before.cost.toLocaleString()}
          afterText={b.after.cost.toLocaleString()}
          icon={IcGauge}
          direction="lower-better"
          tooltip="Plan cost from EXPLAIN PLAN. Currently shows the original's cost on both sides — wiring per-candidate plan cost is on the backlog."
        />
        <BenchCard
          label="Rows returned"
          beforeNum={b.before.rows}
          afterNum={b.after.rows}
          beforeText={b.before.rows.toLocaleString()}
          afterText={b.after.rows.toLocaleString()}
          icon={IcLayers}
          // Row count must NOT change between rewrites — that would mean a wrong rewrite.
          direction="must-match"
          tooltip="Actual row count measured by Phase 4 (the validation engine executed the query). Different from DBMS_XPLAN's optimizer estimate, which is a pre-execution guess."
        />
      </div>

      <div className="card p-5">
        <div className="text-[11.5px] uppercase tracking-wide text-dim font-semibold mb-3">
          Speedup
        </div>
        <div className="flex items-end gap-6">
          <div className="text-[44px] font-semibold leading-none tracking-tight text-gradient-brand">
            {speedup.toFixed(1)}×
          </div>
          <div className="text-[12.5px] text-muted pb-1.5 leading-relaxed">
            faster after rewrite. {iters > 0 ? `Tested across ${iters} warm runs against the same dataset.` : ""}
          </div>
        </div>
        <div className="mt-4">
          <div className="flex items-center gap-3 text-[11.5px] text-muted mb-1.5">
            <span className="w-12">Before</span>
            <div className="flex-1 h-3 rounded-full bg-surface-2 overflow-hidden">
              <div className="h-full bg-warn" style={{ width: "100%" }} />
            </div>
            <span className="w-16 text-right tabular-nums font-mono-app">{fmtMs(b.before.ms)}</span>
          </div>
          <div className="flex items-center gap-3 text-[11.5px] text-muted">
            <span className="w-12">After</span>
            <div className="flex-1 h-3 rounded-full bg-surface-2 overflow-hidden">
              <div className="h-full bg-success" style={{ width: `${(b.after.ms / b.before.ms) * 100}%` }} />
            </div>
            <span className="w-16 text-right tabular-nums font-mono-app">{fmtMs(b.after.ms)}</span>
          </div>
        </div>
      </div>

      {meta?.candidates && meta.candidates.length > 0 && (
        <CandidateTable candidates={meta.candidates} winner={meta.winner} />
      )}
    </div>
  );
}

function CandidateTable({
  candidates,
  winner,
}: {
  candidates: import("./optimize-demo").BenchmarkCandidate[];
  winner: string;
}) {
  return (
    <div className="card overflow-x-auto">
      <table className="w-full text-[12.5px] min-w-[560px]">
        <thead className="bg-surface-2 text-muted">
          <tr className="text-left">
            <th className="px-3 py-2 font-medium">Candidate</th>
            <th className="px-3 py-2 font-medium text-right w-[110px]">Avg</th>
            <th className="px-3 py-2 font-medium text-right w-[90px]">Min</th>
            <th className="px-3 py-2 font-medium text-right w-[90px]">Max</th>
            <th className="px-3 py-2 font-medium w-[120px]">Result match</th>
          </tr>
        </thead>
        <tbody>
          {candidates.map((c, i) => {
            const isWinner = c.label === winner;
            const matchColor =
              c.results_match === "YES" ? "text-success" :
              c.results_match === "ROW_COUNT" ? "text-warn" :
              c.results_match === "NO" ? "text-danger" : "text-dim";
            const matchLabel =
              c.results_match === "YES" ? "Identical" :
              c.results_match === "ROW_COUNT" ? "Row count only" :
              c.results_match === "NO" ? "Differs" : "Not tested";
            // Choose pill color based on overall validity vs partial-validation
            const pillClass =
              c.is_valid === "N"
                ? "bg-danger-soft text-danger"
                : c.results_match === "ROW_COUNT"
                ? "bg-warn-soft text-warn"
                : "";
            const pillText =
              c.is_valid === "N" ? "invalid"
                : c.results_match === "ROW_COUNT" ? "partial"
                : null;
            return (
              <tr key={i} className="border-t border-default">
                <td className="px-3 py-2">
                  <div className="flex items-center gap-2 flex-wrap">
                    {isWinner && <IcCheck size={12} className="text-success" />}
                    <span className={isWinner ? "font-semibold text-fg" : "text-fg"}>{c.label}</span>
                    {pillText && (
                      <span
                        className={`pill !py-0 !px-1.5 !text-[10.5px] ${pillClass}`}
                        title={c.validation_msg}
                      >
                        {pillText}
                      </span>
                    )}
                  </div>
                  {c.validation_msg && c.validation_msg !== "OK" && (
                    <div className="text-[11.5px] text-dim mt-0.5 break-words">
                      {c.validation_msg}
                    </div>
                  )}
                </td>
                <td className="px-3 py-2 text-right tabular-nums font-mono-app">
                  {c.avg_ms != null ? fmtMs(c.avg_ms) : "—"}
                </td>
                <td className="px-3 py-2 text-right tabular-nums font-mono-app text-muted">
                  {c.min_ms != null ? fmtMs(c.min_ms) : "—"}
                </td>
                <td className="px-3 py-2 text-right tabular-nums font-mono-app text-muted">
                  {c.max_ms != null ? fmtMs(c.max_ms) : "—"}
                </td>
                <td className={`px-3 py-2 ${matchColor}`} title={
                  c.results_match === "ROW_COUNT"
                    ? "MINUS could not parse (duplicate column names from SELECT *). Row counts compared instead — weaker check."
                    : ""
                }>
                  {matchLabel}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
    </div>
  );
}

type Direction = "lower-better" | "higher-better" | "must-match";

function BenchCard({
  label,
  beforeNum,
  afterNum,
  beforeText,
  afterText,
  icon: Icon,
  accent,
  direction,
  tooltip,
}: {
  label: string;
  beforeNum: number;
  afterNum: number;
  beforeText: string;
  afterText: string;
  icon: React.ComponentType<{ size?: number; className?: string }>;
  accent?: boolean;
  direction: Direction;
  tooltip?: string;
}) {
  // Derive verdict from the actual numbers, not a hardcoded prop.
  const isSame = beforeNum === afterNum;
  let verdict: "improved" | "unchanged" | "regressed" | "matches" | "differs";
  if (direction === "must-match") {
    verdict = isSame ? "matches" : "differs";
  } else if (isSame) {
    verdict = "unchanged";
  } else {
    const better =
      direction === "lower-better" ? afterNum < beforeNum : afterNum > beforeNum;
    verdict = better ? "improved" : "regressed";
  }

  const verdictColor: Record<typeof verdict, string> = {
    improved: "text-success",
    matches:  "text-success",
    regressed: "text-danger",
    differs:   "text-danger",
    unchanged: "text-dim",
  };
  const verdictText: Record<typeof verdict, string> = {
    improved: "improved",
    regressed: "regressed",
    unchanged: "unchanged",
    matches: "match",
    differs: "differ",
  };

  return (
    <div
      className={`card p-4 ${accent ? "ring-1 ring-[color:var(--color-accent)]/30" : ""}`}
      title={tooltip}
    >
      <div className="flex items-center gap-2 text-[11.5px] uppercase tracking-wide text-dim font-semibold">
        <Icon size={12} />
        {label}
      </div>
      <div className="mt-2 flex items-baseline gap-2 flex-wrap">
        <div className="text-[22px] font-semibold tracking-tight tabular-nums">{afterText}</div>
        {!isSame && (
          <div className="text-[12px] text-dim line-through tabular-nums">{beforeText}</div>
        )}
      </div>
      <div className={`mt-1 text-[11.5px] font-medium ${verdictColor[verdict]}`}>
        {verdictText[verdict]}
      </div>
    </div>
  );
}

function EmptyTabState({
  icon: Icon,
  title,
  body,
  compact,
}: {
  icon: React.ComponentType<{ size?: number; className?: string }>;
  title: string;
  body: string;
  compact?: boolean;
}) {
  return (
    <div className={`flex flex-col items-center justify-center text-center ${compact ? "p-6" : "p-10"} h-full fade-up`}>
      <div className="w-10 h-10 rounded-xl bg-surface-2 border border-default flex items-center justify-center mb-3">
        <Icon size={16} className="text-muted" />
      </div>
      <div className="text-[13px] font-semibold mb-1.5">{title}</div>
      <div className={`text-[12.5px] text-muted leading-relaxed ${compact ? "max-w-[280px]" : "max-w-[420px]"}`}>
        {body}
      </div>
    </div>
  );
}

function EmptyState() {
  const items = [
    { icon: IcLayers, label: "Execution plan",  desc: "Step-by-step EXPLAIN with cost & rows" },
    { icon: IcList,   label: "Rule analysis",   desc: "Catches anti-patterns you'd miss in review" },
    { icon: IcSparkles, label: "AI rewrite",    desc: "A side-by-side optimized version" },
    { icon: IcGauge,  label: "Benchmark",       desc: "Before vs after, with speedup factor" },
  ];
  return (
    <div className="flex-1 h-full flex items-center justify-center p-8 bg-grid bg-grid-fade">
      <div className="max-w-[420px] w-full text-center fade-up">
        <div className="w-14 h-14 rounded-2xl bg-gradient-brand mx-auto mb-4 flex items-center justify-center shadow-md-app">
          <IcSparkles size={22} className="text-white" />
        </div>
        <h2 className="text-[20px] font-semibold tracking-tight mb-1.5">Tune your first query</h2>
        <p className="text-[13px] text-muted leading-relaxed">
          Paste a slow Oracle query on the left and hit{" "}
          <span className="text-fg font-medium">Optimize</span>. You&apos;ll see plan, rules,
          a rewrite, and a benchmark — all in one place.
        </p>
        <div className="mt-6 grid grid-cols-2 gap-2 text-left">
          {items.map(({ icon: Icon, label, desc }) => (
            <div key={label} className="card p-3">
              <Icon size={14} className="text-accent mb-1.5" />
              <div className="text-[12.5px] font-medium">{label}</div>
              <div className="text-[11.5px] text-dim mt-0.5 leading-snug">{desc}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function RunningState() {
  const steps = [
    "Parsing query…",
    "Building EXPLAIN PLAN…",
    "Running rule engine…",
    "Generating AI rewrite…",
    "Benchmarking…",
  ];
  const [step, setStep] = React.useState(0);
  React.useEffect(() => {
    const t = setInterval(() => setStep(s => Math.min(s + 1, steps.length - 1)), 280);
    return () => clearInterval(t);
  }, []);
  return (
    <div className="flex-1 h-full flex items-center justify-center p-8 bg-grid bg-grid-fade">
      <div className="w-full max-w-[360px]">
        <div className="flex items-center gap-3 mb-5">
          <div className="w-9 h-9 rounded-xl bg-accent-soft border border-default flex items-center justify-center">
            <span className="inline-block w-4 h-4 rounded-full border-2 border-accent border-t-transparent animate-spin" />
          </div>
          <div>
            <div className="text-[14px] font-semibold">Optimizing</div>
            <div className="text-[12px] text-muted">This usually takes a few seconds.</div>
          </div>
        </div>
        <ul className="space-y-2.5">
          {steps.map((s, i) => (
            <li key={s} className="flex items-center gap-2.5 text-[12.5px]">
              <span className={`w-4 h-4 rounded-full flex items-center justify-center shrink-0 ${
                i < step ? "bg-success-soft text-success" :
                i === step ? "bg-accent-soft text-accent" :
                "bg-surface-2 text-dim"
              }`}>
                {i < step ? <IcCheck size={10} /> : i === step ? (
                  <span className="w-1.5 h-1.5 rounded-full bg-current pulse-dot" />
                ) : null}
              </span>
              <span className={i <= step ? "text-fg" : "text-dim"}>{s}</span>
            </li>
          ))}
        </ul>
      </div>
    </div>
  );
}
