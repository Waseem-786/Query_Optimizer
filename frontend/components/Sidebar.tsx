"use client";

import * as React from "react";
import {
  IcDatabase, IcPlus, IcSearch, IcMessage, IcZap,
  IcTrash, IcChevronRight,
} from "./icons";
import { ThemeToggle } from "./ThemeToggle";

export type HistoryItem = {
  id: string;
  title: string;
  mode: "optimize" | "chat";
  ts: number;          // epoch ms
  preview?: string;
};

type Mode = "optimize" | "chat";

type Props = {
  mode: Mode;
  onModeChange: (m: Mode) => void;
  history: HistoryItem[];
  activeId: string | null;
  onSelect: (id: string) => void;
  onNew: () => void;
  onDelete: (id: string) => void;
  connection: { user: string; host: string } | null;
  onOpenConnection: () => void;
  // Sidebar collapse state — owned by the parent so it can persist across
  // reloads. The logo doubles as the toggle in both states.
  collapsed: boolean;
  onToggleCollapsed: () => void;
};

function relTime(ts: number): string {
  const s = Math.round((Date.now() - ts) / 1000);
  if (s < 60) return "just now";
  if (s < 3600) return `${Math.round(s / 60)}m ago`;
  if (s < 86400) return `${Math.round(s / 3600)}h ago`;
  return `${Math.round(s / 86400)}d ago`;
}

export function Sidebar({
  mode, onModeChange, history, activeId, onSelect, onNew, onDelete,
  connection, onOpenConnection, collapsed, onToggleCollapsed,
}: Props) {
  const [q, setQ] = React.useState("");
  const filtered = React.useMemo(() => {
    if (!q.trim()) return history;
    const needle = q.toLowerCase();
    return history.filter(h =>
      h.title.toLowerCase().includes(needle) ||
      (h.preview ?? "").toLowerCase().includes(needle)
    );
  }, [history, q]);

  // ──────────────────────────────────────────────────────────────────────
  // Two layouts share one <aside> so width can transition smoothly.
  //
  // Outer wrapper animates `width` from 56 ↔ 280 over 220ms; inside, we
  // conditionally render the rail icons or the full panel. The inner
  // content is keyed off `collapsed` so React mounts a fresh subtree each
  // toggle — that triggers our `fade-up` keyframe animation, giving the
  // content a soft cross-fade rather than a hard snap. `overflow-hidden`
  // on the wrapper hides any frame where the wide content is still mid-
  // transition inside the narrowing rail width.
  //
  // The collapsed rail keeps the most-used controls reachable (logo-
  // toggle, mode switch, new, theme toggle, connection status) while
  // freeing the editor + results pane to take the rail's 224 px back.
  // History list + search are hidden — they need text width that just
  // isn't available at 56 px.
  // ──────────────────────────────────────────────────────────────────────
  return (
    <aside
      style={{ width: collapsed ? 56 : 280 }}
      className="flex flex-col h-full shrink-0 border-r border-default bg-surface overflow-hidden transition-[width] duration-[220ms] ease-out"
      aria-label="Sidebar"
    >
      <div key={collapsed ? "rail" : "full"} className="flex flex-col h-full fade-up">
        {collapsed ? (
          <RailContent
            mode={mode}
            connection={connection}
            onToggleCollapsed={onToggleCollapsed}
            onModeChange={onModeChange}
            onNew={onNew}
            onOpenConnection={onOpenConnection}
          />
        ) : (
          <FullContent
            mode={mode}
            onModeChange={onModeChange}
            filtered={filtered}
            q={q}
            setQ={setQ}
            activeId={activeId}
            onSelect={onSelect}
            onNew={onNew}
            onDelete={onDelete}
            connection={connection}
            onOpenConnection={onOpenConnection}
            onToggleCollapsed={onToggleCollapsed}
          />
        )}
      </div>
    </aside>
  );
}

// ============================================================================
// Rail (collapsed) — 56 px icon-only navigation
// ============================================================================
function RailContent({
  mode, connection, onToggleCollapsed, onModeChange, onNew, onOpenConnection,
}: {
  mode: Mode;
  connection: { user: string; host: string } | null;
  onToggleCollapsed: () => void;
  onModeChange: (m: Mode) => void;
  onNew: () => void;
  onOpenConnection: () => void;
}) {
  return (
    <div className="flex flex-col items-center h-full py-3 gap-2 w-[56px]">
      <button
        onClick={onToggleCollapsed}
        title="Expand navigation"
        aria-label="Expand navigation"
        className="w-9 h-9 rounded-lg bg-gradient-brand flex items-center justify-center shadow-sm-app hover:scale-[1.04] transition-transform"
      >
        <IcZap size={16} className="text-white" />
      </button>
      <div className="w-8 h-px bg-default my-1" />
      <button
        onClick={() => onModeChange("optimize")}
        title="Optimize"
        aria-label="Optimize"
        className={`w-9 h-9 rounded-lg flex items-center justify-center transition-colors ${
          mode === "optimize"
            ? "bg-accent-soft text-accent border border-default"
            : "text-muted hover:text-fg hover:bg-surface-2"
        }`}
      >
        <IcZap size={15} />
      </button>
      <button
        onClick={() => onModeChange("chat")}
        title="Assistant"
        aria-label="Assistant"
        className={`w-9 h-9 rounded-lg flex items-center justify-center transition-colors ${
          mode === "chat"
            ? "bg-info-soft text-info border border-default"
            : "text-muted hover:text-fg hover:bg-surface-2"
        }`}
      >
        <IcMessage size={15} />
      </button>
      <button
        onClick={onNew}
        title={mode === "optimize" ? "New query" : "New chat"}
        aria-label={mode === "optimize" ? "New query" : "New chat"}
        className="w-9 h-9 rounded-lg flex items-center justify-center text-muted hover:text-fg hover:bg-surface-2 transition-colors"
      >
        <IcPlus size={15} />
      </button>
      <div className="mt-auto flex flex-col items-center gap-2">
        <ThemeToggle />
        <button
          onClick={onOpenConnection}
          title={connection ? `${connection.user}@${connection.host}` : "Connect to Oracle"}
          aria-label={connection ? "Connection settings" : "Connect to Oracle"}
          className="w-9 h-9 rounded-lg flex items-center justify-center hover:bg-surface-2 transition-colors relative"
        >
          <IcDatabase size={16} className={connection ? "text-success" : "text-dim"} />
          {connection && (
            <span className="absolute top-1.5 right-1.5 w-1.5 h-1.5 rounded-full bg-success pulse-dot" />
          )}
        </button>
      </div>
    </div>
  );
}

// ============================================================================
// Full (expanded) — 280 px sidebar with mode/search/history/footer
// ============================================================================
function FullContent({
  mode, onModeChange, filtered, q, setQ, activeId, onSelect, onNew, onDelete,
  connection, onOpenConnection, onToggleCollapsed,
}: {
  mode: Mode;
  onModeChange: (m: Mode) => void;
  filtered: HistoryItem[];
  q: string;
  setQ: (v: string) => void;
  activeId: string | null;
  onSelect: (id: string) => void;
  onNew: () => void;
  onDelete: (id: string) => void;
  connection: { user: string; host: string } | null;
  onOpenConnection: () => void;
  onToggleCollapsed: () => void;
}) {
  return (
    <div className="flex flex-col h-full w-[280px]">
      {/* Brand — logo doubles as collapse toggle */}
      <div className="px-4 py-4 flex items-center gap-2.5 border-b border-default">
        <button
          onClick={onToggleCollapsed}
          title="Collapse navigation"
          aria-label="Collapse navigation"
          className="w-7 h-7 rounded-lg bg-gradient-brand flex items-center justify-center shadow-sm-app hover:scale-[1.06] transition-transform"
        >
          <IcZap size={15} className="text-white" />
        </button>
        <button
          onClick={onToggleCollapsed}
          className="leading-tight text-left hover:opacity-80 transition-opacity"
          title="Collapse navigation"
        >
          <div className="text-[13px] font-semibold tracking-tight">QueryMind</div>
          <div className="text-[11px] text-dim">SQL Workbench</div>
        </button>
        <div className="ml-auto"><ThemeToggle /></div>
      </div>

      {/* Mode toggle */}
      <div className="px-3 pt-3">
        <div className="bg-surface-2 border border-default rounded-lg p-1 grid grid-cols-2 gap-1 text-[12px] font-medium">
          <button
            onClick={() => onModeChange("optimize")}
            className={`px-2.5 py-1.5 rounded-md flex items-center justify-center gap-1.5 transition-colors ${
              mode === "optimize" ? "bg-surface text-fg shadow-sm-app" : "text-muted hover:text-fg"
            }`}
          >
            <IcZap size={13} />
            Optimize
          </button>
          <button
            onClick={() => onModeChange("chat")}
            className={`px-2.5 py-1.5 rounded-md flex items-center justify-center gap-1.5 transition-colors ${
              mode === "chat" ? "bg-surface text-fg shadow-sm-app" : "text-muted hover:text-fg"
            }`}
          >
            <IcMessage size={13} />
            Assistant
          </button>
        </div>
      </div>

      {/* New + search */}
      <div className="px-3 pt-3 space-y-2">
        <button onClick={onNew} className="btn btn-ghost w-full justify-start">
          <IcPlus size={14} />
          New {mode === "optimize" ? "query" : "chat"}
        </button>
        <div className="relative">
          <IcSearch
            size={13}
            className="absolute left-2.5 top-1/2 -translate-y-1/2 text-dim pointer-events-none"
          />
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="Search history…"
            className="w-full pl-7 pr-2 py-1.5 rounded-md bg-surface-2 border border-default text-[12px]
                       placeholder:text-dim focus:outline-none focus:border-strong"
          />
        </div>
      </div>

      {/* History */}
      <div className="flex-1 overflow-y-auto px-2 py-3">
        <div className="px-2 mb-1.5 text-[10.5px] uppercase tracking-[0.08em] text-dim font-semibold">
          History · {filtered.length}
        </div>
        <ul className="space-y-0.5">
          {filtered.length === 0 && (
            <li className="px-3 py-6 text-center text-[12px] text-dim">No items</li>
          )}
          {filtered.map((h) => {
            const active = h.id === activeId;
            // Hover tooltip shows full title + absolute timestamp + preview
            // — gives the user a way to disambiguate two history entries
            // whose truncated titles look identical (e.g. "SELECT * FROM
            // dual" run twice).
            const fullTimestamp = new Date(h.ts).toLocaleString();
            const tooltip = [
              h.title,
              h.preview ? `\n${h.preview}` : "",
              `\nRan ${fullTimestamp}`,
            ].join("");
            return (
              <li key={h.id}>
                <div
                  className={`group relative rounded-lg px-2.5 py-2 cursor-pointer transition-colors ${
                    active ? "bg-surface-3" : "hover:bg-surface-2"
                  }`}
                  onClick={() => onSelect(h.id)}
                  title={tooltip}
                >
                  <div className="flex items-center gap-2">
                    <span
                      className={`shrink-0 w-1 h-4 rounded-full ${
                        h.mode === "optimize" ? "bg-accent" : "bg-info"
                      }`}
                    />
                    <span className="flex-1 truncate text-[12.5px] text-fg">{h.title}</span>
                    <button
                      onClick={(e) => { e.stopPropagation(); onDelete(h.id); }}
                      className="opacity-0 group-hover:opacity-100 text-dim hover:text-danger transition-opacity"
                      aria-label="Delete"
                      title="Delete this entry"
                    >
                      <IcTrash size={12} />
                    </button>
                  </div>
                  <div className="ml-3 mt-0.5 text-[11px] text-dim truncate">
                    {h.preview ?? "—"} · {relTime(h.ts)}
                  </div>
                </div>
              </li>
            );
          })}
        </ul>
      </div>

      {/* Connection footer */}
      <button
        onClick={onOpenConnection}
        className="border-t border-default px-3 py-3 flex items-center gap-2.5 hover:bg-surface-2 transition-colors text-left"
      >
        <div className="w-8 h-8 rounded-lg bg-surface-2 border border-default flex items-center justify-center">
          <IcDatabase size={15} className={connection ? "text-success" : "text-dim"} />
        </div>
        <div className="flex-1 min-w-0">
          <div className="text-[12px] font-medium text-fg truncate flex items-center gap-1.5">
            {connection ? (
              <>
                <span className="w-1.5 h-1.5 rounded-full bg-success pulse-dot" />
                Connected
              </>
            ) : (
              "No connection"
            )}
          </div>
          <div className="text-[11px] text-dim truncate">
            {connection ? `${connection.user}@${connection.host}` : "Click to connect Oracle DB"}
          </div>
        </div>
        <IcChevronRight size={13} className="text-dim" />
      </button>
    </div>
  );
}
