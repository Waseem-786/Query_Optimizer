import { NextRequest } from "next/server";
import { generateChatReplyStream, type ChatMessage } from "@/lib/llm";

interface ChatRequest {
  messages: ChatMessage[];
  // Optional provider override from the model picker. When omitted the route
  // falls back to LLM_PROVIDER env var or auto-detection in pickProvider().
  provider?: string;
}

// Streaming chat endpoint for the Database Assistant tab.
//
// Wire format: NDJSON (one JSON event per line). Each event is one of:
//   { "type": "meta",  "provider": "...", "model": "..." }
//   { "type": "delta", "text": "..." }
//   { "type": "done"  }
//   { "type": "error", "message": "...", "code"?: "LLM_CONFIG" | "RATE_LIMIT" }
//
// We pick NDJSON over Server-Sent Events because the client only needs to
// read until newline and `JSON.parse` — no event-source framing logic. The
// HTTP status stays 200 even on logical errors so partial deltas can still
// reach the user; the final {type:"error"} event carries the failure mode.
export async function POST(req: NextRequest) {
  const body = (await req.json().catch(() => null)) as ChatRequest | null;
  if (!body || !Array.isArray(body.messages) || body.messages.length === 0) {
    return new Response(
      JSON.stringify({ type: "error", message: "messages[] is required." }) + "\n",
      { status: 400, headers: { "Content-Type": "application/x-ndjson" } },
    );
  }

  // Defensive: cap absurdly long histories so we don't blow the model's
  // context window. Keep the most recent 30 turns.
  const messages = body.messages.slice(-30);

  const encoder = new TextEncoder();
  const stream = new ReadableStream<Uint8Array>({
    async start(controller) {
      try {
        for await (const ev of generateChatReplyStream(messages, body.provider)) {
          controller.enqueue(encoder.encode(JSON.stringify(ev) + "\n"));
        }
      } catch (err) {
        // Defensive: generateChatReplyStream already converts errors into
        // {type:"error"} events, but if anything escapes (e.g. a sync throw
        // before the first yield), emit a final error event so the client
        // doesn't hang waiting for "done".
        const msg = err instanceof Error ? err.message : String(err);
        controller.enqueue(
          encoder.encode(JSON.stringify({ type: "error", message: msg }) + "\n"),
        );
      } finally {
        controller.close();
      }
    },
  });

  return new Response(stream, {
    status: 200,
    headers: {
      "Content-Type": "application/x-ndjson; charset=utf-8",
      "Cache-Control": "no-cache, no-transform",
      // Hint to Next.js / reverse proxies to flush each chunk immediately
      // rather than buffering until the response closes.
      "X-Accel-Buffering": "no",
    },
  });
}
