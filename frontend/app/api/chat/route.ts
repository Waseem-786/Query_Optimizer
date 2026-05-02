import { NextRequest, NextResponse } from "next/server";
import { generateChatReply, LlmConfigError, type ChatMessage } from "@/lib/llm";

interface ChatRequest {
  messages: ChatMessage[];
}

// Stateless chat endpoint for the Database Assistant tab. The frontend sends
// the full conversation history each call; we add the system prompt and call
// the configured LLM provider (Gemini by default, Anthropic when explicitly
// selected via LLM_PROVIDER).
export async function POST(req: NextRequest) {
  try {
    const body = (await req.json()) as ChatRequest;
    if (!Array.isArray(body.messages) || body.messages.length === 0) {
      return NextResponse.json({ error: "messages[] is required." }, { status: 400 });
    }

    // Defensive: cap absurdly long histories so we don't blow the model's
    // context window. Keep the most recent 30 turns.
    const messages = body.messages.slice(-30);

    const reply = await generateChatReply(messages);
    return NextResponse.json(reply);
  } catch (err) {
    if (err instanceof LlmConfigError) {
      return NextResponse.json({ error: err.message, code: "LLM_CONFIG" }, { status: 503 });
    }
    const msg = err instanceof Error ? err.message : "Unknown error";
    // Detect Gemini / Anthropic rate-limit errors and surface a friendly,
    // actionable message instead of the raw JSON the SDK throws.
    if (/429|quota|rate.?limit/i.test(msg)) {
      return NextResponse.json(
        {
          error:
            "The free-tier rate limit was exceeded. Wait ~1 minute (or check your daily quota at aistudio.google.com) and try again.",
          code: "RATE_LIMIT",
        },
        { status: 429 },
      );
    }
    return NextResponse.json({ error: msg }, { status: 500 });
  }
}
