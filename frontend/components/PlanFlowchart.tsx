"use client";

import * as React from "react";
import type { PlanNode } from "./optimize-demo";

// ============================================================================
// PlanFlowchart
//
// Renders a hierarchical flowchart of an Oracle EXPLAIN PLAN. The plan is a
// tree (id + parent_id) — we lay it out top-down with the root SELECT
// STATEMENT at the top and leaves (TABLE ACCESS / INDEX SCAN) at the bottom.
// Layout is computed in pure JS:
//   width(node)  = max(NODE_W, sum(width(children)) + spacing)
//   xpos(node)   = centered above its children's bounding box
//   ypos(node)   = depth * (NODE_H + V_GAP)
//
// Connectors are drawn as orthogonal SVG paths (down → across → down) so the
// chart reads like a flow diagram, not a tangle.
//
// Each node is colour-coded by operation family so you can tell at a glance
// which steps are full scans (red), index access (green), joins (blue),
// sorts (purple), set operators (orange), data flow (gray). Predicates
// (FILTER + ACCESS) appear inside an expander at the bottom of each node so
// the user can see WHY each operation runs.
// ============================================================================

const NODE_W = 220;
const NODE_H = 90;          // base height; expanded nodes grow downward
const H_GAP  = 28;
const V_GAP  = 56;
const PAD    = 24;

type Layout = {
  byId: Map<number, PlanNode>;
  childrenOf: Map<number, PlanNode[]>;
  // x, y, w (subtree width), expanded extra height
  pos: Map<number, { x: number; y: number; w: number; h: number }>;
  totalW: number;
  totalH: number;
};

function classifyNode(op: string, options: string | null): {
  family: string;
  bg: string;
  border: string;
  text: string;
  badge: string;
} {
  const opU = (op || "").toUpperCase();
  const optU = (options || "").toUpperCase();

  // Full table scan — performance red flag
  if (opU === "TABLE ACCESS" && optU === "FULL") {
    return { family: "Full scan", bg: "bg-danger-soft", border: "border-danger/40", text: "text-danger", badge: "bg-danger/15 text-danger" };
  }
  // Cartesian / Nested loop on whole table = bad
  if (opU.includes("CARTESIAN")) {
    return { family: "Cartesian", bg: "bg-danger-soft", border: "border-danger/40", text: "text-danger", badge: "bg-danger/15 text-danger" };
  }
  // Index access — usually good
  if (opU === "INDEX") {
    return { family: "Index access", bg: "bg-success-soft", border: "border-success/40", text: "text-success", badge: "bg-success/15 text-success" };
  }
  if (opU === "TABLE ACCESS" && (optU.includes("INDEX") || optU.includes("ROWID"))) {
    return { family: "Indexed access", bg: "bg-success-soft", border: "border-success/40", text: "text-success", badge: "bg-success/15 text-success" };
  }
  // Joins
  if (opU.includes("JOIN") || opU.includes("NESTED LOOPS")) {
    return { family: "Join", bg: "bg-info-soft", border: "border-info/40", text: "text-info", badge: "bg-info/15 text-info" };
  }
  // Sort / aggregate
  if (opU.includes("SORT") || opU.includes("HASH GROUP BY") || opU.includes("AGGREGATE")) {
    return { family: "Sort / Aggregate", bg: "bg-warn-soft", border: "border-warn/40", text: "text-warn", badge: "bg-warn/15 text-warn" };
  }
  // Set operators
  if (opU.includes("UNION") || opU.includes("MINUS") || opU.includes("INTERSECT")) {
    return { family: "Set op", bg: "bg-warn-soft", border: "border-warn/40", text: "text-warn", badge: "bg-warn/15 text-warn" };
  }
  // Filter / view / projection
  if (opU === "FILTER" || opU === "VIEW" || opU === "COUNT" || opU.includes("PROJECTION")) {
    return { family: "Pipeline", bg: "bg-surface-2", border: "border-default", text: "text-fg", badge: "bg-surface-3 text-muted" };
  }
  // Parallel / partition coordination
  if (opU.startsWith("PX") || opU.startsWith("PARTITION")) {
    return { family: "Parallel/Partition", bg: "bg-surface-2", border: "border-default", text: "text-muted", badge: "bg-surface-3 text-muted" };
  }
  // Root SELECT STATEMENT
  if (opU === "SELECT STATEMENT") {
    return { family: "Root", bg: "bg-accent-soft", border: "border-accent/40", text: "text-accent", badge: "bg-accent/15 text-accent" };
  }
  return { family: "Other", bg: "bg-surface-2", border: "border-default", text: "text-fg", badge: "bg-surface-3 text-muted" };
}

function fmt(n: number | null | undefined, opts?: { unit?: string; placeholder?: string }) {
  if (n == null) return opts?.placeholder ?? "—";
  return n.toLocaleString() + (opts?.unit ?? "");
}

function buildLayout(nodes: PlanNode[], expanded: Set<number>): Layout {
  const byId = new Map<number, PlanNode>();
  const childrenOf = new Map<number, PlanNode[]>();
  for (const n of nodes) {
    byId.set(n.id, n);
    if (n.parent_id != null) {
      const list = childrenOf.get(n.parent_id) ?? [];
      list.push(n);
      childrenOf.set(n.parent_id, list);
    }
  }
  for (const list of childrenOf.values()) {
    list.sort((a, b) => (a.position ?? 0) - (b.position ?? 0));
  }

  const pos = new Map<number, { x: number; y: number; w: number; h: number }>();

  // Pass 1: compute subtree widths (bottom-up).
  function widthOf(id: number): number {
    const kids = childrenOf.get(id) ?? [];
    if (kids.length === 0) return NODE_W;
    let total = 0;
    for (const k of kids) total += widthOf(k.id);
    total += H_GAP * (kids.length - 1);
    return Math.max(NODE_W, total);
  }

  // Pass 2: assign x positions (top-down), centering each node above its kids.
  function place(id: number, leftX: number, depth: number) {
    const kids = childrenOf.get(id) ?? [];
    const subtreeW = widthOf(id);
    const node = byId.get(id)!;
    const isExpanded = expanded.has(id);
    const extraH = isExpanded ? predicateExtraHeight(node) : 0;
    const y = PAD + depth * (NODE_H + V_GAP);
    if (kids.length === 0) {
      const x = leftX + subtreeW / 2 - NODE_W / 2;
      pos.set(id, { x, y, w: NODE_W, h: NODE_H + extraH });
      return;
    }
    let cursor = leftX;
    for (const k of kids) {
      const kw = widthOf(k.id);
      place(k.id, cursor, depth + 1);
      cursor += kw + H_GAP;
    }
    // Center this node above its leftmost & rightmost child
    const first = pos.get(kids[0].id)!;
    const last  = pos.get(kids[kids.length - 1].id)!;
    const centerX = (first.x + last.x + last.w) / 2;
    pos.set(id, { x: centerX - NODE_W / 2, y, w: NODE_W, h: NODE_H + extraH });
  }

  // Find roots (parent_id == null)
  const roots = nodes.filter((n) => n.parent_id == null).sort((a, b) => a.id - b.id);
  let cursor = PAD;
  let totalH = PAD * 2;
  for (const r of roots) {
    place(r.id, cursor, 0);
    cursor += widthOf(r.id) + H_GAP;
  }

  // Compute totalW + totalH
  let totalW = PAD * 2;
  for (const p of pos.values()) {
    totalW = Math.max(totalW, p.x + p.w + PAD);
    totalH = Math.max(totalH, p.y + p.h + PAD);
  }

  return { byId, childrenOf, pos, totalW, totalH };
}

function predicateExtraHeight(n: PlanNode): number {
  let h = 0;
  if (n.access_predicates) h += 32;
  if (n.filter_predicates) h += 32;
  if (n.partition_start && n.partition_start !== n.partition_stop) h += 24;
  return h;
}

function Connector({
  from,
  to,
}: {
  from: { x: number; y: number; w: number; h: number };
  to:   { x: number; y: number; w: number; h: number };
}) {
  // Parent (from) sits below child (to). Draw a path from child top-center →
  // up → across → down to parent bottom-center. (Plans flow data UP from leaves.)
  // Note: in our layout depth=0 is the root (SELECT STATEMENT) which is at the
  // TOP visually; deeper rows are below. Data flows from bottom to top.
  // So we draw from CHILD bottom → horizontal mid → PARENT bottom.
  // Actually, simpler: draw line from child.topCenter to parent.bottomCenter.
  const childX = to.x + to.w / 2;
  const childY = to.y;             // top of child node
  const parentX = from.x + from.w / 2;
  const parentY = from.y + from.h; // bottom of parent node
  const midY = (parentY + childY) / 2;
  const d = `M ${childX} ${childY} V ${midY} H ${parentX} V ${parentY}`;
  return <path d={d} fill="none" stroke="var(--color-border-strong)" strokeWidth={1.5} />;
}

function Node({
  node,
  layout,
  expanded,
  toggle,
}: {
  node: PlanNode;
  layout: { x: number; y: number; w: number; h: number };
  expanded: boolean;
  toggle: () => void;
}) {
  const cls = classifyNode(node.operation, node.options);
  const opLabel = [node.operation, node.options].filter(Boolean).join(" · ");
  const obj = node.object_name
    ? `${node.object_owner ? node.object_owner + "." : ""}${node.object_name}`
    : null;
  const hasPredicates =
    !!node.access_predicates ||
    !!node.filter_predicates ||
    (!!node.partition_start && node.partition_start !== node.partition_stop);

  return (
    <div
      className={`absolute card ${cls.bg} ${cls.border} border overflow-hidden`}
      style={{ left: layout.x, top: layout.y, width: layout.w, minHeight: NODE_H }}
    >
      <div className="px-3 py-2">
        <div className="flex items-center gap-2 mb-0.5">
          <span className={`pill !py-0 !px-1.5 !text-[10px] uppercase tracking-wide ${cls.badge}`}>
            {cls.family}
          </span>
          <span className="text-[10.5px] text-dim font-mono-app ml-auto">#{node.id}</span>
        </div>
        <div className={`text-[12.5px] font-semibold leading-tight ${cls.text}`}>
          {opLabel}
        </div>
        {obj && (
          <div className="text-[11.5px] text-muted font-mono-app mt-0.5 truncate" title={obj}>
            {obj}
          </div>
        )}
        <div className="mt-1.5 flex items-center gap-3 text-[10.5px] text-dim font-mono-app">
          <span>cost <span className="text-fg">{fmt(node.cost)}</span></span>
          <span>rows <span className="text-fg">{fmt(node.cardinality)}</span></span>
          {node.bytes != null && <span>bytes <span className="text-fg">{fmt(node.bytes)}</span></span>}
        </div>
      </div>

      {hasPredicates && (
        <button
          type="button"
          onClick={toggle}
          className="w-full px-3 py-1 text-[10.5px] text-muted hover:bg-surface-2 border-t border-default flex items-center justify-between"
        >
          <span>{expanded ? "Hide predicates" : "Show predicates"}</span>
          <span>{expanded ? "−" : "+"}</span>
        </button>
      )}

      {expanded && hasPredicates && (
        <div className="px-3 py-2 border-t border-default text-[11px] font-mono-app space-y-1.5 bg-surface-2/40">
          {node.access_predicates && (
            <div>
              <div className="text-[10px] uppercase text-dim mb-0.5">access</div>
              <div className="text-fg break-words">{node.access_predicates}</div>
            </div>
          )}
          {node.filter_predicates && (
            <div>
              <div className="text-[10px] uppercase text-dim mb-0.5">filter</div>
              <div className="text-fg break-words">{node.filter_predicates}</div>
            </div>
          )}
          {node.partition_start && node.partition_start !== node.partition_stop && (
            <div>
              <div className="text-[10px] uppercase text-dim mb-0.5">partition</div>
              <div className="text-fg">{node.partition_start} → {node.partition_stop}</div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

export function PlanFlowchart({ nodes }: { nodes: PlanNode[] }) {
  const [expanded, setExpanded] = React.useState<Set<number>>(() => new Set());
  const layout = React.useMemo(() => buildLayout(nodes, expanded), [nodes, expanded]);

  if (nodes.length === 0) return null;

  const toggle = (id: number) => {
    setExpanded((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  };

  // Build connector list (parent → each child)
  const connectors: { from: number; to: number }[] = [];
  for (const node of nodes) {
    if (node.parent_id != null && layout.byId.has(node.parent_id)) {
      connectors.push({ from: node.parent_id, to: node.id });
    }
  }

  return (
    <div className="relative" style={{ width: layout.totalW, height: layout.totalH }}>
      <svg
        className="absolute inset-0 pointer-events-none"
        width={layout.totalW}
        height={layout.totalH}
      >
        {connectors.map((c, i) => {
          const from = layout.pos.get(c.from);
          const to   = layout.pos.get(c.to);
          if (!from || !to) return null;
          return <Connector key={i} from={from} to={to} />;
        })}
      </svg>
      {nodes.map((n) => {
        const p = layout.pos.get(n.id);
        if (!p) return null;
        return (
          <Node
            key={n.id}
            node={n}
            layout={p}
            expanded={expanded.has(n.id)}
            toggle={() => toggle(n.id)}
          />
        );
      })}
    </div>
  );
}

export function PlanFlowchartLegend() {
  const items: { label: string; cls: string }[] = [
    { label: "Root",            cls: "bg-accent-soft border-accent/40" },
    { label: "Index access",    cls: "bg-success-soft border-success/40" },
    { label: "Full scan",       cls: "bg-danger-soft border-danger/40" },
    { label: "Join",            cls: "bg-info-soft border-info/40" },
    { label: "Sort / aggregate",cls: "bg-warn-soft border-warn/40" },
    { label: "Pipeline",        cls: "bg-surface-2 border-default" },
  ];
  return (
    <div className="flex flex-wrap gap-2 text-[11px] text-dim">
      {items.map((i) => (
        <span key={i.label} className="inline-flex items-center gap-1.5">
          <span className={`inline-block w-3 h-3 rounded-sm border ${i.cls}`} />
          {i.label}
        </span>
      ))}
    </div>
  );
}
