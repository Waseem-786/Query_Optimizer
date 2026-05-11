"use client";

import * as React from "react";
import ReactMarkdown from "react-markdown";
import type { Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import { CopyButton } from "./CopyButton";
import { SqlBlock } from "./SqlBlock";

// Renders assistant text as proper Markdown. Code blocks tagged ```sql get
// the same syntax-highlighted SqlBlock as the rewrite tab; other code blocks
// fall through to a plain monospaced <pre>. Headings render as smaller bold
// blocks (h1 / h2 are too large for an in-panel chat bubble), and every code
// block — fenced or inline — picks up a Copy button so users can grab snippets
// without selecting text by hand.
//
// Why react-markdown vs hand-rolled: the model emits real Markdown — tables,
// nested lists, GFM strike-through, links — and we want all of it without
// reimplementing the parser. remark-gfm covers GitHub-flavored extensions.
//
// Why no rehype-highlight: we already ship a SQL highlighter that matches our
// theme. Other languages render plain (the chat is DB-scoped, ~all snippets
// are SQL / PL/SQL anyway).
export function MarkdownRender({ children }: { children: string }) {
  return (
    <div className="markdown-body text-[13px] leading-relaxed text-fg">
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={MD_COMPONENTS}>
        {children}
      </ReactMarkdown>
    </div>
  );
}

// react-markdown's default tags produce browser-default styling, which clashes
// with our tight chat layout. Override each one with a class set that matches
// the surrounding `card` aesthetic.
const MD_COMPONENTS: Components = {
  h1: ({ children, ...p }) => (
    <h1 className="text-[15px] font-semibold tracking-tight mt-3 mb-1.5 first:mt-0" {...p}>
      {children}
    </h1>
  ),
  h2: ({ children, ...p }) => (
    <h2 className="text-[14px] font-semibold tracking-tight mt-3 mb-1.5 first:mt-0" {...p}>
      {children}
    </h2>
  ),
  h3: ({ children, ...p }) => (
    <h3 className="text-[13px] font-semibold mt-2.5 mb-1 first:mt-0" {...p}>
      {children}
    </h3>
  ),
  h4: ({ children, ...p }) => (
    <h4 className="text-[12.5px] font-semibold mt-2.5 mb-1 first:mt-0" {...p}>
      {children}
    </h4>
  ),
  p:  ({ children, ...p }) => (
    <p className="mb-2 last:mb-0" {...p}>{children}</p>
  ),
  strong: ({ children, ...p }) => (
    <strong className="font-semibold text-fg" {...p}>{children}</strong>
  ),
  em: ({ children, ...p }) => (
    <em className="italic text-fg/90" {...p}>{children}</em>
  ),
  ul: ({ children, ...p }) => (
    <ul className="list-disc pl-5 space-y-1 mb-2 last:mb-0" {...p}>{children}</ul>
  ),
  ol: ({ children, ...p }) => (
    <ol className="list-decimal pl-5 space-y-1 mb-2 last:mb-0" {...p}>{children}</ol>
  ),
  li: ({ children, ...p }) => (
    <li className="leading-relaxed" {...p}>{children}</li>
  ),
  a: ({ children, href, ...p }) => (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className="text-accent underline underline-offset-2 hover:opacity-80"
      {...p}
    >
      {children}
    </a>
  ),
  blockquote: ({ children, ...p }) => (
    <blockquote className="border-l-2 border-default pl-3 my-2 text-muted italic" {...p}>
      {children}
    </blockquote>
  ),
  hr: () => <hr className="my-3 border-default" />,
  table: ({ children, ...p }) => (
    <div className="my-2 overflow-x-auto">
      <table className="w-full text-[12.5px] border-collapse" {...p}>{children}</table>
    </div>
  ),
  thead: ({ children, ...p }) => (
    <thead className="bg-surface-2 text-muted" {...p}>{children}</thead>
  ),
  th: ({ children, ...p }) => (
    <th className="px-2 py-1.5 text-left font-medium border-b border-default" {...p}>{children}</th>
  ),
  td: ({ children, ...p }) => (
    <td className="px-2 py-1.5 border-b border-default align-top" {...p}>{children}</td>
  ),
  // Inline + fenced code. ReactMarkdown 10 routes BOTH through this component.
  // We detect "fenced" by the presence of a `language-*` className OR the
  // string containing a newline (fenced blocks include a trailing \n).
  code: ({ className, children, ...rest }) => {
    const lang = /language-(\w+)/.exec(className || "")?.[1]?.toLowerCase();
    const raw = String(children ?? "").replace(/\n$/, "");
    // Heuristic: react-markdown gives us the inline element wrapped in a <p>
    // (no className) and the fenced block as a `<code className="language-x">`
    // child of `<pre>`. If we have a lang or the content has newlines, treat
    // it as a block; otherwise inline.
    const isBlock = !!lang || raw.includes("\n");
    if (!isBlock) {
      return (
        <code
          className="font-mono-app text-[12px] px-1 py-0.5 rounded bg-surface-2 border border-default text-fg"
          {...rest}
        >
          {children}
        </code>
      );
    }
    // Block — wrap with a header strip showing the language tag and a copy
    // button. SQL/PL-SQL goes through SqlBlock for keyword colouring; others
    // render as a plain <pre>.
    const isSql = lang === "sql" || lang === "plsql" || lang === "pl/sql";
    return (
      <div className="my-2 rounded-md border border-default bg-surface-2 overflow-hidden">
        <div className="flex items-center justify-between px-3 h-7 border-b border-default text-[11px] text-dim font-mono-app">
          <span>{lang || "code"}</span>
          <CopyButton text={raw} />
        </div>
        <div className="px-3 py-2 overflow-x-auto">
          {isSql ? (
            <SqlBlock sql={raw} />
          ) : (
            <pre className="font-mono-app text-[12.5px] leading-[1.6] whitespace-pre-wrap break-words text-fg">
              <code>{raw}</code>
            </pre>
          )}
        </div>
      </div>
    );
  },
  pre: ({ children }) => <>{children}</>, // strip default <pre> wrapper — handled inside `code`
};
