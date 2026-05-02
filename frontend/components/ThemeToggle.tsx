"use client";

import * as React from "react";
import { IcSun, IcMoon } from "./icons";

export function ThemeToggle() {
  const [theme, setTheme] = React.useState<"light" | "dark">("dark");

  React.useEffect(() => {
    const saved = (localStorage.getItem("qm-theme") as "light" | "dark" | null) ?? "dark";
    setTheme(saved);
    document.documentElement.setAttribute("data-theme", saved);
  }, []);

  const toggle = () => {
    const next = theme === "dark" ? "light" : "dark";
    setTheme(next);
    document.documentElement.setAttribute("data-theme", next);
    try { localStorage.setItem("qm-theme", next); } catch {}
  };

  return (
    <button
      onClick={toggle}
      aria-label={`Switch to ${theme === "dark" ? "light" : "dark"} theme`}
      className="btn btn-ghost btn-icon"
      title={`Theme: ${theme}`}
    >
      {theme === "dark" ? <IcSun size={15} /> : <IcMoon size={15} />}
    </button>
  );
}
