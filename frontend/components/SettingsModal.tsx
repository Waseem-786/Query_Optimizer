"use client";

import * as React from "react";
import { createPortal } from "react-dom";
import { IcSettings, IcX, IcCheck, IcAlert, IcSparkles } from "./icons";
import {
  type LlmProvider,
  type ProviderStatusMap,
  PROVIDER_LABELS,
  PROVIDER_DESCRIPTIONS,
} from "@/lib/use-llm-provider";

// Full-detail settings modal for picking the LLM provider. Opened via the
// gear icon in the sidebar. The compact ProviderPicker (in the chat header)
// stays in sync because they share state through useLlmProvider().
export function SettingsModal({
  open,
  onClose,
  provider,
  setProvider,
  status,
  loadingStatus,
}: {
  open: boolean;
  onClose: () => void;
  provider: LlmProvider;
  setProvider: (p: LlmProvider) => void;
  status: ProviderStatusMap | null;
  loadingStatus: boolean;
}) {
  const [mounted, setMounted] = React.useState(false);
  React.useEffect(() => setMounted(true), []);

  React.useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    document.addEventListener("keydown", onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prev;
    };
  }, [open, onClose]);

  if (!mounted || !open) return null;

  const options: LlmProvider[] = ["claude-code", "gemini", "anthropic"];

  return createPortal(
    <div
      className="fixed inset-0 z-[60] flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="settings-modal-title"
    >
      <div
        className="absolute inset-0 bg-black/60 backdrop-blur-sm"
        onClick={onClose}
      />
      <div className="relative card shadow-lg-app w-full max-w-[560px] overflow-hidden">
        {/* Header */}
        <div className="flex items-start gap-3 px-5 py-4 border-b border-default">
          <div className="w-9 h-9 rounded-lg bg-accent-soft border border-default flex items-center justify-center shrink-0">
            <IcSettings size={17} className="text-accent" />
          </div>
          <div className="flex-1 min-w-0">
            <div id="settings-modal-title" className="text-[14px] font-semibold">
              Settings
            </div>
            <div className="text-[12px] text-muted mt-0.5">
              Pick which AI provider powers the rewrite tab and Database Assistant.
            </div>
          </div>
          <button
            onClick={onClose}
            className="btn btn-ghost btn-icon"
            aria-label="Close settings"
          >
            <IcX size={15} />
          </button>
        </div>

        {/* AI provider section */}
        <div className="px-5 py-4">
          <div className="flex items-center gap-2 text-[11.5px] uppercase tracking-wide text-dim font-semibold mb-3">
            <IcSparkles size={11} className="text-accent" />
            AI provider
          </div>

          <div className="space-y-2">
            {options.map((p) => {
              const isActive = provider === p;
              const s = status?.[p];
              const available = s?.available ?? true;
              return (
                <button
                  key={p}
                  onClick={() => setProvider(p)}
                  className={`w-full text-left rounded-lg border px-3.5 py-3 transition-colors ${
                    isActive
                      ? "border-[color:var(--color-accent)] bg-accent-soft"
                      : "border-default hover:bg-surface-2"
                  }`}
                  aria-pressed={isActive}
                >
                  <div className="flex items-center gap-2">
                    <span
                      className={`w-2 h-2 rounded-full shrink-0 ${
                        available ? "bg-success" : "bg-danger"
                      }`}
                      title={available ? "Available" : "Not configured"}
                    />
                    <span className="text-[13px] font-medium flex-1">
                      {PROVIDER_LABELS[p]}
                    </span>
                    {isActive && (
                      <span className="pill bg-accent-soft text-accent border-transparent !py-0 !px-1.5 !text-[10.5px]">
                        <IcCheck size={10} />
                        Active
                      </span>
                    )}
                  </div>
                  <p className="text-[12px] text-muted mt-1.5 leading-relaxed">
                    {PROVIDER_DESCRIPTIONS[p]}
                  </p>
                  {!available && s?.reason && (
                    <p className="mt-2 text-[11.5px] text-danger flex items-start gap-1.5">
                      <IcAlert size={11} className="mt-0.5 shrink-0" />
                      <span>{s.reason}</span>
                    </p>
                  )}
                </button>
              );
            })}
          </div>

          {loadingStatus && (
            <p className="mt-3 text-[11px] text-dim">Checking provider availability…</p>
          )}
        </div>

        {/* Footer hint */}
        <div className="px-5 py-3 border-t border-default bg-surface-2/50">
          <p className="text-[11.5px] text-dim leading-relaxed">
            Choice is saved per-tab. Picking an unconfigured provider will return a
            friendly error when you actually run a query — nothing is locked in.
          </p>
        </div>

        <div className="px-5 py-3 border-t border-default flex items-center justify-end gap-2">
          <button onClick={onClose} className="btn btn-primary">
            Done
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
