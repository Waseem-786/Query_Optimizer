"use client";

import * as React from "react";
import { IcSend, IcMessage, IcSparkles, IcTrash } from "./icons";
import { SqlBlock } from "./SqlBlock";

type Msg = { id: string; role: "user" | "assistant"; content: string; sql?: string };

const SUGGESTIONS = [
  "Explain why a hash join can outperform a nested loop.",
  "Write me a query to find duplicate rows in a table.",
  "How do I read DBMS_XPLAN output?",
  "When should I use a function-based index vs a virtual column?",
];

// Persist chat messages to sessionStorage so a page reload doesn't wipe the
// conversation. Per-tab (sessionStorage, not localStorage) so opening a new
// tab gives a fresh chat — matches how the connection persists. Versioned key
// in case the Msg shape changes later.
const CHAT_STORAGE_KEY = "querymind.chat.v1";

function loadStoredChat(): Msg[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = sessionStorage.getItem(CHAT_STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter(
      (m) =>
        m && typeof m.id === "string" && (m.role === "user" || m.role === "assistant") &&
        typeof m.content === "string",
    );
  } catch {
    return [];
  }
}

export function ChatPanel({ clearSignal = 0 }: { clearSignal?: number } = {}) {
  const [messages, setMessages] = React.useState<Msg[]>([]);
  const [input, setInput] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const scrollRef = React.useRef<HTMLDivElement>(null);

  // Restore on mount.
  React.useEffect(() => {
    const stored = loadStoredChat();
    if (stored.length > 0) setMessages(stored);
  }, []);

  // Page-level "New chat" button bumps `clearSignal`. We treat it the same
  // way as the in-panel Clear button — wipe messages + sessionStorage.
  // Skip the first render (signal=0) so we don't blow away whatever we just
  // restored from storage.
  const initialClearSignalRef = React.useRef(clearSignal);
  React.useEffect(() => {
    if (clearSignal === initialClearSignalRef.current) return;
    setMessages([]);
    if (typeof window !== "undefined") {
      try { sessionStorage.removeItem(CHAT_STORAGE_KEY); } catch { /* ignore */ }
    }
  }, [clearSignal]);

  // Save on every change. Cap at the last 100 messages to keep storage bounded
  // (typical messages are < 4 KB; 100 turns ≈ 400 KB, well under sessionStorage's
  // ~5 MB browser limit but plenty for any realistic conversation).
  React.useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      if (messages.length === 0) {
        sessionStorage.removeItem(CHAT_STORAGE_KEY);
      } else {
        sessionStorage.setItem(
          CHAT_STORAGE_KEY,
          JSON.stringify(messages.slice(-100)),
        );
      }
    } catch { /* quota errors are non-fatal — chat still works in memory */ }
  }, [messages]);

  React.useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages, busy]);

  const clearChat = () => {
    setMessages([]);
    if (typeof window !== "undefined") {
      try { sessionStorage.removeItem(CHAT_STORAGE_KEY); } catch { /* ignore */ }
    }
  };

  // Send the full conversation history to /api/chat each call. The route is
  // stateless; the system prompt + scope guardrail (DB-only) lives server-side
  // in lib/llm.ts so it can't be tampered with via DevTools.
  const send = async (text: string) => {
    if (!text.trim() || busy) return;
    const userMsg: Msg = { id: crypto.randomUUID(), role: "user", content: text };
    const nextMessages = [...messages, userMsg];
    setMessages(nextMessages);
    setInput("");
    setBusy(true);
    try {
      const res = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          messages: nextMessages.map(({ role, content }) => ({ role, content })),
        }),
      });
      const data = await res.json();
      if (!res.ok) {
        const msg =
          data.code === "LLM_CONFIG"
            ? `Assistant is not configured: ${data.error}`
            : `Assistant error: ${data.error || `HTTP ${res.status}`}`;
        setMessages((m) => [...m, {
          id: crypto.randomUUID(),
          role: "assistant",
          content: msg,
        }]);
      } else {
        setMessages((m) => [...m, {
          id: crypto.randomUUID(),
          role: "assistant",
          content: data.content || "(empty reply)",
        }]);
      }
    } catch (err) {
      setMessages((m) => [...m, {
        id: crypto.randomUUID(),
        role: "assistant",
        content: `Network error: ${err instanceof Error ? err.message : String(err)}`,
      }]);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex flex-col h-full bg-bg">
      <div className="flex items-center gap-2 px-4 h-11 border-b border-default bg-surface shrink-0">
        <IcMessage size={14} className="text-info" />
        <div className="text-[12.5px] font-semibold">Database Assistant</div>
        <div className="ml-auto flex items-center gap-2">
          <span className="pill">DB knowledge · Oracle</span>
          {messages.length > 0 && (
            <button
              onClick={clearChat}
              className="btn btn-ghost text-[11px] px-2 py-1 inline-flex items-center gap-1"
              title="Clear conversation history"
            >
              <IcTrash size={11} />
              Clear
            </button>
          )}
        </div>
      </div>

      <div ref={scrollRef} className="flex-1 overflow-y-auto p-5 space-y-4">
        {messages.length === 0 && (
          <div className="max-w-[520px] mx-auto text-center fade-up py-10">
            <div className="w-12 h-12 rounded-xl bg-info-soft border border-default mx-auto mb-3 flex items-center justify-center">
              <IcMessage size={20} className="text-info" />
            </div>
            <h3 className="text-[16px] font-semibold tracking-tight">Ask anything about your DB</h3>
            <p className="text-[13px] text-muted mt-1.5">
              Indexes, plan reading, locking, partitioning — explained in plain English.
            </p>
            <div className="mt-5 grid grid-cols-1 sm:grid-cols-2 gap-2 text-left">
              {SUGGESTIONS.map((s) => (
                <button
                  key={s}
                  onClick={() => send(s)}
                  className="card px-3 py-2.5 text-[12.5px] text-muted hover:text-fg hover:bg-surface-2 transition-colors"
                >
                  {s}
                </button>
              ))}
            </div>
          </div>
        )}

        {messages.map((m) => (
          <div key={m.id} className={`flex gap-3 fade-up ${m.role === "user" ? "justify-end" : ""}`}>
            {m.role === "assistant" && (
              <div className="w-7 h-7 rounded-lg bg-gradient-brand flex items-center justify-center shrink-0 mt-0.5">
                <IcSparkles size={13} className="text-white" />
              </div>
            )}
            <div className={`max-w-[78%] ${m.role === "user" ? "" : "flex-1"}`}>
              <div className={`px-3.5 py-2.5 rounded-xl text-[13px] leading-relaxed ${
                m.role === "user"
                  ? "bg-accent-soft text-fg border border-[color:var(--color-accent)]/30"
                  : "card"
              }`}>
                {m.content}
              </div>
              {m.sql && (
                <div className="mt-2 card overflow-hidden">
                  <div className="px-3 py-1.5 border-b border-default text-[11px] uppercase tracking-wide text-dim font-semibold">
                    Suggested SQL
                  </div>
                  <div className="p-3"><SqlBlock sql={m.sql} /></div>
                </div>
              )}
            </div>
          </div>
        ))}

        {busy && (
          <div className="flex gap-3 fade-up">
            <div className="w-7 h-7 rounded-lg bg-gradient-brand flex items-center justify-center shrink-0 mt-0.5">
              <IcSparkles size={13} className="text-white" />
            </div>
            <div className="card px-3.5 py-2.5">
              <div className="flex gap-1">
                <span className="w-1.5 h-1.5 rounded-full bg-text-dim pulse-dot" style={{ animationDelay: "0ms" }} />
                <span className="w-1.5 h-1.5 rounded-full bg-text-dim pulse-dot" style={{ animationDelay: "200ms" }} />
                <span className="w-1.5 h-1.5 rounded-full bg-text-dim pulse-dot" style={{ animationDelay: "400ms" }} />
              </div>
            </div>
          </div>
        )}
      </div>

      <form
        onSubmit={(e) => { e.preventDefault(); send(input); }}
        className="border-t border-default p-3 bg-surface shrink-0"
      >
        <div className="flex items-end gap-2 card px-3 py-2 focus-within:border-strong">
          <textarea
            value={input}
            onChange={(e) => setInput(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                send(input);
              }
            }}
            rows={1}
            placeholder="Ask about indexes, plans, locking, partitioning…"
            className="flex-1 bg-transparent text-[13px] outline-none resize-none max-h-32 leading-relaxed"
          />
          <button
            type="submit"
            disabled={!input.trim() || busy}
            className="btn btn-primary btn-icon disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <IcSend size={14} />
          </button>
        </div>
      </form>
    </div>
  );
}
