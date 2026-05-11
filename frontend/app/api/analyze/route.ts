import { NextRequest, NextResponse } from "next/server";
import { generateRewrite, LlmConfigError, type RewriteRequest } from "@/lib/llm";

// Body shape: RewriteRequest + optional `provider` override that the frontend
// settings modal can pass through. The route validates/honours it via
// pickProvider() in lib/llm.ts.
interface AnalyzeBody extends RewriteRequest {
  provider?: string;
}

export async function POST(req: NextRequest) {
  try {
    const body = (await req.json()) as AnalyzeBody;
    if (!body.query || !body.query.trim()) {
      return NextResponse.json({ error: "Query is required." }, { status: 400 });
    }

    const analysis = await generateRewrite(body, body.provider);
    return NextResponse.json(analysis);
  } catch (err) {
    if (err instanceof LlmConfigError) {
      return NextResponse.json({ error: err.message, code: "LLM_CONFIG" }, { status: 503 });
    }
    const msg = err instanceof Error ? err.message : "Unknown error";
    // Detect Gemini / Anthropic rate-limit errors and surface a friendly,
    // actionable message instead of the raw SDK JSON. Mirrors the same logic
    // in /api/chat so both LLM paths fail the same way.
    if (/429|quota|rate.?limit|RESOURCE_EXHAUSTED/i.test(msg)) {
      return NextResponse.json(
        {
          error:
            "AI rewrite hit the free-tier rate limit. Wait ~1 minute (or check your daily quota at aistudio.google.com) and try again.",
          code: "RATE_LIMIT",
        },
        { status: 429 },
      );
    }
    return NextResponse.json({ error: msg }, { status: 500 });
  }
}
