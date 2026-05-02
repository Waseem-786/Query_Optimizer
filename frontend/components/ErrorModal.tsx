"use client";

import * as React from "react";
import { createPortal } from "react-dom";
import { IcAlert, IcX } from "./icons";

type Props = {
  open: boolean;
  title?: string;
  message: string;
  detail?: string;        // Optional secondary message (e.g. failing SQL)
  onClose: () => void;
};

// Centered, overlay-style error modal. Replaces the old slim red banner that
// hid at the top of the right pane and was easy to miss on small screens.
//
// - Portaled to document.body so ancestor transforms (e.g. fade-up animations
//   or the editor's split-pane) cannot clip it.
// - Esc dismisses; clicking the backdrop dismisses.
// - Body scroll is locked while open.
// - Width caps at 460px and stays centered on every viewport size.
export function ErrorModal({ open, title, message, detail, onClose }: Props) {
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

  return createPortal(
    <div
      className="fixed inset-0 z-[60] flex items-center justify-center p-4"
      role="alertdialog"
      aria-modal="true"
    >
      <div
        className="absolute inset-0 bg-black/60 backdrop-blur-sm"
        onClick={onClose}
      />
      <div className="relative card shadow-lg-app w-full max-w-[460px] overflow-hidden border border-danger/40">
        <div className="flex items-start gap-3 px-5 py-4 border-b border-default bg-danger-soft/30">
          <div className="w-9 h-9 rounded-lg bg-danger-soft border border-danger/40 flex items-center justify-center shrink-0">
            <IcAlert size={17} className="text-danger" />
          </div>
          <div className="flex-1 min-w-0">
            <div className="text-[14px] font-semibold text-danger">
              {title ?? "Could not run analysis"}
            </div>
            <div className="text-[12px] text-muted mt-0.5">
              The database returned an error.
            </div>
          </div>
          <button
            onClick={onClose}
            className="btn btn-ghost btn-icon"
            aria-label="Close error"
          >
            <IcX size={15} />
          </button>
        </div>

        <div className="px-5 py-4 space-y-3">
          <div className="rounded-md bg-surface-2 border border-default p-3">
            <div className="text-[11px] uppercase tracking-wide text-dim font-semibold mb-1.5">
              Error
            </div>
            <div className="text-[12.5px] text-fg font-mono-app whitespace-pre-wrap break-words">
              {message}
            </div>
          </div>

          {detail && (
            <div className="rounded-md bg-surface-2 border border-default p-3">
              <div className="text-[11px] uppercase tracking-wide text-dim font-semibold mb-1.5">
                Details
              </div>
              <div className="text-[12px] text-muted font-mono-app whitespace-pre-wrap break-words">
                {detail}
              </div>
            </div>
          )}

          <div className="text-[11.5px] text-dim leading-relaxed">
            Common causes: the referenced table/view doesn&apos;t exist, the connecting
            user lacks SELECT privileges, the query is non-SELECT, or the connection
            timed out. Press Esc or click outside to dismiss.
          </div>
        </div>

        <div className="px-5 py-3 border-t border-default flex items-center justify-end gap-2 bg-surface-2/50">
          <button onClick={onClose} className="btn btn-primary">
            Got it
          </button>
        </div>
      </div>
    </div>,
    document.body,
  );
}
