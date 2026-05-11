"use client";

import * as React from "react";
import { IcSend, IcMessage, IcSparkles, IcTrash } from "./icons";
import { SqlBlock } from "./SqlBlock";
import { ProviderPicker } from "./ProviderPicker";
import { MarkdownRender } from "./MarkdownRender";
import { type LlmProvider, type ProviderStatusMap } from "@/lib/use-llm-provider";

export type Msg = {
  id: string;
  role: "user" | "assistant";
  content: string;
  sql?: string;
  // Set while the assistant message is mid-stream so the UI can show a
  // typing-style cursor and disable the Send button. Cleared on done/error.
  streaming?: boolean;
};

const SUGGESTIONS = [
  "Explain why a hash join can outperform a nested loop.",
  "Write me a query to find duplicate rows in a table.",
  "How do I read DBMS_XPLAN output?",
  "When should I use a function-based index vs a virtual column?",
];

// ChatPanel is now CONTROLLED at the message level — the parent owns the
// list of chats (each with its own messages array) and feeds us the active
// chat's messages via `initialMessages`. We keep an internal mirror so
// streaming token-by-token updates stay snappy without bouncing through the
// parent on every delta; the parent gets notified of the final state via
// `onMessagesChange` at meaningful turn boundaries (user-sent, stream done,
// error). Parent assigns a fresh chatId on first send, so each conversation
// gets its own sidebar entry like Optimize runs do.

export function ChatPanel({
  initialChatId,
  initialMessages = [],
  onMessagesChange,
  provider,
  setProvider,
  providerStatus,
}: {
  // Stable id for THIS conversation. Provided by the parent when restoring a
  // chat from history. Undefined for a fresh "New chat" — we generate one on
  // the user's first submit so the parent can store the chat under that key.
  initialChatId?: string;
  initialMessages?: Msg[];
  // (chatId, messages) — the chatId lets the parent route updates to the
  // correct history entry even if the user has since switched chats. Prevents
  // an orphan stream from overwriting whichever chat happens to be active
  // when the stream finishes.
  onMessagesChange?: (chatId: string, next: Msg[]) => void;
  provider: LlmProvider;
  setProvider: (p: LlmProvider) => void;
  providerStatus: ProviderStatusMap | null;
}) {
  const [messages, setMessages] = React.useState<Msg[]>(initialMessages);
  const [input, setInput] = React.useState("");
  const [busy, setBusy] = React.useState(false);
  const scrollRef = React.useRef<HTMLDivElement>(null);

  // Stable chat id. Captured from initialChatId when restoring, or minted on
  // first send. Stays the same for the lifetime of this ChatPanel instance —
  // remounting (via chatLoadKey in the parent) resets it.
  const chatIdRef = React.useRef<string | null>(initialChatId ?? null);

  // Cancel an in-flight stream when the component unmounts (chat switch /
  // "New chat" / mode change). Without this, the orphan fetch would keep
  // reading bytes from the server long after the user navigated away — and
  // its final notify() call would land on a stale parent handler, possibly
  // corrupting the now-active chat.
  const abortRef = React.useRef<AbortController | null>(null);
  React.useEffect(() => {
    return () => {
      abortRef.current?.abort();
    };
  }, []);

  // Always have the latest onMessagesChange so the closures inside send()
  // call back to the current parent (no stale ref after re-render).
  const onMessagesChangeRef = React.useRef(onMessagesChange);
  React.useEffect(() => {
    onMessagesChangeRef.current = onMessagesChange;
  }, [onMessagesChange]);
  // Helper — sanitises messages before notifying the parent so the persisted
  // history is clean:
  //   1. Strip ephemeral `streaming` flags (otherwise a reload shows a stuck
  //      caret on a finished message).
  //   2. Drop assistant placeholders whose content is still empty. They only
  //      matter inside the running ChatPanel for the typing-indicator UX; if
  //      a stream gets aborted mid-flight (user switched chats, hit "New
  //      chat", etc.), persisting an empty bubble in history is just noise.
  // Routes via the stable chatIdRef so the parent always updates THIS chat,
  // even if the user has switched away.
  const notify = React.useCallback((msgs: Msg[]) => {
    const id = chatIdRef.current;
    if (!id) return;
    const clean = msgs
      .map((m) => {
        if (!m.streaming) return m;
        const copy: Msg = { ...m };
        delete copy.streaming;
        return copy;
      })
      .filter((m) => !(m.role === "assistant" && m.content === ""));
    onMessagesChangeRef.current?.(id, clean);
  }, []);

  React.useEffect(() => {
    scrollRef.current?.scrollTo({ top: scrollRef.current.scrollHeight, behavior: "smooth" });
  }, [messages, busy]);

  const clearChat = () => {
    // If we have a stable chatId, notify the parent so it drops the history
    // entry. Reset the id too so the next send starts a fresh chat.
    abortRef.current?.abort();
    setMessages([]);
    notify([]);
    chatIdRef.current = null;
  };

  // Send the full conversation history to /api/chat each call. The route is
  // stateless and replies as NDJSON — one JSON event per line — so we read
  // the response body as a stream and append text deltas to the in-flight
  // assistant message as they arrive (ChatGPT / Claude UX).
  //
  // Events emitted by the route (see app/api/chat/route.ts):
  //   {type:"meta",  provider, model}
  //   {type:"delta", text}
  //   {type:"done"}
  //   {type:"error", message, code?}
  const send = async (text: string) => {
    if (!text.trim() || busy) return;
    // Mint our stable chat id the first time the user sends. From here on,
    // every notify() routes back to THIS history entry — switching chats
    // can't trick a stale stream into overwriting the active one.
    if (!chatIdRef.current) chatIdRef.current = crypto.randomUUID();

    const userMsg: Msg = { id: crypto.randomUUID(), role: "user", content: text };
    const assistantId = crypto.randomUUID();
    const placeholder: Msg = {
      id: assistantId,
      role: "assistant",
      content: "",
      streaming: true,
    };
    const nextMessages = [...messages, userMsg, placeholder];
    setMessages(nextMessages);
    setInput("");
    setBusy(true);
    // Tell the parent about the user submission immediately so the new chat
    // appears in the sidebar before the assistant has finished streaming.
    notify(nextMessages);

    // Track the latest messages locally too. Two reasons:
    //   1. After the stream, we need the final list to pass to notify(). We
    //      can't read it from React state synchronously inside setMessages
    //      (the updater runs during render — calling notify() there triggers
    //      a React warning + silently drops the parent setState update).
    //   2. Multiple deltas can land in one tick; React batches but our local
    //      copy is the truth between batches.
    let currentMessages: Msg[] = nextMessages;
    const applyAssistantMutation = (mutate: (m: Msg) => Partial<Msg>) => {
      currentMessages = currentMessages.map((m) =>
        m.id === assistantId ? { ...m, ...mutate(m) } : m,
      );
      setMessages(currentMessages);
    };

    // Fresh AbortController for THIS send. The unmount cleanup effect
    // aborts the previous one (if any), and any in-flight fetch tied to it
    // throws AbortError below — which we swallow so we don't paint a
    // misleading "Network error" on chats the user already moved away from.
    abortRef.current?.abort();
    const ac = new AbortController();
    abortRef.current = ac;

    try {
      const res = await fetch("/api/chat", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          // Don't include the empty placeholder in what we send up.
          messages: nextMessages
            .filter((m) => m.id !== assistantId)
            .map(({ role, content }) => ({ role, content })),
          provider,
        }),
        signal: ac.signal,
      });
      if (!res.body) throw new Error("Empty response body");
      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      // NDJSON parser: append incoming bytes to buffer, split on newline,
      // JSON.parse each complete line. Anything after the last newline is
      // kept in the buffer until the next chunk completes it.
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        buffer += decoder.decode(value, { stream: true });
        let nl = buffer.indexOf("\n");
        while (nl !== -1) {
          const line = buffer.slice(0, nl).trim();
          buffer = buffer.slice(nl + 1);
          nl = buffer.indexOf("\n");
          if (!line) continue;
          let ev: { type: string; text?: string; message?: string; code?: string };
          try { ev = JSON.parse(line); } catch { continue; }
          if (ev.type === "delta" && typeof ev.text === "string") {
            applyAssistantMutation((m) => ({ content: m.content + ev.text }));
          } else if (ev.type === "error") {
            const msg =
              ev.code === "LLM_CONFIG"
                ? `Assistant is not configured: ${ev.message}`
                : ev.message || "Assistant error";
            applyAssistantMutation(() => ({ content: msg, streaming: false }));
          } else if (ev.type === "done") {
            applyAssistantMutation(() => ({ streaming: false }));
          }
          // ev.type === "meta" is currently ignored on the client — provider
          // is already shown in the picker; model name could be rendered
          // later as a small badge if needed.
        }
      }
      // Drain any trailing partial line (unlikely but defensive).
      const tail = buffer.trim();
      if (tail) {
        try {
          const ev = JSON.parse(tail);
          if (ev.type === "delta" && typeof ev.text === "string") {
            applyAssistantMutation((m) => ({ content: m.content + ev.text }));
          }
        } catch { /* ignore */ }
      }
      // Final safety: clear streaming flag in case we never saw an explicit
      // "done" (some providers close without one).
      currentMessages = currentMessages.map((m) =>
        m.id === assistantId
          ? { ...m, streaming: false, content: m.content || "(empty reply)" }
          : m,
      );
      setMessages(currentMessages);
      notify(currentMessages);
    } catch (err) {
      // AbortError from the unmount cleanup — the user navigated away. Don't
      // notify (the chat may have been deleted, or we'd just overwrite the
      // last-known good state with a misleading "Network error"). Whatever
      // state we already saved during streaming stays put.
      const name = err instanceof Error ? err.name : "";
      if (name === "AbortError" || ac.signal.aborted) {
        return;
      }
      const msg = `Network error: ${err instanceof Error ? err.message : String(err)}`;
      currentMessages = currentMessages.map((m) =>
        m.id === assistantId ? { ...m, content: msg, streaming: false } : m,
      );
      setMessages(currentMessages);
      notify(currentMessages);
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
          <ProviderPicker
            provider={provider}
            setProvider={setProvider}
            status={providerStatus}
          />
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

        {messages.map((m) => {
          const isUser = m.role === "user";
          const isEmptyStreaming = !isUser && m.streaming && m.content.length === 0;
          return (
            <div key={m.id} className={`flex gap-3 fade-up ${isUser ? "justify-end" : ""}`}>
              {!isUser && (
                <div className="w-7 h-7 rounded-lg bg-gradient-brand flex items-center justify-center shrink-0 mt-0.5">
                  <IcSparkles size={13} className="text-white" />
                </div>
              )}
              <div className={`max-w-[78%] ${isUser ? "" : "flex-1"}`}>
                <div className={`px-3.5 py-2.5 rounded-xl text-[13px] leading-relaxed ${
                  isUser
                    ? "bg-accent-soft text-fg border border-[color:var(--color-accent)]/30"
                    : "card"
                }`}>
                  {isUser ? (
                    // User messages stay plain text — no markdown surprises.
                    m.content
                  ) : isEmptyStreaming ? (
                    // First-token wait — show the three-dot typing indicator
                    // (replaces the old separate "busy" row).
                    <div className="flex gap-1 py-0.5">
                      <span className="w-1.5 h-1.5 rounded-full bg-text-dim pulse-dot" style={{ animationDelay: "0ms" }} />
                      <span className="w-1.5 h-1.5 rounded-full bg-text-dim pulse-dot" style={{ animationDelay: "200ms" }} />
                      <span className="w-1.5 h-1.5 rounded-full bg-text-dim pulse-dot" style={{ animationDelay: "400ms" }} />
                    </div>
                  ) : (
                    <>
                      <MarkdownRender>{m.content}</MarkdownRender>
                      {m.streaming && (
                        // Blinking caret while more tokens are streaming in.
                        <span
                          aria-hidden
                          className="inline-block w-1.5 h-3.5 align-text-bottom ml-0.5 bg-accent/80 streaming-caret"
                        />
                      )}
                    </>
                  )}
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
          );
        })}
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
