"use client";

import * as React from "react";
import { IcCopy, IcCheck } from "./icons";

export function CopyButton({ text, label = "Copy" }: { text: string; label?: string }) {
  const [copied, setCopied] = React.useState(false);
  const onClick = async () => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {}
  };
  return (
    <button onClick={onClick} className="btn btn-ghost text-xs">
      {copied ? <IcCheck size={13} /> : <IcCopy size={13} />}
      <span>{copied ? "Copied" : label}</span>
    </button>
  );
}
