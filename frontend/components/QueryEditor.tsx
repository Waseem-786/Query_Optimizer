"use client";

import * as React from "react";
import { highlightSql } from "./SqlBlock";
import { IcPlay, IcSparkles, IcZap } from "./icons";

type Props = {
  value: string;
  onChange: (v: string) => void;
  onRun: () => void;
  busy: boolean;
  connected: boolean;
};

// Schema-agnostic anti-pattern templates. Use {your_table} placeholders so
// users replace with their own tables — used to reference HR tables that
// don't exist on most production DBs (Fix #3). Each sample illustrates ONE
// anti-pattern the rule engine targets.
const SAMPLES = [
  {
    label: "Function on indexed column",
    sql:
      "-- Anti-pattern: UPPER() on a column blocks B-tree index access.\n-- Replace {your_table} / {your_col} with real names from your schema.\nSELECT * FROM {your_table}\nWHERE UPPER({your_col}) = 'VALUE';",
  },
  {
    label: "Subquery → JOIN",
    sql:
      "-- Anti-pattern: IN(SELECT ...) where an INNER JOIN would be cleaner.\nSELECT * FROM {outer_table} o\nWHERE o.{key} IN (SELECT i.{key} FROM {inner_table} i WHERE i.flag = 'Y');",
  },
  {
    label: "SELECT *",
    sql:
      "-- Anti-pattern: SELECT * fetches every column, defeating covering scans.\nSELECT * FROM {your_table}\nWHERE id = :1;",
  },
];

// Detects the user's platform once and renders ⌘ for Mac, Ctrl for everyone
// else. Used in the editor toolbar's "press X+Enter to optimize" hint so the
// shortcut symbol matches what the user actually has to press. Falls back to
// "Ctrl" during SSR (no `navigator`) — matches the eventual Windows/Linux
// rendering and avoids a hydration mismatch flash.
function useShortcutKeyLabel(): string {
  const [label, setLabel] = React.useState("Ctrl");
  React.useEffect(() => {
    if (typeof navigator === "undefined") return;
    const ua = navigator.platform || navigator.userAgent || "";
    setLabel(/Mac|iPhone|iPad|iPod/i.test(ua) ? "⌘" : "Ctrl");
  }, []);
  return label;
}

export function QueryEditor({ value, onChange, onRun, busy, connected }: Props) {
  const taRef = React.useRef<HTMLTextAreaElement>(null);
  const preRef = React.useRef<HTMLPreElement>(null);
  const cmdKey = useShortcutKeyLabel();

  // Sync scroll between textarea and highlight overlay
  const onScroll = () => {
    if (preRef.current && taRef.current) {
      preRef.current.scrollTop = taRef.current.scrollTop;
      preRef.current.scrollLeft = taRef.current.scrollLeft;
    }
  };

  const onKeyDown = (e: React.KeyboardEvent<HTMLTextAreaElement>) => {
    // Cmd/Ctrl+Enter to run
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      if (!busy) onRun();
    }
    // Tab inserts two spaces
    if (e.key === "Tab") {
      e.preventDefault();
      const ta = e.currentTarget;
      const s = ta.selectionStart;
      const en = ta.selectionEnd;
      const next = ta.value.slice(0, s) + "  " + ta.value.slice(en);
      onChange(next);
      requestAnimationFrame(() => {
        ta.selectionStart = ta.selectionEnd = s + 2;
      });
    }
  };

  const lines = React.useMemo(() => value.split("\n").length, [value]);

  // True when the editor holds something the user typed (more than just the
  // starter comment placeholder). Used to confirm before a sample click
  // would silently throw it away. We treat blank text and the comment-only
  // starter as "empty enough to overwrite without asking".
  const hasUserContent = React.useMemo(() => {
    const stripped = value
      .split("\n")
      .map((l) => l.trim())
      .filter((l) => l.length > 0 && !l.startsWith("--"))
      .join("");
    return stripped.length > 0;
  }, [value]);

  // Sample SQL ships with {curly_braces} placeholder identifiers that won't
  // parse on Oracle — the user has to swap them for real names first. Detect
  // unfilled placeholders so the toolbar can flag them BEFORE the round-trip
  // failure (which manifests as ORA-00903/942 from EXPLAIN PLAN, ~2s late).
  const hasPlaceholders = React.useMemo(
    () => /\{[a-z_][a-z0-9_]*\}/i.test(value),
    [value],
  );

  const applySample = (sample: { label: string; sql: string }) => {
    if (
      hasUserContent &&
      !window.confirm(
        `Replace your current query with the "${sample.label}" sample? Your edit will be lost.`,
      )
    ) {
      return;
    }
    onChange(sample.sql);
  };

  return (
    <div className="flex flex-col h-full bg-surface">
      {/* Toolbar */}
      <div className="flex items-center gap-2 px-4 h-11 border-b border-default shrink-0">
        <div className="flex items-center gap-1.5 text-[12px] text-muted">
          <IcZap size={13} className="text-accent" />
          <span className="font-medium text-fg">Query editor</span>
          <span className="text-dim">·</span>
          <span className="text-dim">{lines} {lines === 1 ? "line" : "lines"}</span>
        </div>
        <div className="ml-auto flex items-center gap-2">
          <span className="text-[11px] text-dim hidden md:inline">
            <kbd className="px-1.5 py-0.5 rounded border border-default bg-surface-2 font-mono-app text-[10.5px]">{cmdKey}</kbd>{" "}
            <kbd className="px-1.5 py-0.5 rounded border border-default bg-surface-2 font-mono-app text-[10.5px]">↵</kbd>{" "}
            to optimize
          </span>
          <button
            onClick={onRun}
            disabled={busy || !value.trim()}
            className="btn btn-primary disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {busy ? (
              <>
                <span className="inline-block w-3 h-3 rounded-full border-2 border-white border-t-transparent animate-spin" />
                Optimizing…
              </>
            ) : (
              <>
                <IcSparkles size={14} />
                Optimize
              </>
            )}
          </button>
        </div>
      </div>

      {/* Editor surface */}
      <div className="relative flex-1 overflow-hidden">
        {/* Gutter */}
        <div
          aria-hidden
          className="absolute left-0 top-0 bottom-0 w-10 border-r border-default bg-surface-2/50 select-none pointer-events-none font-mono-app text-[12px] text-dim leading-[1.65] py-3 px-2 text-right overflow-hidden"
        >
          {Array.from({ length: lines }).map((_, i) => (
            <div key={i}>{i + 1}</div>
          ))}
        </div>

        {/* Highlight overlay (mirrors textarea) */}
        <pre
          ref={preRef}
          aria-hidden
          className="absolute inset-0 pl-12 pr-4 py-3 m-0 font-mono-app text-[13px] leading-[1.65] whitespace-pre-wrap break-words overflow-auto pointer-events-none"
        >
          <code>{highlightSql(value || " ")}</code>
        </pre>

        {/* Real textarea (transparent text, caret visible) */}
        <textarea
          ref={taRef}
          value={value}
          onChange={(e) => onChange(e.target.value)}
          onScroll={onScroll}
          onKeyDown={onKeyDown}
          spellCheck={false}
          placeholder="-- Paste a slow Oracle query here…"
          className="absolute inset-0 pl-12 pr-4 py-3 font-mono-app text-[13px] leading-[1.65]
                     bg-transparent text-transparent caret-[color:var(--color-accent)]
                     resize-none outline-none w-full h-full whitespace-pre-wrap break-words"
          style={{ WebkitTextFillColor: "transparent" }}
        />
      </div>

      {/* Footer — samples + placeholder hint + status */}
      <div className="border-t border-default px-4 py-2.5 flex flex-wrap items-center gap-2 shrink-0">
        <span className="text-[11px] text-dim mr-1">Try:</span>
        {SAMPLES.map((s) => (
          <button
            key={s.label}
            onClick={() => applySample(s)}
            className="pill hover:bg-surface-3 hover:text-fg transition-colors"
          >
            {s.label}
          </button>
        ))}
        {hasPlaceholders && (
          <span
            className="pill bg-warn-soft text-warn border-transparent"
            title={
              "Sample queries use {your_table} / {your_col} placeholders.\n" +
              "Replace them with real names from your schema before running — Oracle will reject the curly-brace identifiers with ORA-00903 otherwise."
            }
          >
            Replace {"{placeholders}"} before running
          </span>
        )}
        <div className="ml-auto flex items-center gap-1.5 text-[11px]">
          <span
            className={`w-1.5 h-1.5 rounded-full ${connected ? "bg-success pulse-dot" : "bg-warn"}`}
          />
          <span className="text-muted">
            {connected ? "Live DB" : "Disconnected — connect to run analysis"}
          </span>
        </div>
      </div>
    </div>
  );
}
