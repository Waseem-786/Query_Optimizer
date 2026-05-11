"use client";

import * as React from "react";

// All three providers the backend's pickProvider() understands. Keep in sync
// with LlmProvider in lib/llm.ts.
export type LlmProvider = "gemini" | "anthropic" | "claude-code";

export interface ProviderStatus {
  available: boolean;
  reason?: string;
}

export type ProviderStatusMap = Record<LlmProvider, ProviderStatus>;

const STORAGE_KEY = "querymind.llm.provider.v1";

// Default to "claude-code" so users with Claude Code installed get a working
// experience out of the box even without a separate API key. The settings
// UI and runtime errors will guide them to switch if it's not configured.
const DEFAULT_PROVIDER: LlmProvider = "claude-code";

const VALID: LlmProvider[] = ["gemini", "anthropic", "claude-code"];

export const PROVIDER_LABELS: Record<LlmProvider, string> = {
  "gemini": "Gemini",
  "anthropic": "Anthropic API",
  "claude-code": "Claude Code",
};

export const PROVIDER_DESCRIPTIONS: Record<LlmProvider, string> = {
  "gemini": "Free tier from aistudio.google.com. Fast and forgiving but rate-limited; ~250 calls/day on the free plan.",
  "anthropic": "Paid Anthropic API (console.anthropic.com). Reliable, but every call is metered.",
  "claude-code": "Uses your local Claude Code OAuth session. No separate API key needed if Claude Code is installed and logged in.",
};

export interface UseLlmProviderResult {
  provider: LlmProvider;
  setProvider: (p: LlmProvider) => void;
  status: ProviderStatusMap | null;   // null while still loading
  loadingStatus: boolean;
  isAvailable: (p: LlmProvider) => boolean;
}

/**
 * Reads the user's selected LLM provider from sessionStorage and exposes a
 * setter that persists changes. Also fetches /api/llm-status once on mount
 * so consumers can render availability indicators.
 */
export function useLlmProvider(): UseLlmProviderResult {
  const [provider, setProviderState] = React.useState<LlmProvider>(DEFAULT_PROVIDER);
  const [status, setStatus] = React.useState<ProviderStatusMap | null>(null);
  const [loadingStatus, setLoadingStatus] = React.useState(true);

  // Restore choice from sessionStorage on mount.
  React.useEffect(() => {
    if (typeof window === "undefined") return;
    try {
      const stored = sessionStorage.getItem(STORAGE_KEY);
      if (stored && VALID.includes(stored as LlmProvider)) {
        setProviderState(stored as LlmProvider);
      }
    } catch { /* ignore */ }
  }, []);

  // Fetch availability once. Status is cached for the lifetime of the page;
  // re-running it on every component mount would spam the route.
  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch("/api/llm-status");
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json() as { providers: ProviderStatusMap };
        if (!cancelled) setStatus(data.providers);
      } catch {
        if (!cancelled) setStatus(null);
      } finally {
        if (!cancelled) setLoadingStatus(false);
      }
    })();
    return () => { cancelled = true; };
  }, []);

  const setProvider = React.useCallback((p: LlmProvider) => {
    setProviderState(p);
    if (typeof window !== "undefined") {
      try { sessionStorage.setItem(STORAGE_KEY, p); } catch { /* ignore */ }
    }
  }, []);

  const isAvailable = React.useCallback(
    (p: LlmProvider) => (status ? status[p].available : true),
    [status],
  );

  return { provider, setProvider, status, loadingStatus, isAvailable };
}
