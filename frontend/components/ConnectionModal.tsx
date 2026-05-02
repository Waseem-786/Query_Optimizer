"use client";

import * as React from "react";
import { IcX, IcDatabase, IcKey, IcCheck, IcAlert } from "./icons";

export type ConnectionInfo = {
  user: string;
  host: string;
  port: string;
  service: string;
  password: string;
};

type Props = {
  open: boolean;
  onClose: () => void;
  onConnect: (info: ConnectionInfo) => void;
  current: ConnectionInfo | null;
};

// Defined at module scope so React keeps the same component identity across
// renders. Declaring it inside ConnectionModal would create a new function
// reference on every keystroke, causing React to unmount + remount each input
// and steal focus back to the autoFocused field (the original bug).
const inputCls =
  "px-3 py-2 rounded-lg bg-surface-2 border border-default text-[13px] " +
  "placeholder:text-dim focus:outline-none focus:border-accent transition-colors font-mono-app";

function Field(props: {
  label: string;
  children: React.ReactNode;
  span?: number;
  hint?: string;
}) {
  return (
    <label className={`flex flex-col gap-1.5 ${props.span === 2 ? "col-span-2" : ""}`}>
      <span className="text-[12px] font-medium text-muted">{props.label}</span>
      {props.children}
      {props.hint && <span className="text-[11px] text-dim">{props.hint}</span>}
    </label>
  );
}

export function ConnectionModal({ open, onClose, onConnect, current }: Props) {
  const [form, setForm] = React.useState<ConnectionInfo>({
    user: current?.user ?? "",
    host: current?.host ?? "",
    port: current?.port ?? "1521",
    service: current?.service ?? "",
    password: current?.password ?? "",
  });
  const [status, setStatus] = React.useState<"idle" | "testing" | "ok" | "fail">("idle");
  const [statusMsg, setStatusMsg] = React.useState<string>("");

  // The form's useState initializer only fires on first mount, so when the
  // page restores a saved `current` from sessionStorage AFTER the modal is
  // mounted, the form silently keeps showing empty fields. Re-sync the form
  // each time the modal opens — so editing an existing connection actually
  // shows the saved values instead of blank placeholders.
  React.useEffect(() => {
    if (open) {
      setStatus("idle");
      setStatusMsg("");
      setForm({
        user:     current?.user ?? "",
        host:     current?.host ?? "",
        port:     current?.port ?? "1521",
        service:  current?.service ?? "",
        password: current?.password ?? "",
      });
    }
  }, [open, current]);

  // Esc closes — matches ErrorModal / PlanFlowchartModal so all modals
  // dismiss the same way.
  React.useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") onClose(); };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [open, onClose]);

  if (!open) return null;

  const test = async () => {
    if (!form.user || !form.host || !form.service || !form.password) {
      setStatus("fail");
      setStatusMsg("Fill in user, host, service, and password before testing.");
      return;
    }
    setStatus("testing");
    setStatusMsg("");
    try {
      const res = await fetch("/api/oracle/test-connection", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          host: form.host,
          port: form.port,
          serviceName: form.service,
          user: form.user,
          password: form.password,
        }),
      });
      const data = await res.json();
      if (res.ok && data.ok) {
        setStatus("ok");
        setStatusMsg(`Connected as ${data.user} on ${data.db}.`);
      } else {
        setStatus("fail");
        setStatusMsg(data.error || `HTTP ${res.status}`);
      }
    } catch (err) {
      setStatus("fail");
      setStatusMsg(err instanceof Error ? err.message : "Network error.");
    }
  };

  const submit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!form.user || !form.host || !form.service || !form.password) return;
    onConnect({
      user: form.user,
      host: form.host,
      port: form.port,
      service: form.service,
      password: form.password,
    });
    onClose();
  };

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center p-4 fade-up"
      role="dialog"
      aria-modal="true"
    >
      {/* backdrop */}
      <div
        className="absolute inset-0 bg-black/60 backdrop-blur-sm"
        onClick={onClose}
      />
      {/* dialog */}
      <div className="relative card shadow-lg-app w-full max-w-[520px] overflow-hidden">
        <div className="flex items-center gap-3 px-5 py-4 border-b border-default">
          <div className="w-9 h-9 rounded-lg bg-accent-soft border border-default flex items-center justify-center">
            <IcDatabase size={17} className="text-accent" />
          </div>
          <div className="flex-1">
            <div className="text-[14px] font-semibold">Oracle Database Connection</div>
            <div className="text-[12px] text-muted">
              Credentials are kept in memory for this session only.
            </div>
          </div>
          <button onClick={onClose} className="btn btn-ghost btn-icon" aria-label="Close">
            <IcX size={15} />
          </button>
        </div>

        <form onSubmit={submit} className="px-5 py-5 space-y-4">
          <div className="grid grid-cols-2 gap-3.5">
            <Field label="Username">
              <input
                className={inputCls}
                placeholder="hr"
                value={form.user}
                onChange={(e) => setForm({ ...form, user: e.target.value })}
                autoFocus
              />
            </Field>
            <Field label="Password">
              <div className="relative">
                <IcKey size={13} className="absolute left-3 top-1/2 -translate-y-1/2 text-dim" />
                <input
                  type="password"
                  className={`${inputCls} pl-8 w-full`}
                  placeholder="••••••••"
                  value={form.password}
                  onChange={(e) => setForm({ ...form, password: e.target.value })}
                />
              </div>
            </Field>
            <Field label="Host" span={2}>
              <input
                className={inputCls}
                placeholder="db.example.com"
                value={form.host}
                onChange={(e) => setForm({ ...form, host: e.target.value })}
              />
            </Field>
            <Field label="Port">
              <input
                className={inputCls}
                placeholder="1521"
                value={form.port}
                onChange={(e) => setForm({ ...form, port: e.target.value })}
              />
            </Field>
            <Field label="Service name">
              <input
                className={inputCls}
                placeholder="ORCLPDB1"
                value={form.service}
                onChange={(e) => setForm({ ...form, service: e.target.value })}
              />
            </Field>
          </div>

          {/* Status strip */}
          <div className="min-h-[36px] flex items-center">
            {status === "ok" && (
              <div className="flex items-center gap-2 px-3 py-1.5 rounded-md bg-success-soft text-success text-[12px]">
                <IcCheck size={13} />
                {statusMsg || "Connection looks good. You can save it now."}
              </div>
            )}
            {status === "fail" && (
              <div className="flex items-center gap-2 px-3 py-1.5 rounded-md bg-danger-soft text-danger text-[12px]">
                <IcAlert size={13} />
                {statusMsg || "Couldn't reach the database."}
              </div>
            )}
            {status === "testing" && (
              <div className="flex items-center gap-2 text-[12px] text-muted">
                <span className="inline-block w-3 h-3 rounded-full border-2 border-current border-t-transparent animate-spin" />
                Testing connection…
              </div>
            )}
          </div>

          <div className="flex items-center justify-between pt-1">
            <button
              type="button"
              onClick={test}
              disabled={status === "testing"}
              className="btn btn-ghost"
            >
              Test connection
            </button>
            <div className="flex items-center gap-2">
              <button type="button" onClick={onClose} className="btn btn-ghost">
                Cancel
              </button>
              <button type="submit" className="btn btn-primary">
                Save & connect
              </button>
            </div>
          </div>
        </form>
      </div>
    </div>
  );
}
