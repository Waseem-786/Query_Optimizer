import { NextResponse } from "next/server";
import { providerStatus } from "@/lib/llm";

// Reports which LLM providers are configured well enough to be callable.
// The frontend model picker uses this to render an availability dot per
// provider and to disable options that would fail. No API keys ever leak
// in the response — only a boolean and a human-readable reason string.
//
// GET so the picker can hit it on mount without preflight noise.
export async function GET() {
  return NextResponse.json({ providers: providerStatus() });
}
