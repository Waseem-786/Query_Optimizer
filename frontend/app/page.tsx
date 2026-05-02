"use client";

import * as React from "react";
import { Sidebar, type HistoryItem } from "@/components/Sidebar";
import { ConnectionModal, type ConnectionInfo } from "@/components/ConnectionModal";
import { QueryEditor } from "@/components/QueryEditor";
import { ResultsPanel } from "@/components/ResultsPanel";
import { ChatPanel } from "@/components/ChatPanel";
import { ErrorModal } from "@/components/ErrorModal";
import { type OptimizeResult } from "@/components/optimize-demo";
import { optimizeQuery } from "@/lib/optimize";

// Minimal placeholder that does not pretend the schema exists. Bugs Fix #2/#3
// — the previous starter referenced HR tables (employees/departments) that
// don't exist on Flexcube, so the very first Optimize click would always
// fail.  We now show a comment-only placeholder; the user pastes their query.
const STARTER_SQL =
  "-- Paste a slow Oracle SELECT here, then press Ctrl/Cmd + Enter (or click Optimize).\n";

// History items now carry the SQL + the OptimizeResult so clicking restores
// the prior run. Was a flat HistoryItem[] before — clicks were dead (Fix #9).
type StoredHistoryItem = HistoryItem & {
  sql?: string;
  result?: OptimizeResult;
};

const CONN_STORAGE_KEY = "querymind.connection.v2";
const HISTORY_STORAGE_KEY = "querymind.history.v1";
const SIDEBAR_STORAGE_KEY = "querymind.sidebar.collapsed.v1";

function loadStoredConnection(): ConnectionInfo | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = sessionStorage.getItem(CONN_STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<ConnectionInfo>;
    if (parsed.user && parsed.host && parsed.port && parsed.service && parsed.password) {
      return parsed as ConnectionInfo;
    }
  } catch { /* ignore */ }
  return null;
}

function loadStoredHistory(): StoredHistoryItem[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = sessionStorage.getItem(HISTORY_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (h) =>
        h && typeof h.id === "string" && typeof h.title === "string" &&
        (h.mode === "optimize" || h.mode === "chat"),
    );
  } catch { return []; }
}

export default function Home() {
  const [mode, setMode] = React.useState<"optimize" | "chat">("optimize");
  // Connection persisted in sessionStorage so a page refresh doesn't drop it
  // (Fix #7). sessionStorage is per-tab and clears on tab close, matching the
  // ConnectionModal's "credentials kept for this session only" copy.
  const [connection, setConnection] = React.useState<ConnectionInfo | null>(null);
  const [showConnect, setShowConnect] = React.useState(false);
  React.useEffect(() => {
    const stored = loadStoredConnection();
    if (stored) setConnection(stored);
  }, []);
  const persistConnection = React.useCallback((c: ConnectionInfo | null) => {
    setConnection(c);
    if (typeof window !== "undefined") {
      try {
        if (c) sessionStorage.setItem(CONN_STORAGE_KEY, JSON.stringify(c));
        else sessionStorage.removeItem(CONN_STORAGE_KEY);
      } catch { /* ignore */ }
    }
  }, []);

  const [sql, setSql] = React.useState(STARTER_SQL);
  const [busy, setBusy] = React.useState(false);
  const [result, setResult] = React.useState<OptimizeResult | null>(null);
  const [lastQuery, setLastQuery] = React.useState("");
  const [error, setError] = React.useState<string | null>(null);

  // Bumped whenever the user clicks "New chat" in the sidebar while the
  // Assistant tab is open. ChatPanel watches this counter and resets its
  // messages + sessionStorage when it changes — gives the sidebar button
  // the same effect as the in-panel Clear button.
  const [chatClearSignal, setChatClearSignal] = React.useState(0);

  // Sidebar collapse state. Persisted per-tab so a reload doesn't undo the
  // user's preference. Defaults to expanded; flips to a 56 px icon-only
  // rail when the user clicks the logo.
  const [sidebarCollapsed, setSidebarCollapsed] = React.useState(false);
  React.useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      if (sessionStorage.getItem(SIDEBAR_STORAGE_KEY) === "1") {
        setSidebarCollapsed(true);
      }
    } catch { /* ignore */ }
  }, []);
  const toggleSidebar = React.useCallback(() => {
    setSidebarCollapsed((c) => {
      const next = !c;
      if (typeof window !== "undefined") {
        try {
          sessionStorage.setItem(SIDEBAR_STORAGE_KEY, next ? "1" : "0");
        } catch { /* ignore */ }
      }
      return next;
    });
  }, []);

  // Empty by default — we used to seed three fake history rows that:
  //  • highlighted "h1" by default but pointed at no real state (Fix #4)
  //  • cluttered the sidebar with sample data the user never created (Fix #5)
  //  • made History click feel broken because we couldn't restore them.
  const [history, setHistory] = React.useState<StoredHistoryItem[]>([]);
  const [activeId, setActiveId] = React.useState<string | null>(null);

  // Restore optimize history from sessionStorage on mount; persist on every
  // change so a page refresh doesn't wipe what the user has run.
  React.useEffect(() => {
    const stored = loadStoredHistory();
    if (stored.length > 0) setHistory(stored);
  }, []);
  React.useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      // Cap at last 30 entries — each entry can be tens of KB (full
      // OptimizeResult), so 30 keeps the storage footprint reasonable.
      sessionStorage.setItem(
        HISTORY_STORAGE_KEY,
        JSON.stringify(history.slice(0, 30)),
      );
    } catch { /* quota errors non-fatal */ }
  }, [history]);

  // Race-condition guard (Fix #6). When the user changes SQL while an
  // optimize call is in flight, the stale response would have overwritten the
  // newer state. Each run now bumps a counter; we drop responses whose id is
  // no longer the latest.
  const runIdRef = React.useRef(0);

  const runOptimize = async () => {
    // Empty editor used to silently no-op (Fix #1). Surface a clear message.
    if (!sql.trim()) {
      setError("Paste a query into the editor first.");
      return;
    }
    // Strip block + line comments. If nothing remains, the user has only
    // typed comments — Oracle will reject this with "Only SELECT queries
    // are supported in Phase 2" after a wasted ~150 ms round-trip. Catch it
    // here with a friendlier message instead.
    const stripped = sql
      .replace(/\/\*[\s\S]*?\*\//g, "")
      .split("\n")
      .map((l) => l.replace(/--.*$/, "").trim())
      .join("")
      .trim();
    if (stripped.length === 0) {
      setLastQuery(sql);
      setError(
        "The editor only contains comments. Paste a SELECT statement before running.",
      );
      return;
    }
    if (busy) return;
    if (!connection) {
      setShowConnect(true);
      setError("Connect to Oracle before running an analysis.");
      return;
    }
    // The Try samples ship with {your_table} / {your_col} placeholders. Send
    // those to Oracle and you get ORA-00903 ~2 s later — wasting a round
    // trip and leaving the user puzzled. Catch it client-side instead.
    const placeholderMatch = sql.match(/\{[a-z_][a-z0-9_]*\}/gi);
    if (placeholderMatch && placeholderMatch.length > 0) {
      const unique = Array.from(new Set(placeholderMatch));
      setLastQuery(sql);
      setError(
        `Replace the sample placeholder${unique.length === 1 ? "" : "s"} ` +
          `${unique.join(", ")} with real names from your schema before running.`,
      );
      return;
    }
    const myRunId = ++runIdRef.current;
    setBusy(true);
    setResult(null);
    setError(null);
    setLastQuery(sql);

    const capturedSql = sql;
    const out = await optimizeQuery(connection, capturedSql);

    // Bail if a newer run started after us — its response will arrive later
    // and own the UI; ours is stale.
    if (myRunId !== runIdRef.current) return;

    setBusy(false);

    if ("error" in out) {
      setError(`${out.error.kind === "connection" ? "Oracle connection" : "Oracle"}: ${out.error.message}`);
      return;
    }

    setResult(out.result);
    const id = crypto.randomUUID();
    const firstNonComment = capturedSql
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l && !l.startsWith("--"));
    const title = (firstNonComment ?? "Untitled").slice(0, 60);
    setHistory((h) => [
      {
        id,
        title,
        mode: "optimize",
        ts: Date.now(),
        preview: out.result.summary.slice(0, 60) + "…",
        sql: capturedSql,
        result: out.result,
      },
      ...h,
    ]);
    setActiveId(id);
  };

  // Restore SQL + previous result when a history entry is clicked (Fix #9).
  const selectHistory = React.useCallback((id: string) => {
    setActiveId(id);
    const entry = history.find((h) => h.id === id);
    if (!entry) return;
    if (entry.mode === "optimize") {
      if (entry.sql) setSql(entry.sql);
      if (entry.result) {
        setResult(entry.result);
        setLastQuery(entry.sql ?? "");
      }
    }
  }, [history]);

  return (
    <div className="flex h-screen w-screen overflow-hidden">
      <Sidebar
        mode={mode}
        onModeChange={(m) => { setMode(m); setActiveId(null); }}
        history={history.filter((h) => h.mode === mode)}
        activeId={activeId}
        onSelect={selectHistory}
        onNew={() => {
          setActiveId(null);
          if (mode === "optimize") {
            setSql("");
            setResult(null);
            setError(null);
          } else {
            // "New chat" used to be a no-op — bump the clear signal so the
            // ChatPanel resets messages + storage to match Optimize's "New
            // query" behaviour.
            setChatClearSignal((n) => n + 1);
          }
        }}
        onDelete={(id) => setHistory((h) => h.filter((x) => x.id !== id))}
        connection={connection}
        onOpenConnection={() => setShowConnect(true)}
        collapsed={sidebarCollapsed}
        onToggleCollapsed={toggleSidebar}
      />

      <main className="flex-1 min-w-0 flex flex-col">
        {mode === "optimize" ? (
          <div className="flex-1 min-h-0 grid grid-cols-1 lg:grid-cols-2 gap-px bg-default">
            <div className="min-h-0 overflow-hidden">
              <QueryEditor
                value={sql}
                onChange={setSql}
                onRun={runOptimize}
                busy={busy}
                connected={!!connection}
              />
            </div>
            <div className="min-h-0 overflow-hidden border-l border-default flex flex-col">
              <div className="flex-1 min-h-0 overflow-hidden">
                <ResultsPanel result={result} busy={busy} lastQuery={lastQuery} />
              </div>
            </div>
          </div>
        ) : (
          <ChatPanel clearSignal={chatClearSignal} />
        )}
      </main>

      <ConnectionModal
        open={showConnect}
        onClose={() => setShowConnect(false)}
        onConnect={persistConnection}
        current={connection}
      />

      <ErrorModal
        open={!!error}
        message={error ?? ""}
        detail={lastQuery ? `Query:\n${lastQuery.slice(0, 600)}${lastQuery.length > 600 ? " …" : ""}` : undefined}
        onClose={() => setError(null)}
      />
    </div>
  );
}
