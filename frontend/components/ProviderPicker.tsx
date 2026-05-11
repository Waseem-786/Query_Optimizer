"use client";

import * as React from "react";
import { IcChevronDown, IcSparkles, IcCheck, IcAlert } from "./icons";
import {
  type LlmProvider,
  type ProviderStatusMap,
  PROVIDER_LABELS,
} from "@/lib/use-llm-provider";

/**
 * Compact LLM-provider dropdown. Shown in the Database Assistant header so
 * users can switch model without opening the full Settings modal. Closes on
 * outside click + Escape; availability shown as a green/red dot per option.
 *
 * Self-contained — receives provider + setter from the caller's
 * useLlmProvider() hook so the SettingsModal and this picker stay in sync
 * across renders.
 */
export function ProviderPicker({
  provider,
  setProvider,
  status,
  className = "",
}: {
  provider: LlmProvider;
  setProvider: (p: LlmProvider) => void;
  status: ProviderStatusMap | null;
  className?: string;
}) {
  const [open, setOpen] = React.useState(false);
  const ref = React.useRef<HTMLDivElement>(null);

  // Outside-click + Escape close the menu, matching native <select> UX.
  React.useEffect(() => {
    if (!open) return;
    const onDown = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    };
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") setOpen(false); };
    document.addEventListener("mousedown", onDown);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onDown);
      document.removeEventListener("keydown", onKey);
    };
  }, [open]);

  const options: LlmProvider[] = ["claude-code", "gemini", "anthropic"];

  return (
    <div ref={ref} className={`relative ${className}`}>
      <button
        onClick={() => setOpen((o) => !o)}
        className="pill hover:bg-surface-3 transition-colors inline-flex items-center gap-1.5"
        title="Switch AI provider"
        aria-haspopup="menu"
        aria-expanded={open}
      >
        <IcSparkles size={11} className="text-accent" />
        <span className="text-fg/80">AI:</span>
        <span className="font-medium">{PROVIDER_LABELS[provider]}</span>
        <IcChevronDown size={11} className={`text-dim transition-transform ${open ? "rotate-180" : ""}`} />
      </button>

      {open && (
        <div
          role="menu"
          className="absolute right-0 top-full mt-1.5 z-30 w-[220px] card shadow-md-app overflow-hidden fade-up"
        >
          <div className="px-3 py-2 text-[10.5px] uppercase tracking-wide text-dim font-semibold border-b border-default">
            AI provider
          </div>
          <ul className="py-1">
            {options.map((p) => {
              const isActive = provider === p;
              const s = status?.[p];
              const available = s?.available ?? true;
              return (
                <li key={p}>
                  <button
                    onClick={() => { setProvider(p); setOpen(false); }}
                    className={`w-full px-3 py-2 flex items-center gap-2 text-left text-[12.5px] transition-colors ${
                      isActive ? "bg-surface-2" : "hover:bg-surface-2"
                    }`}
                    title={s?.reason ?? PROVIDER_LABELS[p]}
                    role="menuitem"
                  >
                    <span
                      className={`w-1.5 h-1.5 rounded-full ${
                        available ? "bg-success" : "bg-danger"
                      }`}
                    />
                    <span className="flex-1 truncate">{PROVIDER_LABELS[p]}</span>
                    {isActive && <IcCheck size={12} className="text-accent" />}
                    {!available && !isActive && (
                      <IcAlert size={11} className="text-warn" />
                    )}
                  </button>
                </li>
              );
            })}
          </ul>
          <div className="px-3 py-2 border-t border-default text-[11px] text-dim leading-snug">
            Click the gear icon for full provider settings.
          </div>
        </div>
      )}
    </div>
  );
}
